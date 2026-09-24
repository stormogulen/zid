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

test "property: a generator's ids strictly increase under a random clock" {
    // Small sequence field, so exhaustion happens often.
    const Id = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 3, .tag = struct {} });

    var prng: std.Random.DefaultPrng = .init(0xc10c);
    const random = prng.random();

    var manual = clock.ManualClock{ .value = 1_000 };
    var gen = generator.Generator(Id, clock.ManualClock).init(.{
        .node = 5,
        .clock = &manual,
    });

    var previous: ?Id = null;
    var exhausted: usize = 0;
    var backwards: usize = 0;

    for (0..iterations) |_| {
        // Mostly stay in the same millisecond, sometimes move forward,
        // occasionally step backwards.
        switch (random.uintLessThan(u8, 10)) {
            0...5 => {},
            6...8 => manual.advance(random.intRangeAtMost(u64, 1, 5)),
            else => manual.set(manual.value -| random.intRangeAtMost(u64, 1, 3)),
        }

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

const FuzzId = layouts[0];

/// A corpus entry is raw input for `std.testing.Smith`, not the value a
/// test sees: `smith.slice` reads a little-endian u32 length first.
fn sliceEntry(comptime text: []const u8) []const u8 {
    const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, text.len));
    return &(len ++ text[0..text.len].*);
}

/// `smith.value(u64)` reads 8 little-endian bytes.
fn u64Entry(comptime value: u64) []const u8 {
    const bytes: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, value));
    return &bytes;
}

// Built at container level, so the entries are evaluated at compile
// time and stay valid for the whole test run.
const parse_corpus = [_][]const u8{
    sliceEntry("0000000000000"),
    sliceEntry("7ZZZZZZZZZZZZ"), // Largest value this 63-bit layout can produce.
    sliceEntry("8000000000000"), // Well-formed, but uses bit 63.
    sliceEntry("TOOSHORT"),
    sliceEntry("I000000000000"),
};

test "fuzz: parse never misreads input" {
    try std.testing.fuzz({}, fuzzParse, .{ .corpus = &parse_corpus });
}

fn fuzzParse(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var buf: [32]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];

    const id = FuzzId.parse(input) catch |err| switch (err) {
        // Rejecting is always allowed; misreading is not.
        error.InvalidLength, error.InvalidCharacter, error.Overflow, error.ReservedBitsSet => return,
    };

    // Anything parse accepts must be a value the layout can produce...
    try std.testing.expectEqual(0, id.raw() & ~FuzzId.Layout.used_mask);
    try std.testing.expect(id.eql(FuzzId.fromParts(id.decode())));

    // ...and exactly what toString produces for it.
    const text = id.toString();
    try std.testing.expectEqualStrings(input, &text);
}

const from_raw_corpus = [_][]const u8{
    u64Entry(0),
    u64Entry(FuzzId.Layout.used_mask),
    u64Entry(1 << 63),
    u64Entry(std.math.maxInt(u64)),
};

test "fuzz: fromRaw accepts exactly the values the layout can produce" {
    try std.testing.fuzz({}, fuzzFromRaw, .{ .corpus = &from_raw_corpus });
}

fn fuzzFromRaw(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const raw = smith.value(u64);
    const fits = raw & ~FuzzId.Layout.used_mask == 0;

    if (FuzzId.fromRaw(raw)) |id| {
        try std.testing.expect(fits);
        try std.testing.expectEqual(raw, FuzzId.fromParts(id.decode()).raw());
    } else |err| switch (err) {
        error.ReservedBitsSet => try std.testing.expect(!fits),
    }
}
