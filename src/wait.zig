//! Waiters for `Generator.nextRetrying`.
//!
//! Responsibilities:
//!
//! - Provide a ready-made busy-wait for sequence exhaustion.
//!
//! Does NOT:
//!
//! - Sleep or yield to a scheduler. A sequence runs out for under a
//!   millisecond, so spinning is usually cheaper than a context switch.
//!   The exception is a generator with a nonzero
//!   `clock_skew_tolerance_ms` that is running ahead of its clock: the
//!   wait can then last up to the tolerance, and a sleeping waiter is
//!   the better choice. Bring your own waiter (anything with
//!   `wait(self)`) to sleep instead.

const std = @import("std");

/// Busy-waits with a CPU relax hint.
pub const SpinWait = struct {
    pub fn wait(self: SpinWait) void {
        _ = self;
        std.atomic.spinLoopHint();
    }
};

test "SpinWait returns" {
    const waiter: SpinWait = .{};
    waiter.wait();
}
