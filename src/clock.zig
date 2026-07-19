//! Clock sources for id generators.
//!
//! Responsibilities:
//!
//! - Provide millisecond-resolution timestamps.
//!
//! Does NOT:
//!
//! - Interpret, validate, or bound timestamps.
//! - Know about id layouts.

const std = @import("std");

pub const SystemClock = struct {
    io: std.Io,

    pub fn init(io: std.Io) SystemClock {
        return .{ .io = io };
    }

    pub fn now(self: *SystemClock) u64 {
        const timestamp = std.Io.Clock.now(.real, self.io);

        return @intCast(
            @divTrunc(timestamp.nanoseconds, std.time.ns_per_ms),
        );
    }
};

pub const ManualClock = struct {
    value: u64 = 0,

    pub fn now(self: *ManualClock) u64 {
        return self.value;
    }

    pub fn set(self: *ManualClock, value: u64) void {
        self.value = value;
    }

    pub fn advance(self: *ManualClock, amount: u64) void {
        self.value += amount;
    }
};
