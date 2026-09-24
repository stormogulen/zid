//! Custom epoch offsets for ids.
//!
//! Responsibilities:
//!
//! - Represent the reference point an id's timestamp counts from.
//!
//! Does NOT:
//!
//! - Read clocks.
//! - Know about id layouts or bit widths.
//! - Convert timestamps. The epoch is part of an id type's Config, so
//!   the conversions live on the id type (`OrderedId.unixMillis`,
//!   `OrderedId.timestampFromUnixMillis`), where the layout is known.

const std = @import("std");

/// An epoch is part of an id type's format, so it is always known at
/// compile time. The constructors take compile-time arguments: a value
/// that doesn't fit is a compile error, not a runtime one.
pub const Epoch = struct {
    unix_millis: u64,

    /// The Unix epoch itself: 1970-01-01T00:00:00Z.
    pub const unix: Epoch = .{ .unix_millis = 0 };

    pub fn fromUnixMillis(comptime unix_millis: u64) Epoch {
        return .{ .unix_millis = unix_millis };
    }

    pub fn fromUnixSeconds(comptime unix_seconds: u64) Epoch {
        // Evaluated at compile time: an overflowing value fails the
        // build instead of wrapping.
        return .{ .unix_millis = comptime unix_seconds * std.time.ms_per_s };
    }
};

test "unix epoch has zero offset" {
    try std.testing.expectEqual(0, Epoch.unix.unix_millis);
}

test "fromUnixSeconds converts to milliseconds" {
    const epoch = Epoch.fromUnixSeconds(1_735_689_600);
    try std.testing.expectEqual(1_735_689_600_000, epoch.unix_millis);
}
