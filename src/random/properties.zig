//! Property and fuzz tests for RandomOrderedId and RandomGenerator.
//!
//! The generator is checked against an independent model that states
//! the rules directly: it remembers where the current millisecond started
//! and how many ids it has handed out since, instead of adding one to
//! the last id like `successor` does. Both read the same seeded random
//! stream, so every id is predictable.

const std = @import("std");
const errors = @import("../errors.zig");
const clock = @import("../clock.zig");
const RandomOrderedId = @import("id.zig").RandomOrderedId;
const RandomGenerator = @import("generator.zig").RandomGenerator;

const layouts = [_]type{
    RandomOrderedId(.{ .timestamp_bits = 48, .random_bits = 80, .tag = struct {}, .epoch = .unix }),
    // Tiny fields: the random bits run out and the timestamp overflows.
    RandomOrderedId(.{ .timestamp_bits = 4, .random_bits = 2, .tag = struct {}, .epoch = .unix }),
    // A late epoch, so walks also reach BeforeEpoch.
    RandomOrderedId(.{ .timestamp_bits = 10, .random_bits = 6, .tag = struct {}, .epoch = .fromUnixMillis(5_000) }),
    // The largest timestamp a u64 clock can reach.
    RandomOrderedId(.{ .timestamp_bits = 64, .random_bits = 2, .tag = struct {}, .epoch = .unix }),
    RandomOrderedId(.{ .timestamp_bits = 41, .random_bits = 23, .tag = struct {}, .epoch = .fromUnixMillis(1_735_689_600_000) }),
};

fn Model(comptime Id: type) type {
    return struct {
        const Self = @This();

        prng: std.Random.DefaultPrng,
        tolerance: u64,
        /// The millisecond of the last id (epoch-relative), and where its
        /// random bits started and how many ids have been handed out in it.
        current: ?u64 = null,
        start: u128 = 0,
        count: u128 = 0,

        /// Fresh starts are uniform over the lower half of the field.
        const half_range: u128 = (@as(u128, std.math.maxInt(Id.Random)) >> 1) + 1;

        fn next(self: *Self, clock_unix_millis: u64) errors.NextError!Id {
            // One draw per call, before anything can fail.
            var bytes: [16]u8 = undefined;
            self.prng.fill(&bytes);
            const drawn = std.mem.readInt(u128, &bytes, .little) % half_range;

            if (clock_unix_millis < Id.epoch.unix_millis) return error.BeforeEpoch;
            var millisecond = clock_unix_millis - Id.epoch.unix_millis;
            if (millisecond > std.math.maxInt(Id.Timestamp)) return error.TimestampOverflow;

            if (self.current) |current| {
                if (millisecond < current) {
                    if (current - millisecond > self.tolerance) return error.ClockMovedBackwards;
                    millisecond = current;
                }
                if (millisecond == current) {
                    const random = self.start + self.count;
                    if (random > std.math.maxInt(Id.Random)) return error.SequenceExhausted;
                    self.count += 1;
                    return Id.fromInts(millisecond, random) catch unreachable;
                }
            }

            self.current = millisecond;
            self.start = drawn;
            self.count = 1;
            return Id.fromInts(millisecond, drawn) catch unreachable;
        }
    };
}

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

/// The next clock reading in a walk, chosen by `r`; the same shape as the
/// OrderedId property tests use.
fn clockStep(comptime Id: type, previous: u64, r: u64) u64 {
    const amount = (r >> 8) % 4 + 1;
    return switch (r % 16) {
        0...7 => previous,
        8...11 => previous +| amount,
        12...14 => previous -| amount,
        else => jump: {
            const near_end = (r >> 16) & 1 == 1;
            const base = if (near_end) Id.max_unix_millis else Id.epoch.unix_millis;
            break :jump (base -| 4) +| ((r >> 17) % 8);
        },
    };
}

fn checkAgainstModel(comptime Id: type, tolerance: u64, seed: u64, readings: []const u64, outcomes: *Outcomes) !void {
    var model: Model(Id) = .{ .prng = .init(seed), .tolerance = tolerance };

    var manual = clock.ManualClock{};
    var prng: std.Random.DefaultPrng = .init(seed);
    var gen = RandomGenerator(Id, clock.ManualClock, std.Random.DefaultPrng).init(.{
        .clock = &manual,
        .random = &prng,
        .clock_skew_tolerance_ms = tolerance,
    });

    for (readings) |now| {
        const expected = model.next(now);
        outcomes.record(Id, expected);

        manual.set(now);
        const actual = gen.next();
        if (expected) |id| {
            try std.testing.expectEqual(id, try actual);
        } else |err| {
            try std.testing.expectError(err, actual);
        }
    }
}

