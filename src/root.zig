//! zid public API.

const ordered_id =
    @import("ordered/ordered.zig");
const layout =
    @import("ordered/layout.zig");
const generator_mod =
    @import("generator.zig");
const clock_mod =
    @import("clock.zig");
const errors_mod =
    @import("errors.zig");

const epoch_mod =
    @import("epoch.zig");

pub const Epoch =
    epoch_mod.Epoch;

pub const OrderedId =
    ordered_id.OrderedId;
pub const Config =
    layout.Config;
pub const Parts =
    layout.Parts;

pub const Generator =
    generator_mod.Generator;
pub const SystemClock =
    clock_mod.SystemClock;
pub const ManualClock =
    clock_mod.ManualClock;
pub const Error =
    errors_mod.Error;

test {
    _ = @import("ordered/layout.zig");
    _ = @import("ordered/ordered.zig");
    _ = @import("generator.zig");
    _ = @import("clock.zig");
    _ = @import("epoch.zig");
    _ = @import("encoding.zig");
}
