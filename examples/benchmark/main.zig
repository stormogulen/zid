// Measures two different things, because a Snowflake-style generator
// has two different limits:
//
// 1. Generator cost: how fast next() itself is. Uses ManualClock and
//    advances it by hand whenever a millisecond's sequence is used up,
//    so the numbers are pure CPU cost, with no waiting on real time.
//
// 2. Real throughput: how many ids per second you actually get under a
//    SystemClock. With 12 sequence bits this is capped at 4096 ids per
//    millisecond (about 4.1 million per second), however fast next()
//    is. When a millisecond is used up, the loop simply retries until
//    the clock moves on, and counts how often that happened.
//
// Run it optimized, or you are measuring Debug safety checks:
//
//     zig build run-benchmark -Doptimize=ReleaseFast

const std = @import("std");
const builtin = @import("builtin");
const zid = @import("zid");

const BenchId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
});

const iterations = 10_000_000;

const Result = struct {
    elapsed_ns: u64,
    exhausted_retries: u64,
};

fn benchGeneratorCost(io: std.Io) !Result {
    var clock = zid.ManualClock{ .value = 1_000 };
    var gen = zid.Generator(BenchId, zid.ManualClock).init(.{
        .node = 1,
        .clock = &clock,
    });

    var exhausted_retries: u64 = 0;
    const start = std.Io.Timestamp.now(io, .awake);

    var generated: u64 = 0;
    while (generated < iterations) {
        const id = gen.next() catch |err| switch (err) {
            error.SequenceExhausted => {
                clock.advance(1);
                exhausted_retries += 1;
                continue;
            },
            error.BeforeEpoch,
            error.TimestampOverflow,
            error.ClockMovedBackwards,
            => return err,
        };
        std.mem.doNotOptimizeAway(id);
        generated += 1;
    }

    return .{
        .elapsed_ns = elapsedNs(start, io),
        .exhausted_retries = exhausted_retries,
    };
}

fn benchRealThroughput(io: std.Io) !Result {
    var clock = zid.SystemClock.init(io);
    var gen = zid.Generator(BenchId, zid.SystemClock).init(.{
        .node = 1,
        .clock = &clock,
    });

    var exhausted_retries: u64 = 0;
    const start = std.Io.Timestamp.now(io, .awake);

    var generated: u64 = 0;
    while (generated < iterations) {
        const id = gen.next() catch |err| switch (err) {
            // The millisecond is full. Retry until the clock moves on:
            // that wait is part of what this benchmark measures.
            error.SequenceExhausted => {
                exhausted_retries += 1;
                continue;
            },
            error.BeforeEpoch,
            error.TimestampOverflow,
            error.ClockMovedBackwards,
            => return err,
        };
        std.mem.doNotOptimizeAway(id);
        generated += 1;
    }

    return .{
        .elapsed_ns = elapsedNs(start, io),
        .exhausted_retries = exhausted_retries,
    };
}

fn elapsedNs(start: std.Io.Timestamp, io: std.Io) u64 {
    const elapsed = start.untilNow(io, .awake).toNanoseconds();
    // The awake clock is monotonic, so time can't run backwards, and
    // at least one nanosecond keeps the divisions below safe.
    return @max(1, @as(u64, @intCast(elapsed)));
}

fn report(writer: *std.Io.Writer, name: []const u8, result: Result) !void {
    const ns_per_id = @as(f64, @floatFromInt(result.elapsed_ns)) / iterations;
    const ids_per_second = @as(f64, iterations) * std.time.ns_per_s / @as(f64, @floatFromInt(result.elapsed_ns));

    try writer.print("{s}\n", .{name});
    try writer.print("  total:       {d} ms\n", .{result.elapsed_ns / std.time.ns_per_ms});
    try writer.print("  per id:      {d:.2} ns\n", .{ns_per_id});
    try writer.print("  throughput:  {d:.0} ids/s\n", .{ids_per_second});
    try writer.print("  exhausted:   {d} retries\n\n", .{result.exhausted_retries});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const writer = &stdout.interface;

    if (builtin.mode == .Debug) {
        try writer.print("warning: Debug build, numbers include safety checks. Use -Doptimize=ReleaseFast.\n\n", .{});
    }
    try writer.print("Generating {d} ids per benchmark...\n\n", .{iterations});
    try writer.flush();

    try report(writer, "Generator cost (ManualClock)", try benchGeneratorCost(io));
    try writer.flush();

    try report(writer, "Real throughput (SystemClock)", try benchRealThroughput(io));
    try writer.flush();
}
