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
const has_64_bit_atomics = @import("target.zig").has_64_bit_atomics;
const clock = @import("clock.zig");
const encoding = @import("encoding.zig");
const errors = @import("errors.zig");

const iterations = 10_000;

const layouts = [_]type{
    OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {}, .epoch = .unix }),
    OrderedId(.{ .timestamp_bits = 1, .node_bits = 1, .sequence_bits = 1, .tag = struct {}, .epoch = .unix }),
    OrderedId(.{ .timestamp_bits = 32, .node_bits = 0, .sequence_bits = 0, .tag = struct {}, .epoch = .unix }),
    OrderedId(.{ .timestamp_bits = 52, .node_bits = 0, .sequence_bits = 12, .tag = struct {}, .epoch = .unix }),
    OrderedId(.{ .timestamp_bits = 64, .node_bits = 0, .sequence_bits = 0, .tag = struct {}, .epoch = .unix }),
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
const SmallSeqId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 3, .tag = struct {}, .epoch = .unix });

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
    if (comptime !has_64_bit_atomics) return error.SkipZigTest;

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
        // layout, and 64-bit atomics, so not on a 32-bit target.
        if (comptime Id.Layout.total_bits < 64 and has_64_bit_atomics) {
            try checkLayout(atomic_generator.AtomicGenerator(Id, clock.ManualClock), random);
        }
    }
}

// ------------------------------------------------------- reference model

/// What a generator must return, written straight from the rules and
/// independently of `successor`, which both generators share. Comparing
/// the two generators with each other can't catch a bug in `successor`,
/// because both would have it; comparing each with this model can.
///
/// It works differently on purpose: it counts the ids it has handed out
/// in the current millisecond, instead of reading the last id's sequence
/// and adding one, and builds ids with `fromInts`.
fn Model(comptime Id: type) type {
    return struct {
        const Self = @This();

        node: u64,
        tolerance: u64,
        /// The millisecond of the last id handed out (epoch-relative).
        current: ?u64 = null,
        /// How many ids have been handed out in `current`.
        count: u64 = 0,

        const ids_per_millisecond: u64 = @as(u64, std.math.maxInt(Id.Sequence)) + 1;

        fn next(self: *Self, clock_unix_millis: u64) errors.NextError!Id {
            if (clock_unix_millis < Id.epoch.unix_millis) return error.BeforeEpoch;
            var millisecond = clock_unix_millis - Id.epoch.unix_millis;
            if (millisecond > std.math.maxInt(Id.Timestamp)) return error.TimestampOverflow;

            if (self.current) |current| {
                if (millisecond < current) {
                    if (current - millisecond > self.tolerance) return error.ClockMovedBackwards;
                    millisecond = current; // Within the tolerance: stay put.
                }
                if (millisecond != current) self.count = 0;
            }

            if (self.count == ids_per_millisecond) return error.SequenceExhausted;

            const id = Id.fromInts(millisecond, self.node, self.count) catch unreachable;
            self.current = millisecond;
            self.count += 1;
            return id;
        }
    };
}

/// How often each outcome came up, so a test can check that its clock
/// walks reached every one of them.
const Outcomes = struct {
    issued: usize = 0,
    exhausted: usize = 0,
    backwards: usize = 0,
    before_epoch: usize = 0,
    overflow: usize = 0,

    fn record(self: *Outcomes, comptime Id: type, outcome: errors.NextError!Id) void {
        if (outcome) |_| {
            self.issued += 1;
        } else |err| switch (err) {
            error.SequenceExhausted => self.exhausted += 1,
            error.ClockMovedBackwards => self.backwards += 1,
            error.BeforeEpoch => self.before_epoch += 1,
            error.TimestampOverflow => self.overflow += 1,
        }
    }
};

fn expectSameOutcome(comptime Id: type, expected: errors.NextError!Id, actual: errors.NextError!Id) !void {
    if (expected) |id| {
        try std.testing.expectEqual(id, try actual);
    } else |err| {
        try std.testing.expectError(err, actual);
    }
}

/// The layouts the model is checked on: every edge layout, plus one with
/// a late epoch and a tiny timestamp field, so walks also reach
/// `BeforeEpoch` and `TimestampOverflow`.
const model_layouts = layouts ++ [_]type{
    OrderedId(.{ .timestamp_bits = 10, .node_bits = 4, .sequence_bits = 2, .tag = struct {}, .epoch = .fromUnixMillis(5_000) }),
};

/// The next clock reading in a walk, chosen by `r`: mostly the same
/// millisecond, sometimes a small step forward or back, and now and then a
/// jump to just around the epoch or the end of the layout's lifetime.
fn clockStep(comptime Id: type, previous: u64, r: u64) u64 {
    const amount = (r >> 8) % 4 + 1;
    return switch (r % 16) {
        0...7 => previous,
        8...11 => previous +| amount,
        12...14 => previous -| amount,
        else => jump: {
            const near_end = (r >> 16) & 1 == 1;
            const base = if (near_end) Id.max_unix_millis else Id.epoch.unix_millis;
            const offset = (r >> 17) % 8;
            break :jump (base -| 4) +| offset;
        },
    };
}

