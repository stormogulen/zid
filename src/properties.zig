//! Property and fuzz tests.
//!
//! The unit tests next to each module check hand-picked cases. These
//! check that the guarantees hold across many random inputs and several
//! layouts, including the edge layouts (1-bit fields, 0-bit fields, a
//! full 64-bit timestamp).
//!
//! Property tests use a fixed seed, so a failure reproduces exactly.
//! Fuzz tests run their corpus once under `zig build test`; run
//! `zig build test --fuzz` to fuzz them continuously.

const std = @import("std");
const OrderedId = @import("ordered/id.zig").OrderedId;
const generator = @import("generator.zig");
const atomic_generator = @import("atomic_generator.zig");
const clock = @import("clock.zig");
const encoding = @import("encoding.zig");

const iterations = 10_000;

const layouts = [_]type{
    OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} }),
    OrderedId(.{ .timestamp_bits = 1, .node_bits = 1, .sequence_bits = 1, .tag = struct {} }),
    OrderedId(.{ .timestamp_bits = 32, .node_bits = 0, .sequence_bits = 0, .tag = struct {} }),
    OrderedId(.{ .timestamp_bits = 52, .node_bits = 0, .sequence_bits = 12, .tag = struct {} }),
    OrderedId(.{ .timestamp_bits = 64, .node_bits = 0, .sequence_bits = 0, .tag = struct {} }),
};

fn randomParts(comptime Id: type, random: std.Random) Id.Parts {
    return .{
        .timestamp = random.int(Id.Timestamp),
        .node = random.int(Id.Node),
        .sequence = random.int(Id.Sequence),
    };
}

/// The order the id promises: timestamp, then node, then sequence.
fn partsOrder(comptime Id: type, a: Id.Parts, b: Id.Parts) std.math.Order {
    const by_timestamp = std.math.order(a.timestamp, b.timestamp);
    if (by_timestamp != .eq) return by_timestamp;
    const by_node = std.math.order(a.node, b.node);
    if (by_node != .eq) return by_node;
    return std.math.order(a.sequence, b.sequence);
}

test "property: fields round trip through every representation" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();

    inline for (layouts) |Id| {
        for (0..iterations) |_| {
            const parts = randomParts(Id, random);
            const id = Id.fromParts(parts);

            try std.testing.expectEqual(parts, id.decode());
            try std.testing.expect(id.eql(try Id.fromRaw(id.raw())));

            const text = id.toString();
            try std.testing.expect(id.eql(try Id.parse(&text)));
        }
    }
}

test "property: raw, order and encoded strings all agree with field order" {
    var prng: std.Random.DefaultPrng = .init(0x0bde12);
    const random = prng.random();

    inline for (layouts) |Id| {
        for (0..iterations) |_| {
            const a_parts = randomParts(Id, random);
            const b_parts = randomParts(Id, random);
            const a = Id.fromParts(a_parts);
            const b = Id.fromParts(b_parts);

            const expected = partsOrder(Id, a_parts, b_parts);
            try std.testing.expectEqual(expected, a.order(b));

            const a_text = a.toString();
            const b_text = b.toString();
            try std.testing.expectEqual(expected, std.mem.order(u8, &a_text, &b_text));
        }
    }
}

test "property: minAt and maxAt bound every id at their timestamp" {
    var prng: std.Random.DefaultPrng = .init(0xb0bd5);
    const random = prng.random();

    inline for (layouts) |Id| {
        for (0..iterations) |_| {
            const id = Id.fromParts(randomParts(Id, random));
            const min = Id.minAt(id.timestamp());
            const max = Id.maxAt(id.timestamp());

            try std.testing.expect(min.order(id) != .gt);
            try std.testing.expect(id.order(max) != .gt);
        }
    }
}

/// Small sequence field, so exhaustion happens often.
const SmallSeqId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 3, .tag = struct {} });

/// Moves a manual clock the way the random-clock tests want: mostly
/// stay in the same millisecond, sometimes move forward, occasionally
/// step backwards.
fn randomStep(manual: *clock.ManualClock, random: std.Random) void {
    switch (random.uintLessThan(u8, 10)) {
        0...5 => {},
        6...8 => manual.advance(random.intRangeAtMost(u64, 1, 5)),
        else => manual.set(manual.value -| random.intRangeAtMost(u64, 1, 3)),
    }
}

