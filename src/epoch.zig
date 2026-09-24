//! Custom epoch offsets for id generators.
//!
//! Responsibilities:
//!
//! - Represent a reference point other than the Unix epoch.
//! - Convert between generator-relative timestamps and Unix
//!   milliseconds.
//!
//! Does NOT:
//!
//! - Read clocks.
//! - Know about id layouts or bit widths.

const std = @import("std");
const errors = @import("errors.zig");

pub const Epoch = struct {
    unix_millis: u64,

    /// The Unix epoch itself: 1970-01-01T00:00:00Z.
    pub const unix: Epoch = .{ .unix_millis = 0 };

    pub fn fromUnixMillis(unix_millis: u64) Epoch {
        return .{ .unix_millis = unix_millis };
    }

    pub fn fromUnixSeconds(unix_seconds: u64) errors.OverflowError!Epoch {
        return .{ .unix_millis = try std.math.mul(u64, unix_seconds, std.time.ms_per_s) };
    }
};

test "unix epoch has zero offset" {
    try std.testing.expectEqual(0, Epoch.unix.unix_millis);
}

test "fromUnixSeconds converts to milliseconds" {
    const epoch = try Epoch.fromUnixSeconds(1_735_689_600);
    try std.testing.expectEqual(1_735_689_600_000, epoch.unix_millis);
}

test "fromUnixSeconds rejects values that overflow in milliseconds" {
    try std.testing.expectError(
        error.Overflow,
        Epoch.fromUnixSeconds(std.math.maxInt(u64) / 1000 + 1),
    );
}
