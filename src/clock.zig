//! Clock sources for id generators.
//!
//! Responsibilities:
//!
//! - Provide millisecond-resolution Unix timestamps, as `UnixMillis`.
//! - Convert operating-system nanoseconds to milliseconds, in one place.
//!
//! Does NOT:
//!
//! - Interpret, validate, or bound timestamps.
//! - Know about id layouts.

const std = @import("std");

/// A point in time: milliseconds since 1970-01-01T00:00:00Z. What every
/// clock's `now` returns. A struct rather than a bare u64 so that the unit
/// is written wherever a reading is made: a clock says `.{ .millis = ... }`
/// or `UnixMillis.fromNanoseconds(...)`, and a reading in seconds or
/// nanoseconds can't be handed to a generator by accident.
pub const UnixMillis = struct {
    millis: u64,

    /// From an operating-system reading in nanoseconds since 1970.
    ///
    /// Clock readings are input, not something to assert on. The wall
    /// clock is settable and can read before 1970; clamp instead of
    /// trusting it. The clamped reading is 0, which is a valid Unix time,
    /// so it is not an error by itself. What the generator does with it
    /// depends on its state: a generator that has already issued ids
    /// reports `ClockMovedBackwards`; an id type with an epoch after 1970
    /// reports `BeforeEpoch`; a fresh generator whose epoch is `.unix`
    /// issues ids at timestamp 0. Never a crash or undefined behaviour.
    /// Use `initAfter` or `initAfterTimestamp` on restart to rule out the
    /// last case.
    pub fn fromNanoseconds(nanoseconds: i96) UnixMillis {
        return .{ .millis = nanosToMillis(nanoseconds) };
    }
};

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

    pub fn now(self: *SystemClock) UnixMillis {
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
/// Initialization is best-effort. The wall clock is read between two
/// monotonic readings and taken to lie in the middle of the gap between
/// them, so the anchor is within half that gap of the true wall time,
/// plus under 1 ms from rounding to whole milliseconds. Init retries up
/// to 8 times for a gap under 1 ms and otherwise keeps the tightest
/// attempt, so a small bound is likely but not guaranteed. (It is only
/// large if the thread was suspended during init.)
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
        // The wall clock is read between two monotonic readings, so the
        // gap between them bounds how far the anchor can be off: if the
        // thread is suspended mid-init, the gap is large and we try again
        // instead of keeping a skewed anchor for the clock's lifetime.
        // The wall reading is taken to lie in the middle of the gap.
        // After a few unlucky attempts the tightest one is used.
        const max_attempts = 8;
        const tight_gap_ns = std.time.ns_per_ms;

        var best = anchor(io);
        var attempts: usize = 1;
        while (best.gap_ns >= tight_gap_ns and attempts < max_attempts) : (attempts += 1) {
            const candidate = anchor(io);
            if (candidate.gap_ns < best.gap_ns) best = candidate;
        }
        return best.clock;
    }

    /// One bracketed reading: a clock anchored to the wall time, and how
    /// wide the monotonic gap around the wall reading was.
    const Anchor = struct {
        clock: MonotonicClock,
        gap_ns: i96,
    };

    fn anchor(io: std.Io) Anchor {
        // `.boot` intends to include time the system is suspended,
        // so the clock doesn't fall behind across a laptop sleep.
        const start: std.Io.Timestamp = .now(io, .boot);
        const wall_ns = std.Io.Clock.now(.real, io).nanoseconds;
        const gap_ns = start.untilNow(io, .boot).toNanoseconds();
        return .{
            .clock = .{
                .io = io,
                .wall_at_start = anchorMillis(wall_ns, gap_ns),
                .start = start,
            },
            .gap_ns = gap_ns,
        };
    }

    pub fn now(self: *MonotonicClock) UnixMillis {
        const elapsed = nanosToMillis(self.start.untilNow(self.io, .boot).toNanoseconds());
        return .{ .millis = self.wall_at_start +| elapsed };
    }
};