test "property: a generator's ids strictly increase under a random clock" {
    var prng: std.Random.DefaultPrng = .init(0xc10c);
    const random = prng.random();

    var manual = clock.ManualClock{ .value = 1_000 };
    var gen = generator.Generator(SmallSeqId, clock.ManualClock).init(.{
        .node = 5,
        .clock = &manual,
    });

    var previous: ?SmallSeqId = null;
    var exhausted: usize = 0;
    var backwards: usize = 0;

    for (0..iterations) |_| {
        randomStep(&manual, random);

        const id = gen.next() catch |err| switch (err) {
            error.SequenceExhausted => {
                exhausted += 1;
                continue;
            },
            error.ClockMovedBackwards => {
                backwards += 1;
                continue;
            },
            error.BeforeEpoch, error.TimestampOverflow => return err,
        };

        try std.testing.expectEqual(5, id.node());
        if (previous) |prev| try std.testing.expectEqual(.gt, id.order(prev));
        previous = id;
    }

    // The walk must actually have exercised both failure paths.
    try std.testing.expect(exhausted > 0);
    try std.testing.expect(backwards > 0);
}

test "property: the skew tolerance fails exactly when the clock is too far behind" {
    var prng: std.Random.DefaultPrng = .init(0x70e4);
    const random = prng.random();

    for ([_]u64{ 0, 1, 3, 10 }) |tolerance| {
        var manual = clock.ManualClock{ .value = 1_000 };
        var gen = generator.Generator(SmallSeqId, clock.ManualClock).init(.{
            .node = 5,
            .clock = &manual,
            .clock_skew_tolerance_ms = tolerance,
        });

        var previous: ?SmallSeqId = null;
        var absorbed: usize = 0;
        var rejected: usize = 0;

        for (0..iterations) |_| {
            randomStep(&manual, random);

            if (gen.next()) |id| {
                if (previous) |prev| {
                    try std.testing.expectEqual(.gt, id.order(prev));

                    // A clock behind the last id (within the tolerance)
                    // keeps the last id's timestamp; never an earlier one.
                    if (manual.value < prev.timestamp()) {
                        try std.testing.expectEqual(prev.timestamp(), id.timestamp());
                        // Absorbed only when behind by AT MOST the tolerance.
                        try std.testing.expect(manual.value + tolerance >= prev.timestamp());
                        absorbed += 1;
                    }
                }
                previous = id;
            } else |err| switch (err) {
                error.SequenceExhausted => try std.testing.expect(previous != null),
                error.ClockMovedBackwards => {
                    // Rejected only when behind by MORE than the tolerance.
                    try std.testing.expect(manual.value + tolerance < previous.?.timestamp());
                    rejected += 1;
                },
                error.BeforeEpoch, error.TimestampOverflow => return err,
            }
        }

        // Rejection is possible at every tolerance used here, but only a
        // nonzero tolerance can absorb a step back.
        try std.testing.expect(rejected > 0);
        if (tolerance > 0) {
            try std.testing.expect(absorbed > 0);
        } else {
            try std.testing.expectEqual(0, absorbed);
        }
    }
}

test "property: a resumed generator always issues ids above the one it resumed from" {
    var prng: std.Random.DefaultPrng = .init(0x7e5e);
    const random = prng.random();

    var resumed_ok: usize = 0;
    var behind: usize = 0;

    for (0..2_000) |_| {
        const last = SmallSeqId.fromParts(.{
            .timestamp = random.intRangeAtMost(u41, 900, 1_100),
            .node = 5,
            .sequence = random.int(SmallSeqId.Sequence),
        });
        var manual = clock.ManualClock{ .value = random.intRangeAtMost(u64, 900, 1_100) };

        var gen = try generator.Generator(SmallSeqId, clock.ManualClock).initAfter(.{
            .node = 5,
            .clock = &manual,
        }, last);
        try std.testing.expectEqual(last, gen.lastIssued().?);

        var previous = last;
        for (0..12) |_| {
            randomStep(&manual, random);

            if (gen.next()) |id| {
                try std.testing.expectEqual(.gt, id.order(previous));
                previous = id;
                resumed_ok += 1;
            } else |err| switch (err) {
                error.ClockMovedBackwards => {
                    try std.testing.expect(manual.value < previous.timestamp());
                    behind += 1;
                },
                error.SequenceExhausted => {
                    try std.testing.expectEqual(previous.timestamp(), manual.value);
                    try std.testing.expectEqual(std.math.maxInt(SmallSeqId.Sequence), previous.sequence());
                },
                error.BeforeEpoch, error.TimestampOverflow => return err,
            }
        }
    }

    // Both outcomes must actually have been exercised.
    try std.testing.expect(resumed_ok > 0);
    try std.testing.expect(behind > 0);
}

