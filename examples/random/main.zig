//! RandomOrderedId: time-ordered ids that need no node id.
//!
//!     zig build run-random

const std = @import("std");
const zid = @import("zid");

// TigerBeetle's and ULID's layout: 48 timestamp bits, 80 random bits.
// With a 2025 epoch the timestamp lasts about 8,900 years.
const OrderKey = zid.RandomOrderedId(.{
    .timestamp_bits = 48,
    .random_bits = 80,
    .tag = struct {},
    .epoch = .fromUnixMillis(1_735_689_600_000), // 2025-01-01T00:00:00Z
    .name = "OrderKey",
});

pub fn main(init: std.process.Init) !void {
    var clock = zid.MonotonicClock.init(init.io);
    var random = zid.IoRandom.init(init.io);

    // Two generators, as two processes would have: no node ids to assign.
    var a = zid.RandomGenerator(OrderKey, zid.MonotonicClock, zid.IoRandom).init(.{
        .clock = &clock,
        .random = &random,
    });
    var b = zid.RandomGenerator(OrderKey, zid.MonotonicClock, zid.IoRandom).init(.{
        .clock = &clock,
        .random = &random,
    });

    for (0..3) |_| {
        const from_a = try a.nextRetrying(zid.SpinWait{});
        const from_b = try b.nextRetrying(zid.SpinWait{});
        std.debug.print("a: {f}  {f}\n", .{ from_a.fmtString(), from_a });
        std.debug.print("b: {f}  {f}\n", .{ from_b.fmtString(), from_b });
    }

    // Within one generator and one millisecond, the random bits count up.
    const first = try a.nextRetrying(zid.SpinWait{});
    const second = try a.nextRetrying(zid.SpinWait{});
    std.debug.print("\nsame generator, consecutive: {f} then {f}\n", .{ first.fmtString(), second.fmtString() });
    std.debug.print("second > first: {}\n", .{second.order(first) == .gt});
}
