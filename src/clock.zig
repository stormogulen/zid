//! Clock sources for id generators.
//!
//! Responsibilities:
//!
//! - Provide millisecond-resolution Unix timestamps.
//!
//! Does NOT:
//!
//! - Interpret, validate, or bound timestamps.
//! - Know about id layouts.

const std = @import("std");

/// Reads the wall clock on every call. Follows every change to the
/// system time, including NTP corrections and manual changes, so it can
/// go backwards; a Generator then reports `error.ClockMovedBackwards`
/// until real time catches up. Prefer `MonotonicClock` unless ids must
/// track the system time exactly.
pub const SystemClock = struct {
    io: std.Io,

    pub fn init(io: std.Io) SystemClock {
        return .{ .io = io };
    }

    pub fn now(self: *SystemClock) u64 {
        return wallMillis(self.io);
    }
};

/// Wall-clock milliseconds that never go backwards.
///
/// Reads the wall clock once, at init, and from then on adds the time
/// measured by a monotonic clock. A later NTP step or manual change of
/// the system time doesn't affect it, so a Generator using it never sees
/// time run backwards within the process.
///
/// Trade-off: any difference in rate between the two clocks accumulates
/// over the lifetime of the clock. It is normally tiny; create a new
/// clock (for example at restart) to re-anchor it to the wall clock.
/// Re-anchoring can land *behind* ids an earlier clock already produced,
/// so resume a restarted generator with `Generator.initAfter` instead of
/// relying on the new clock alone.
pub const MonotonicClock = struct {
    io: std.Io,
    wall_at_start: u64,
    start: std.Io.Timestamp,

    pub fn init(io: std.Io) MonotonicClock {
        return .{
            .io = io,
            .wall_at_start = wallMillis(io),
            // `.boot` intends to include time the system is suspended,
            // so the clock doesn't fall behind across a laptop sleep.
            .start = .now(io, .boot),
        };
    }

    pub fn now(self: *MonotonicClock) u64 {
        const elapsed = nanosToMillis(self.start.untilNow(self.io, .boot).toNanoseconds());
        return self.wall_at_start +| elapsed;
    }
};

/// A clock the caller sets by hand, for deterministic tests.
pub const ManualClock = struct {
    value: u64 = 0,

    pub fn now(self: *ManualClock) u64 {
        return self.value;
    }

    pub fn set(self: *ManualClock, value: u64) void {
        self.value = value;
    }

    pub fn advance(self: *ManualClock, amount: u64) void {
        // Saturating: a test that advances near the end of u64 gets a
        // clock stuck at the maximum, not an overflow panic.
        self.value +|= amount;
    }
};

fn wallMillis(io: std.Io) u64 {
    return nanosToMillis(std.Io.Clock.now(.real, io).nanoseconds);
}

/// Clock readings come from the operating system, so they are input,
/// not something to assert on. The wall clock is settable and can read
/// before 1970; clamp instead of trusting it. A clamped reading then
/// shows up as a proper error from the generator (`BeforeEpoch`,
/// `ClockMovedBackwards` or `TimestampOverflow`), never as a crash or
/// undefined behaviour.
fn nanosToMillis(nanoseconds: i96) u64 {
    return std.math.lossyCast(u64, @divTrunc(nanoseconds, std.time.ns_per_ms));
}

test "SystemClock reads the wall clock" {
    const io = std.testing.io;
    var system = SystemClock.init(io);

    // The wall clock can be stepped (by NTP, say) mid-test; that is the
    // only way these can fail.
    const before = wallMillis(io);
    const reading = system.now();
    const after = wallMillis(io);
    try std.testing.expect(before <= reading);
    try std.testing.expect(reading <= after);
}

test "MonotonicClock starts at the wall clock and never goes backwards" {
    const io = std.testing.io;

    const wall_before = wallMillis(io);
    var clock = MonotonicClock.init(io);
    const wall_after = wallMillis(io);

    var previous = clock.now();
    try std.testing.expect(previous >= wall_before);
    try std.testing.expect(previous <= wall_after + 1);

    for (0..1000) |_| {
        const current = clock.now();
        try std.testing.expect(current >= previous);
        previous = current;
    }
}

test "clock readings outside u64 milliseconds are clamped, not trusted" {
    try std.testing.expectEqual(0, nanosToMillis(-5 * std.time.ns_per_ms)); // Before 1970.
    try std.testing.expectEqual(0, nanosToMillis(-1));
    try std.testing.expectEqual(1_234, nanosToMillis(1_234 * std.time.ns_per_ms + 999));
    try std.testing.expectEqual(std.math.maxInt(u64), nanosToMillis(std.math.maxInt(i96)));
}

test "ManualClock.advance saturates instead of overflowing" {
    var manual = ManualClock{ .value = std.math.maxInt(u64) - 1 };
    manual.advance(5);
    try std.testing.expectEqual(std.math.maxInt(u64), manual.now());

    manual.set(10);
    manual.advance(5);
    try std.testing.expectEqual(15, manual.now());
}
