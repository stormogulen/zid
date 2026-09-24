//! Sequential id generator.
//!
//! Responsibilities:
//!
//! - Combine a clock, a node id, and a sequence counter into ids.
//! - Guarantee ids increase monotonically for a fixed node,
//!   as long as the clock does not move backwards.
//! - Detect sequence exhaustion within a millisecond and report it,
//!   rather than silently wrapping and colliding.
//! - Measure timestamps relative to a configurable epoch, and
//!   convert back to Unix milliseconds on request.
//!
//! Does NOT:
//!
//! - Read wall-clock time directly (delegates to ClockType).
//! - Retry, sleep, or spin on exhaustion (caller's decision).
//! - Coordinate node ids across processes.
//! - Guarantee correctness across threads (not thread-safe).

const std = @import("std");
const errors = @import("errors.zig");
const epoch_mod = @import("epoch.zig");
const ordered = @import("ordered/ordered.zig");
const clock = @import("clock.zig");

pub fn Generator(
    comptime IdType: type,
    comptime ClockType: type,
) type {
    comptime {
        if (!isContainer(IdType) or !@hasDecl(IdType, "Layout") or !@hasDecl(IdType, "fromParts")) {
            @compileError("Generator's IdType must be a zid.OrderedId type, found " ++ @typeName(IdType));
        }

        if (!isContainer(ClockType) or !@hasDecl(ClockType, "now")) {
            @compileError("Generator's ClockType must provide `pub fn now(self: *" ++
                @typeName(ClockType) ++ ") u64`");
        }

        const now_fn = @typeInfo(@TypeOf(ClockType.now)).@"fn";
        if (now_fn.return_type != u64) {
            @compileError(@typeName(ClockType) ++ ".now must return u64 milliseconds");
        }
    }

    const Timestamp = IdType.Timestamp;
    const Sequence = IdType.Sequence;

    return struct {
        const Self = @This();

        pub const Node = IdType.Node;
        pub const NextError = errors.NextError;

        clock: *ClockType,
        node: Node,
        epoch: epoch_mod.Epoch,
        /// The most recently returned id, or null before the first
        /// call to next(). Its timestamp and sequence are all the
        /// state the generator needs.
        last: ?IdType = null,

        pub const Options = struct {
            /// Sized to the layout's node field, so an out-of-range
            /// node can't be passed. Convert a runtime integer at the
            /// boundary with `std.math.cast(Node, value)`.
            node: Node,
            clock: *ClockType,
            epoch: epoch_mod.Epoch = .unix,
        };

        pub fn init(options: Options) Self {
            return .{
                .clock = options.clock,
                .node = options.node,
                .epoch = options.epoch,
            };
        }

        pub fn next(self: *Self) NextError!IdType {
            const now = self.clock.now();

            if (now < self.epoch.unix_millis) {
                return error.ClockBeforeEpoch;
            }

            const timestamp = std.math.cast(Timestamp, now - self.epoch.unix_millis) orelse
                return error.TimestampOverflow;

            const sequence: Sequence = if (self.last) |last| sequence: {
                const last_timestamp = last.timestamp();

                if (timestamp < last_timestamp) {
                    return error.ClockMovedBackwards;
                }
                if (timestamp > last_timestamp) {
                    break :sequence 0;
                }
                if (last.sequence() == std.math.maxInt(Sequence)) {
                    return error.SequenceExhausted;
                }
                break :sequence last.sequence() + 1;
            } else 0;

            const id = IdType.fromParts(.{
                .timestamp = timestamp,
                .node = self.node,
                .sequence = sequence,
            });

            // The generator's core promise: for a fixed node, ids
            // strictly increase.
            if (self.last) |last| std.debug.assert(id.raw() > last.raw());

            self.last = id;
            return id;
        }

        /// Converts an id's decoded (epoch-relative) timestamp back
        /// into Unix milliseconds, using this generator's epoch.
        pub fn unixMillis(self: Self, id: IdType) errors.OverflowError!u64 {
            return std.math.add(u64, id.timestamp(), self.epoch.unix_millis);
        }
    };
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

const TestId = ordered.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
});

