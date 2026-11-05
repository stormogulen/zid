//! Deterministic tests with RandomOrderedId: a ManualClock and a seeded
//! PRNG make every id known in advance, with no waiting and no flakiness.
//!
//!     zig build run-random-testing

const std = @import("std");
const zid = @import("zid");

const TestKey = zid.RandomOrderedId(.{
    .timestamp_bits = 48,
    .random_bits = 80,
    .tag = struct {},
    .epoch = .unix,
});

// Deliberately tiny random field, so running out is easy to show: the
// generator starts each millisecond at 0 or 1 (top bit clear), the start
// is itself the first id's random bits, and 3 is the largest value, so
// 4 ids fit (0..3) or 3 (1..3).
const TinyKey = zid.RandomOrderedId(.{
    .timestamp_bits = 48,
    .random_bits = 2,
    .tag = struct {},
    .epoch = .unix,
});

const Prng = std.Random.DefaultPrng;

/// Checks a result in every build mode; see examples/testing.
fn check(ok: bool, comptime what: []const u8) !void {
    if (!ok) {
        std.debug.print("check failed: " ++ what ++ "\n", .{});
        return error.CheckFailed;
    }
}

pub fn main() !void {
    // Same seed and same clock readings: the same ids, every run.
    {
        var clock_a = zid.ManualClock{ .value = 1_000 };
        var clock_b = zid.ManualClock{ .value = 1_000 };
        var prng_a: Prng = .init(42);
        var prng_b: Prng = .init(42);
        var a = zid.RandomGenerator(TestKey, zid.ManualClock, Prng).init(.{ .clock = &clock_a, .random = &prng_a });
        var b = zid.RandomGenerator(TestKey, zid.ManualClock, Prng).init(.{ .clock = &clock_b, .random = &prng_b });

        const first = try a.next();
        std.debug.print("seed 42, t=1000:   {f}\n", .{first});
        try check(first == try b.next(), "same seed, same id");
        try check(first.timestamp() == 1_000, "timestamp is exactly the clock value");
    }

    var clock = zid.ManualClock{ .value = 1_000 };
    var prng: Prng = .init(7);
    var gen = zid.RandomGenerator(TestKey, zid.ManualClock, Prng).init(.{ .clock = &clock, .random = &prng });

    // Within a millisecond the random bits count up by one.
    const first = try gen.next();
    const second = try gen.next();
    std.debug.print("same millisecond:  {f}\n                   {f}\n", .{ first, second });
    try check(second.random() == first.random() + 1, "random bits count up within a millisecond");

    // A new millisecond draws fresh random bits, with the top bit clear.
    clock.advance(1);
    const third = try gen.next();
    std.debug.print("next millisecond:  {f}\n", .{third});
    try check(third.timestamp() == 1_001, "timestamp follows the clock");
    try check(third.random() <= std.math.maxInt(TestKey.Random) >> 1, "fresh bits start below the top bit");
    try check(third.raw() > second.raw(), "ids still increase");

    // A clock that steps back is an error by default...
    clock.set(900);
    if (gen.next()) |_| return error.CheckFailed else |err| {
        std.debug.print("clock stepped back: {}\n", .{err});
        try check(err == error.ClockMovedBackwards, "a backwards clock is rejected");
    }

    // ...or absorbed, which is what TigerBeetle's clients do.
    {
        var lenient_clock = zid.ManualClock{ .value = 1_000 };
        var lenient_prng: Prng = .init(7);
        var lenient = zid.RandomGenerator(TestKey, zid.ManualClock, Prng).init(.{
            .clock = &lenient_clock,
            .random = &lenient_prng,
            .clock_skew_tolerance_ms = std.math.maxInt(u64),
        });
        const before = try lenient.next();
        lenient_clock.set(0);
        const after = try lenient.next();
        std.debug.print("absorbed step back: {f}\n", .{after});
        try check(after.timestamp() == before.timestamp(), "an absorbed step back keeps the last timestamp");
    }

    // Running out within a millisecond is reported, and the next
    // millisecond starts afresh.
    {
        var tiny_clock = zid.ManualClock{ .value = 1_000 };
        var tiny_prng: Prng = .init(3);
        var tiny = zid.RandomGenerator(TinyKey, zid.ManualClock, Prng).init(.{ .clock = &tiny_clock, .random = &tiny_prng });

        var issued: usize = 0;
        while (tiny.next()) |_| issued += 1 else |err| {
            std.debug.print("tiny field: {d} ids, then {}\n", .{ issued, err });
            try check(err == error.SequenceExhausted, "a full random field is reported");
        }
        try check(issued == 3 or issued == 4, "3 or 4 ids fit, depending on where the millisecond started");

        tiny_clock.advance(1);
        try check((try tiny.next()).timestamp() == 1_001, "a new millisecond recovers");
    }

    // Resuming after a restart: never at or below the id it resumes from.
    {
        var restart_clock = zid.ManualClock{ .value = 1_000 };
        var restart_prng: Prng = .init(99);
        const saved = second; // what the previous run stored
        var resumed = zid.RandomGenerator(TestKey, zid.ManualClock, Prng).initAfter(
            .{ .clock = &restart_clock, .random = &restart_prng },
            saved,
        );
        const next = try resumed.next();
        std.debug.print("resumed after:     {f}\n", .{next});
        try check(next.raw() > saved.raw(), "a resumed generator continues above the saved id");
    }

    std.debug.print("all checks passed\n", .{});
}