/// Runs both generators and the model over the same clock readings and
/// checks that all three agree on every call.
fn checkAgainstModel(
    comptime Id: type,
    tolerance: u64,
    node: Id.Node,
    readings: []const u64,
    outcomes: *Outcomes,
) !void {
    var model: Model(Id) = .{ .node = node, .tolerance = tolerance };

    var plain_clock = clock.ManualClock{};
    var plain = generator.Generator(Id, clock.ManualClock).init(.{
        .node = node,
        .clock = &plain_clock,
        .clock_skew_tolerance_ms = tolerance,
    });

    // AtomicGenerator needs a spare bit and 64-bit atomics.
    const with_atomic = comptime Id.Layout.total_bits < 64 and has_64_bit_atomics;
    var atomic_clock = clock.ManualClock{};
    var atomic = if (with_atomic) atomic_generator.AtomicGenerator(Id, clock.ManualClock).init(.{
        .node = node,
        .clock = &atomic_clock,
        .clock_skew_tolerance_ms = tolerance,
    }) else {};

    for (readings) |now| {
        const expected = model.next(now);
        outcomes.record(Id, expected);

        plain_clock.set(now);
        try expectSameOutcome(Id, expected, plain.next());

        if (with_atomic) {
            atomic_clock.set(now);
            try expectSameOutcome(Id, expected, atomic.next());
        }
    }
}

test "property: both generators match an independent model on every layout" {
    var prng: std.Random.DefaultPrng = .init(0x30de1);
    const random = prng.random();

    var outcomes: Outcomes = .{};
    var readings: [2_000]u64 = undefined;

    inline for (model_layouts) |Id| {
        for ([_]u64{ 0, 2 }) |tolerance| {
            var now = Id.epoch.unix_millis;
            for (&readings) |*reading| {
                now = clockStep(Id, now, random.int(u64));
                reading.* = now;
            }
            try checkAgainstModel(Id, tolerance, random.int(Id.Node), &readings, &outcomes);
        }
    }

    // The walks must have reached every outcome, or the test proves less
    // than its name says.
    try std.testing.expect(outcomes.issued > 0);
    try std.testing.expect(outcomes.exhausted > 0);
    try std.testing.expect(outcomes.backwards > 0);
    try std.testing.expect(outcomes.before_epoch > 0);
    try std.testing.expect(outcomes.overflow > 0);
}

const model_max_steps = 256;

/// Builds a corpus entry for `fuzzModel` in the raw form `Smith` reads:
/// the setup value, then for each step a 0 byte (`eos()` reads "not yet")
/// and the step's value, each value as 8 little-endian bytes. The entry
/// ends where the input ends, which `eos()` reads as "done".
fn modelEntry(buffer: []u8, setup: u64, random: std.Random) []const u8 {
    std.mem.writeInt(u64, buffer[0..8], setup, .little);
    var len: usize = 8;
    for (0..model_max_steps) |_| {
        buffer[len] = 0;
        std.mem.writeInt(u64, buffer[len + 1 ..][0..8], random.int(u64), .little);
        len += 9;
    }
    return buffer[0..len];
}

test "fuzz: both generators match the model for any clock walk" {
    // A plain `zig build test` runs only the corpus, so give it one walk
    // per layout and tolerance; `--fuzz` explores from there.
    const entry_len = 8 + model_max_steps * 9;
    const entry_count = model_layouts.len * 4;
    var buffers: [entry_count][entry_len]u8 = undefined;
    var corpus: [entry_count][]const u8 = undefined;

    var prng: std.Random.DefaultPrng = .init(0xf022);
    for (&buffers, &corpus, 0..) |*buffer, *entry, i| {
        // Low byte picks the layout, the next one the tolerance.
        const setup = (i % model_layouts.len) | ((i / model_layouts.len) << 8) | (prng.random().int(u64) << 16);
        entry.* = modelEntry(buffer, setup, prng.random());
    }

    try std.testing.fuzz({}, fuzzModel, .{ .corpus = &corpus });
}

fn fuzzModel(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const setup = smith.value(u64);
    const which = (setup & 0xff) % model_layouts.len;
    const tolerance = ((setup >> 8) & 0xff) % 4;

    var readings: [model_max_steps]u64 = undefined;
    var outcomes: Outcomes = .{};

    inline for (model_layouts, 0..) |Id, i| {
        if (which == i) {
            var len: usize = 0;
            var now = Id.epoch.unix_millis;
            while (len < readings.len and !smith.eos()) : (len += 1) {
                now = clockStep(Id, now, smith.value(u64));
                readings[len] = now;
            }
            try checkAgainstModel(Id, tolerance, @truncate(setup >> 16), readings[0..len], &outcomes);
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