test "property: a generator resumed after a timestamp never issues an id at or before it" {
    var prng: std.Random.DefaultPrng = .init(0x7e5e7a);
    const random = prng.random();

    var issued: usize = 0;
    var waited: usize = 0;

    for (0..2_000) |_| {
        const reserved = random.intRangeAtMost(SmallSeqId.Timestamp, 900, 1_100);
        var manual = clock.ManualClock{ .value = random.intRangeAtMost(u64, 900, 1_100) };

        var gen = generator.Generator(SmallSeqId, clock.ManualClock).initAfterTimestamp(.{
            .node = 5,
            .clock = &manual,
        }, reserved);

        for (0..12) |_| {
            randomStep(&manual, random);

            if (gen.next()) |id| {
                try std.testing.expect(id.timestamp() > reserved);
                try std.testing.expect(manual.value > reserved);
                issued += 1;
            } else |err| switch (err) {
                // Still at or behind the reserved millisecond, or the
                // ordinary limits once past it.
                error.ClockMovedBackwards, error.SequenceExhausted => waited += 1,
                error.BeforeEpoch, error.TimestampOverflow => return err,
            }
        }
    }

    try std.testing.expect(issued > 0);
    try std.testing.expect(waited > 0);
}

test "property: AtomicGenerator and Generator agree on every call under a random clock" {
    var prng: std.Random.DefaultPrng = .init(0xa70b1c);
    const random = prng.random();

    for ([_]u64{ 0, 2, 7 }) |tolerance| {
        var plain_clock = clock.ManualClock{ .value = 1_000 };
        var atomic_clock = clock.ManualClock{ .value = 1_000 };
        var plain = generator.Generator(SmallSeqId, clock.ManualClock).init(.{
            .node = 9,
            .clock = &plain_clock,
            .clock_skew_tolerance_ms = tolerance,
        });
        var atomic = atomic_generator.AtomicGenerator(SmallSeqId, clock.ManualClock).init(.{
            .node = 9,
            .clock = &atomic_clock,
            .clock_skew_tolerance_ms = tolerance,
        });

        var issued: usize = 0;
        var failed: usize = 0;

        for (0..iterations) |_| {
            // The same step for both clocks.
            const action = random.uintLessThan(u8, 10);
            const amount = random.intRangeAtMost(u64, 1, 5);
            for ([_]*clock.ManualClock{ &plain_clock, &atomic_clock }) |manual| {
                switch (action) {
                    0...5 => {},
                    6...8 => manual.advance(amount),
                    else => manual.set(manual.value -| amount),
                }
            }

            const expected = plain.next();
            const actual = atomic.next();
            if (expected) |id| {
                try std.testing.expectEqual(id, try actual);
                issued += 1;
            } else |err| {
                try std.testing.expectError(err, actual);
                failed += 1;
            }

            try std.testing.expectEqual(plain.lastIssued(), atomic.lastIssued());
        }

        try std.testing.expect(issued > 0);
        try std.testing.expect(failed > 0);
    }
}

/// Walks a forward-moving clock and checks the core promise of a
/// generator type on one layout: for a fixed node, ids strictly increase.
fn checkLayout(comptime Gen: type, random: std.Random) !void {
    const Id = Gen.Id;
    const max_timestamp: u64 = std.math.maxInt(Id.Timestamp);
    const node = random.int(Id.Node);

    var manual = clock.ManualClock{ .value = 0 };
    var gen = Gen.init(.{ .node = node, .clock = &manual });

    var previous: ?Id = null;
    var issued: usize = 0;

    for (0..iterations) |_| {
        // Mostly stay in the same millisecond, sometimes move on, but
        // never past the layout's last timestamp.
        if (random.uintLessThan(u8, 4) == 0 and manual.value < max_timestamp) {
            manual.advance(1);
        }

        const id = gen.next() catch |err| switch (err) {
            error.SequenceExhausted => continue,
            error.ClockMovedBackwards, error.BeforeEpoch, error.TimestampOverflow => return err,
        };

        try std.testing.expectEqual(node, id.node());
        if (previous) |prev| try std.testing.expectEqual(.gt, id.order(prev));
        previous = id;
        issued += 1;
    }

    try std.testing.expect(issued > 0);
}

test "property: both generators work on every layout, including zero-width fields" {
    var prng: std.Random.DefaultPrng = .init(0x1a70);
    const random = prng.random();

    inline for (layouts) |Id| {
        try checkLayout(generator.Generator(Id, clock.ManualClock), random);

        // AtomicGenerator needs a spare bit, so it can't take the 64-bit
        // layout.
        if (comptime Id.Layout.total_bits < 64) {
            try checkLayout(atomic_generator.AtomicGenerator(Id, clock.ManualClock), random);
        }
    }
}

