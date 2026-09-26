//! Sequential id generator.
//!
//! Responsibilities:
//!
//! - Combine a clock, a node id, and a sequence counter into ids.
//! - Guarantee ids increase monotonically for a fixed node,
//!   as long as the clock does not move backwards.
//! - Detect sequence exhaustion within a millisecond and report it,
//!   rather than silently wrapping and colliding.
//! - Resume after an id issued earlier (for example by a previous run
//!   of the process), never issuing one at or below it.
//!
//! Does NOT:
//!
//! - Read wall-clock time directly (delegates to ClockType).
//! - Retry, sleep, or spin on exhaustion (caller's decision).
//! - Coordinate node ids across processes.
//! - Persist the last issued id (the caller stores it and passes it
//!   to initAfter).
//! - Guarantee correctness across threads (not thread-safe).

const std = @import("std");
const errors = @import("errors.zig");
const OrderedId = @import("ordered/id.zig").OrderedId;
const clock = @import("clock.zig");

pub fn Generator(
    comptime IdType: type,
    comptime ClockType: type,
) type {
    comptime {
        if (!isContainer(IdType) or !@hasDecl(IdType, "Layout") or !@hasDecl(IdType, "fromParts") or !@hasDecl(IdType, "timestampFromUnixMillis")) {
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

    const Sequence = IdType.Sequence;

    return struct {
        const Self = @This();

        pub const Node = IdType.Node;
        pub const Timestamp = IdType.Timestamp;
        pub const NextError = errors.NextError;

        // Internal state. Zig has no private fields, so these are
        // visible, but they are not part of the API: construct with
        // init/initAfter and never write them afterwards. Changing
        // `last` or `node` directly can break the monotonicity and
        // uniqueness guarantees.

        clock: *ClockType,
        node: Node,
        /// The most recently returned id, or null before the first
        /// call to next(). Its timestamp and sequence are all the
        /// state the generator needs.
        last: ?IdType = null,

        pub const Options = struct {
            /// Sized to the layout's node field, so an out-of-range
            /// node can't be passed. Convert a runtime integer at the
            /// boundary with `std.math.cast(Node, value)`.
            node: Node,
            /// Borrowed, not copied: the clock must outlive the
            /// generator. Don't return a generator from a function that
            /// owns the clock as a local variable. A pointer (rather
            /// than a copy) is what lets a test move a ManualClock from
            /// outside.
            clock: *ClockType,
        };

        pub fn init(options: Options) Self {
            return .{
                .clock = options.clock,
                .node = options.node,
            };
        }

        /// Like init, but continues after `last`, an id this node issued
        /// earlier: every id from the new generator is greater than it.
        /// If the clock is behind `last` (for example after a restart
        /// with a clock that was set back), next() reports
        /// `error.ClockMovedBackwards` instead of issuing duplicates.
        pub fn initAfter(options: Options, last: IdType) errors.ResumeError!Self {
            if (last.node() != options.node) {
                return error.NodeMismatch;
            }

            var self = init(options);
            self.last = last;
            return self;
        }

        pub fn next(self: *Self) NextError!IdType {
            const timestamp = try IdType.timestampFromUnixMillis(self.clock.now());

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
            // strictly increase. A real check, not `std.debug.assert`: a
            // failed assert is undefined behaviour in ReleaseFast, and zid
            // doesn't choose the caller's build mode. A crash beats
            // silently handing out a duplicate id. Costs one branch.
            if (self.last) |last| {
                if (id.raw() <= last.raw()) {
                    @panic("zid: generator issued an id that is not greater than the last");
                }
            }

            self.last = id;
            return id;
        }
    };
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

const TestId = OrderedId(.{
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
    const TinySequenceId = OrderedId(.{
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

test "clock reading before the epoch is rejected" {
    const EpochId = OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
        .epoch = .fromUnixMillis(1_000),
    });

    var manual = clock.ManualClock{ .value = 100 };
    var gen = Generator(EpochId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });
    try std.testing.expectError(error.BeforeEpoch, gen.next());

    // Exactly at the epoch is timestamp zero.
    manual.set(1_000);
    try std.testing.expectEqual(0, (try gen.next()).timestamp());
}

test "timestamp overflow is rejected" {

    // timestamp_bits = 2 means max_timestamp == 3.
    const TinyTimestampId = OrderedId(.{
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
    const NoSequenceId = OrderedId(.{
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

test "initAfter continues after the last id instead of repeating it" {
    var manual = clock.ManualClock{ .value = 1000 };
    var first_run = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });
    _ = try first_run.next();
    const last = try first_run.next(); // timestamp 1000, sequence 1

    // A restart within the same millisecond.
    var second_run = try Generator(TestId, clock.ManualClock).initAfter(.{
        .node = 1,
        .clock = &manual,
    }, last);

    const next = try second_run.next();
    try std.testing.expectEqual(.gt, next.order(last));
    try std.testing.expectEqual(2, next.sequence());
}

test "initAfter refuses to go below the last id when the clock is behind" {
    var manual = clock.ManualClock{ .value = 900 };
    const last = TestId.fromParts(.{ .timestamp = 1000, .node = 1, .sequence = 0 });

    var gen = try Generator(TestId, clock.ManualClock).initAfter(.{
        .node = 1,
        .clock = &manual,
    }, last);

    try std.testing.expectError(error.ClockMovedBackwards, gen.next());

    manual.set(1001);
    _ = try gen.next();
}

test "initAfter rejects an id from another node" {
    var manual = clock.ManualClock{};
    const last = TestId.fromParts(.{ .timestamp = 1000, .node = 2, .sequence = 0 });

    try std.testing.expectError(
        error.NodeMismatch,
        Generator(TestId, clock.ManualClock).initAfter(.{
            .node = 1,
            .clock = &manual,
        }, last),
    );
}