test "property: RandomGenerator matches an independent model on every layout" {
    var prng: std.Random.DefaultPrng = .init(0x7a2d0);
    const random = prng.random();

    var outcomes: Outcomes = .{};
    var readings: [2_000]u64 = undefined;

    inline for (layouts) |Id| {
        for ([_]u64{ 0, 2 }) |tolerance| {
            var now = Id.epoch.unix_millis;
            for (&readings) |*reading| {
                now = clockStep(Id, now, random.int(u64));
                reading.* = now;
            }
            try checkAgainstModel(Id, tolerance, random.int(u64), &readings, &outcomes);
        }
    }

    try std.testing.expect(outcomes.issued > 0);
    try std.testing.expect(outcomes.exhausted > 0);
    try std.testing.expect(outcomes.backwards > 0);
    try std.testing.expect(outcomes.before_epoch > 0);
    try std.testing.expect(outcomes.overflow > 0);
}

test "property: raw order, string order and field order agree" {
    var prng: std.Random.DefaultPrng = .init(0x5027);
    const random = prng.random();

    inline for (layouts) |Id| {
        for (0..5_000) |_| {
            const a: Id.Parts = .{ .timestamp = random.int(Id.Timestamp), .random = random.int(Id.Random) };
            const b: Id.Parts = .{ .timestamp = random.int(Id.Timestamp), .random = random.int(Id.Random) };
            const by_timestamp = std.math.order(a.timestamp, b.timestamp);
            const expected = if (by_timestamp != .eq) by_timestamp else std.math.order(a.random, b.random);

            const x = Id.fromParts(a);
            const y = Id.fromParts(b);
            try std.testing.expectEqual(expected, x.order(y));
            try std.testing.expectEqual(expected, std.mem.order(u8, &x.toString(), &y.toString()));
            try std.testing.expect(x.eql(try Id.parse(&x.toString())));
        }
    }
}

const max_steps = 256;

/// A corpus entry in the raw form `Smith` reads: the setup value, then per
/// step a 0 byte (`eos()`: not done) and the step's value, every value as
/// 8 little-endian bytes. The input ending is `eos()`'s "done".
fn entry(buffer: []u8, setup: u64, random: std.Random) []const u8 {
    std.mem.writeInt(u64, buffer[0..8], setup, .little);
    var len: usize = 8;
    for (0..max_steps) |_| {
        buffer[len] = 0;
        std.mem.writeInt(u64, buffer[len + 1 ..][0..8], random.int(u64), .little);
        len += 9;
    }
    return buffer[0..len];
}

test "fuzz: RandomGenerator matches the model for any clock walk and seed" {
    const entry_len = 8 + max_steps * 9;
    const entry_count = layouts.len * 4;
    var buffers: [entry_count][entry_len]u8 = undefined;
    var corpus: [entry_count][]const u8 = undefined;

    var prng: std.Random.DefaultPrng = .init(0xf0221);
    for (&buffers, &corpus, 0..) |*buffer, *slot, i| {
        // Low byte: layout. Next byte: tolerance. The rest: the seed.
        const setup = (i % layouts.len) | ((i / layouts.len) << 8) | (prng.random().int(u64) << 16);
        slot.* = entry(buffer, setup, prng.random());
    }

    try std.testing.fuzz({}, fuzzModel, .{ .corpus = &corpus });
}

fn fuzzModel(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const setup = smith.value(u64);
    const which = (setup & 0xff) % layouts.len;
    const tolerance = ((setup >> 8) & 0xff) % 4;
    const seed = setup >> 16;

    var readings: [max_steps]u64 = undefined;
    var outcomes: Outcomes = .{};

    inline for (layouts, 0..) |Id, i| {
        if (which == i) {
            var len: usize = 0;
            var now = Id.epoch.unix_millis;
            while (len < readings.len and !smith.eos()) : (len += 1) {
                now = clockStep(Id, now, smith.value(u64));
                readings[len] = now;
            }
            try checkAgainstModel(Id, tolerance, seed, readings[0..len], &outcomes);
        }
    }
}
