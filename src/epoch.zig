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

pub const Epoch = struct {
    unix_millis: u64,

    pub fn unix() Epoch {
        return .{ .unix_millis = 0 };
    }

    pub fn fromUnixMillis(unix_millis: u64) Epoch {
        return .{ .unix_millis = unix_millis };
    }

    pub fn fromUnixSeconds(unix_seconds: u64) Epoch {
        return .{ .unix_millis = unix_seconds * std.time.ms_per_s };
    }
};

const std = @import("std");

test "unix epoch has zero offset" {
    try std.testing.expectEqual(
        @as(u64, 0),
        Epoch.unix().unix_millis,
    );
}