/// Both fuzz targets first pick one of `layouts` from their first input
/// value, so the same fuzzing run covers every layout, including the
/// 1-bit, 0-bit and full 64-bit edge layouts.
fn layoutIndex(smith: *std.testing.Smith) usize {
    return smith.valueRangeLessThan(u8, 0, layouts.len);
}

/// `Smith` reads every scalar as 8 little-endian bytes, whatever its
/// type, so a corpus entry's layout selector takes 8 bytes too.
fn layoutPrefix(comptime which: u8) [8]u8 {
    return @bitCast(std.mem.nativeToLittle(u64, which));
}

/// A corpus entry is raw input for `std.testing.Smith`, not the value a
/// test sees: the layout selector comes first, then `smith.slice` reads a
/// little-endian u32 length followed by the bytes.
fn parseEntry(comptime which: u8, comptime text: []const u8) []const u8 {
    const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, text.len));
    return &(layoutPrefix(which) ++ len ++ text[0..text.len].*);
}

/// The layout selector, then `smith.value(u64)`'s 8 little-endian bytes.
fn rawEntry(comptime which: u8, comptime value: u64) []const u8 {
    const bytes: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, value));
    return &(layoutPrefix(which) ++ bytes);
}

// Built at container level, so the entries are evaluated at compile
// time and stay valid for the whole test run. Every layout gets its
// largest producible id and, when it has spare bits, the first value
// past it: well-formed text that the layout must still reject.
const parse_corpus = blk: {
    var entries: [layouts.len * 2 + 3][]const u8 = undefined;
    var n: usize = 0;

    for (layouts, 0..) |Id, i| {
        const mask = Id.Layout.used_mask;
        entries[n] = parseEntry(i, &encoding.encode(mask));
        n += 1;
        if (mask != std.math.maxInt(u64)) {
            entries[n] = parseEntry(i, &encoding.encode(mask + 1));
            n += 1;
        }
    }

    entries[n] = parseEntry(0, "0000000000000");
    n += 1;
    entries[n] = parseEntry(0, "TOOSHORT");
    n += 1;
    entries[n] = parseEntry(0, "I000000000000");
    n += 1;

    const result: [n][]const u8 = entries[0..n].*;
    break :blk result;
};

test "fuzz: parse never misreads input" {
    try std.testing.fuzz({}, fuzzParse, .{ .corpus = &parse_corpus });
}

fn fuzzParse(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const which = layoutIndex(smith);

    var buf: [32]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];

    inline for (layouts, 0..) |Id, i| {
        if (which == i) try checkParse(Id, input);
    }
}

fn checkParse(comptime Id: type, input: []const u8) !void {
    const id = Id.parse(input) catch |err| switch (err) {
        // Rejecting is always allowed; misreading is not.
        error.InvalidLength, error.InvalidCharacter, error.ValueTooLarge, error.ReservedBitsSet => return,
    };

    // Anything parse accepts must be a value the layout can produce...
    try std.testing.expectEqual(0, id.raw() & ~Id.Layout.used_mask);
    try std.testing.expect(id.eql(Id.fromParts(id.decode())));

    // ...and exactly what toString produces for it.
    const text = id.toString();
    try std.testing.expectEqualStrings(input, &text);
}

const from_raw_corpus = blk: {
    var entries: [layouts.len * 4][]const u8 = undefined;
    var n: usize = 0;

    for (layouts, 0..) |Id, i| {
        entries[n] = rawEntry(i, 0);
        entries[n + 1] = rawEntry(i, Id.Layout.used_mask);
        entries[n + 2] = rawEntry(i, 1 << 63);
        entries[n + 3] = rawEntry(i, std.math.maxInt(u64));
        n += 4;
    }

    const result: [n][]const u8 = entries[0..n].*;
    break :blk result;
};

test "fuzz: fromRaw accepts exactly the values the layout can produce" {
    try std.testing.fuzz({}, fuzzFromRaw, .{ .corpus = &from_raw_corpus });
}

fn fuzzFromRaw(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const which = layoutIndex(smith);
    const raw = smith.value(u64);

    inline for (layouts, 0..) |Id, i| {
        if (which == i) try checkFromRaw(Id, raw);
    }
}

fn checkFromRaw(comptime Id: type, raw: u64) !void {
    const fits = raw & ~Id.Layout.used_mask == 0;

    if (Id.fromRaw(raw)) |id| {
        try std.testing.expect(fits);
        try std.testing.expectEqual(raw, Id.fromParts(id.decode()).raw());
    } else |err| switch (err) {
        error.ReservedBitsSet => try std.testing.expect(!fits),
    }
}
