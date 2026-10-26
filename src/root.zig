//! zid public API.

const layout = @import("ordered/layout.zig");
const generator = @import("generator.zig");
const atomic_generator = @import("atomic_generator.zig");
const target = @import("target.zig");
const wait = @import("wait.zig");
const clock = @import("clock.zig");
const errors = @import("errors.zig");
const epoch = @import("epoch.zig");
const encoding = @import("encoding.zig");

pub const OrderedId = @import("ordered/id.zig").OrderedId;
pub const Config = layout.Config;

pub const Generator = generator.Generator;
pub const AtomicGenerator = atomic_generator.AtomicGenerator;
/// Whether `AtomicGenerator` can be used on the target being compiled
/// for (it needs 64-bit atomics). Code that builds for both 32- and
/// 64-bit targets can pick a generator with it at compile time.
pub const atomic_generator_supported = target.has_64_bit_atomics;
pub const SpinWait = wait.SpinWait;
pub const Epoch = epoch.Epoch;

pub const SystemClock = clock.SystemClock;
pub const MonotonicClock = clock.MonotonicClock;
pub const ManualClock = clock.ManualClock;
pub const UnixMillis = clock.UnixMillis;

pub const FieldError = errors.FieldError;
pub const TimestampError = errors.TimestampError;
pub const NextError = errors.NextError;
pub const ResumeError = errors.ResumeError;
pub const RawError = errors.RawError;
pub const ParseError = errors.ParseError;
pub const DecodeError = encoding.DecodeError;

test {
    _ = @import("ordered/layout.zig");
    _ = @import("ordered/id.zig");
    _ = @import("generator.zig");
    // On 32-bit targets AtomicGenerator is a compile error by design, so
    // its tests are left out there and the rest still compiles.
    if (target.has_64_bit_atomics) _ = @import("atomic_generator.zig");
    _ = @import("target.zig");
    _ = @import("wait.zig");
    _ = @import("clock.zig");
    _ = @import("epoch.zig");
    _ = @import("encoding.zig");
    _ = @import("properties.zig");
}
