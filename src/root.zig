//! zid public API.

const ordered_id = @import("ordered/ordered.zig");
const layout = @import("ordered/layout.zig");
const generator_mod = @import("generator.zig");
const clock_mod = @import("clock.zig");
const errors_mod = @import("errors.zig");
const epoch_mod = @import("epoch.zig");
const encoding_mod = @import("encoding.zig");

pub const OrderedId = ordered_id.OrderedId;
pub const Config = layout.Config;

pub const Generator = generator_mod.Generator;
pub const Epoch = epoch_mod.Epoch;

pub const SystemClock = clock_mod.SystemClock;
pub const ManualClock = clock_mod.ManualClock;

pub const NextError = errors_mod.NextError;
pub const RawError = errors_mod.RawError;
pub const ParseError = errors_mod.ParseError;
pub const DecodeError = encoding_mod.DecodeError;
pub const OverflowError = errors_mod.OverflowError;

test {
    _ = @import("ordered/layout.zig");
    _ = @import("ordered/ordered.zig");
    _ = @import("generator.zig");
    _ = @import("clock.zig");
    _ = @import("epoch.zig");
    _ = @import("encoding.zig");
}