/// A clock the caller sets by hand, for deterministic tests.
pub const ManualClock = struct {
    value: u64 = 0,

    pub fn now(self: *ManualClock) UnixMillis {
        return .{ .millis = self.value };
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

fn wallMillis(io: std.Io) UnixMillis {
    return .fromNanoseconds(std.Io.Clock.now(.real, io).nanoseconds);
}

/// The one nanoseconds-to-milliseconds conversion, for points in time
/// (`UnixMillis.fromNanoseconds`) and durations (`MonotonicClock`) alike.
/// Rounds down; clamps below 0 and above the u64 range.
/// The wall time at the first monotonic reading of a bracketed sample:
/// the wall reading, taken to lie in the middle of the gap, minus half the
/// gap. In nanoseconds, converted once at the end, so the correction is
/// exact instead of rounded to whole milliseconds. Pure, so it can be
/// tested with any readings; clamped like every clock reading.
fn anchorMillis(wall_ns: i96, gap_ns: i96) u64 {
    return nanosToMillis(wall_ns - @divTrunc(gap_ns, 2));
}

fn nanosToMillis(nanoseconds: i96) u64 {
    return std.math.lossyCast(u64, @divTrunc(nanoseconds, std.time.ns_per_ms));
}

test "SystemClock reads the wall clock" {
    const io = std.testing.io;
    var system = SystemClock.init(io);

    // The wall clock can be stepped (by NTP, say) mid-test; that is the
    // only way these can fail.
    const before = wallMillis(io).millis;
    const reading = system.now().millis;
    const after = wallMillis(io).millis;
    try std.testing.expect(before <= reading);
    try std.testing.expect(reading <= after);
}

test "MonotonicClock starts at the wall clock and never goes backwards" {
    const io = std.testing.io;

    const wall_before = wallMillis(io).millis;
    var clock = MonotonicClock.init(io);
    const wall_after = wallMillis(io).millis;

    var previous = clock.now().millis;

    // The anchor is placed in the middle of a bracketed reading, so it can
    // sit up to a millisecond either side of the wall readings around init.
    try std.testing.expect(previous + 1 >= wall_before);
    try std.testing.expect(previous <= wall_after + 1);

    for (0..1000) |_| {
        const current = clock.now().millis;
        try std.testing.expect(current >= previous);
        previous = current;
    }
}

test "UnixMillis.fromNanoseconds clamps like the clocks do" {
    try std.testing.expectEqual(0, UnixMillis.fromNanoseconds(-1).millis);
    try std.testing.expectEqual(1_234, UnixMillis.fromNanoseconds(1_234 * std.time.ns_per_ms + 999).millis);
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
    try std.testing.expectEqual(std.math.maxInt(u64), manual.now().millis);

    manual.set(10);
    manual.advance(5);
    try std.testing.expectEqual(15, manual.now().millis);
}

test "anchorMillis: half the gap is subtracted, in nanoseconds" {
    const ns_per_ms = std.time.ns_per_ms;

    // No gap: the wall reading is the anchor.
    try std.testing.expectEqual(5_000, anchorMillis(5_000 * ns_per_ms, 0));

    // A sub-millisecond gap still moves the anchor: 5000.1 ms read inside
    // a 0.4 ms gap puts the wall time at the first reading at 4999.9 ms.
    // Correcting in whole milliseconds would have kept 5000.
    try std.testing.expectEqual(4_999, anchorMillis(5_000 * ns_per_ms + 100_000, 400_000));

    // Exactly one millisecond: half of it.
    try std.testing.expectEqual(4_999, anchorMillis(5_000 * ns_per_ms, ns_per_ms));

    // A large gap (the thread was suspended during init).
    try std.testing.expectEqual(9_998, anchorMillis(10_000 * ns_per_ms, 4 * ns_per_ms));

    // Near and before 1970: clamped to 0, never wrapped.
    try std.testing.expectEqual(0, anchorMillis(ns_per_ms, 10 * ns_per_ms));
    try std.testing.expectEqual(0, anchorMillis(-5 * ns_per_ms, 0));
}