test "first id starts at sequence zero" {
    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    const id = try gen.next();

    try std.testing.expectEqual(1000, id.timestamp());
    try std.testing.expectEqual(0, id.sequence());
}

test "sequence increments within the same millisecond" {
    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    const first = try gen.next();
    const second = try gen.next();

    try std.testing.expectEqual(first.timestamp(), second.timestamp());
    try std.testing.expectEqual(0, first.sequence());
    try std.testing.expectEqual(1, second.sequence());
}

test "sequence exhaustion is reported, not silently wrapped" {

    // sequence_bits = 1 means max_sequence == 1.
    const TinySequenceId = ordered.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 1,
        .tag = struct {},
    });

    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(TinySequenceId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    _ = try gen.next(); // sequence 0
    _ = try gen.next(); // sequence 1, field now full

    try std.testing.expectError(
        error.SequenceExhausted,
        gen.next(),
    );

    // Advancing the clock
    // NOTE: Generator holds a *pointer* to this ManualClock, not a copy.
    manual.advance(1);

    const id = try gen.next();
    try std.testing.expectEqual(1001, id.timestamp());
    try std.testing.expectEqual(0, id.sequence());
}

test "clock moving backwards is rejected" {
    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    _ = try gen.next();
    manual.set(500);

    try std.testing.expectError(
        error.ClockMovedBackwards,
        gen.next(),
    );
}

test "custom epoch offsets stored timestamp; unixMillis recovers it" {
    var manual = clock.ManualClock{ .value = 1_700_000_500 };

    var gen = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
        .epoch = epoch_mod.Epoch.fromUnixMillis(1_700_000_000),
    });

    const id = try gen.next();

    try std.testing.expectEqual(500, id.timestamp());
    try std.testing.expectEqual(1_700_000_500, try gen.unixMillis(id));
}

test "clock reading before the epoch is rejected" {
    var manual = clock.ManualClock{ .value = 100 };

    var gen = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
        .epoch = epoch_mod.Epoch.fromUnixMillis(1_000),
    });

    try std.testing.expectError(error.ClockBeforeEpoch, gen.next());
}

test "clock reading exactly at the epoch yields timestamp zero" {
    var manual = clock.ManualClock{ .value = 1_000 };
    var gen = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
        .epoch = epoch_mod.Epoch.fromUnixMillis(1_000),
    });

    const id = try gen.next();
    try std.testing.expectEqual(0, id.timestamp());
}

test "timestamp overflow is rejected" {

    // timestamp_bits = 2 means max_timestamp == 3.
    const TinyTimestampId = ordered.OrderedId(.{
        .timestamp_bits = 2,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    // One past max_timestamp (3), with the default unix epoch (offset 0),
    // so the epoch-relative timestamp equals the clock value directly.
    var manual = clock.ManualClock{ .value = 4 };

    var gen = Generator(TinyTimestampId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    try std.testing.expectError(
        error.TimestampOverflow,
        gen.next(),
    );
}

test "a layout without sequence bits allows one id per millisecond" {
    const NoSequenceId = ordered.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 0,
        .tag = struct {},
    });

    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(NoSequenceId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    _ = try gen.next();
    try std.testing.expectError(error.SequenceExhausted, gen.next());

    manual.advance(1);
    _ = try gen.next();
}

test "unixMillis reports overflow instead of wrapping" {
    var manual = clock.ManualClock{};
    const gen = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
        .epoch = .fromUnixMillis(std.math.maxInt(u64) - 10),
    });

    const id = TestId.fromParts(.{ .timestamp = 11, .node = 1, .sequence = 0 });
    try std.testing.expectError(error.Overflow, gen.unixMillis(id));
}
