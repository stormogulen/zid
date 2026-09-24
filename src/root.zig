//! zid public API.

const layout = @import("ordered/layout.zig");
const generator = @import("generator.zig");
const clock = @import("clock.zig");
const errors = @import("errors.zig");
const epoch = @import("epoch.zig");
const encoding = @import("encoding.zig");

pub const OrderedId = @import("ordered/id.zig").OrderedId;
pub const Config = layout.Config;

pub const Generator = generator.Generator;
pub const Epoch = epoch.Epoch;

pub const SystemClock = clock.SystemClock;
pub const MonotonicClock = clock.MonotonicClock;
pub const ManualClock = clock.ManualClock;

pub const TimestampError = errors.TimestampError;
pub const NextError = errors.NextError;
pub const ResumeError = errors.ResumeError;
pub const RawError = errors.RawError;
pub const ParseError = errors.ParseError;
pub const DecodeError = encoding.DecodeError;
pub const OverflowError = errors.OverflowError;

test {
    _ = @import("ordered/layout.zig");
    _ = @import("ordered/id.zig");
    _ = @import("generator.zig");
    _ = @import("clock.zig");
    _ = @import("epoch.zig");
    _ = @import("encoding.zig");
    _ = @import("properties.zig");
}
