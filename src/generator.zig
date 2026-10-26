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
    comptime checkTypes("Generator", IdType, ClockType);

    return struct {
        const Self = @This();

        pub const Id = IdType;
        pub const Node = IdType.Node;
        pub const Timestamp = IdType.Timestamp;
        pub const NextError = errors.NextError;

        /// Where the generator is. Before the first id only the node is
        /// known; after it, the last id carries the node along with the
        /// timestamp and sequence. Keeping the node in one place means
        /// the node and the last id can't disagree.
        pub const State = union(enum) {
            /// Nothing issued yet; ids will be for this node.
            fresh: Node,
            /// The most recently issued id (or the one to resume after).
            after: IdType,
        };

        // Internal state. Zig has no private fields, so these are
        // visible, but they are not part of the API: construct with
        // init/initAfter and never write them afterwards. Changing
        // `state` directly can break the monotonicity and uniqueness
        // guarantees.

        clock: *ClockType,
        /// How far behind the last id the clock may read before `next()`
        /// gives up. See `Options.clock_skew_tolerance_ms`.
        skew_tolerance_ms: u64,
        state: State,

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
            /// How many milliseconds the clock may read behind the last
            /// id before `next()` returns `error.ClockMovedBackwards`.
            /// Within the tolerance the generator keeps issuing ids at
            /// the last id's timestamp (so they run slightly ahead of
            /// the wall clock, and may exhaust the sequence sooner)
            /// instead of failing. Ids still strictly increase. If the
            /// sequence runs out while the clock is still behind,
            /// `next()` returns `error.SequenceExhausted` until the
            /// clock passes the last id's timestamp. That can take up
            /// to the tolerance, not the usual sub-millisecond, so
            /// `nextRetrying` can wait that long. The default, 0,
            /// reports any backwards step.
            clock_skew_tolerance_ms: u64 = 0,
        };

        pub fn init(options: Options) Self {
            return .{
                .clock = options.clock,
                .skew_tolerance_ms = options.clock_skew_tolerance_ms,
                .state = .{ .fresh = options.node },
            };
        }

        /// Like init, but continues after `last`, an id this node issued
        /// earlier (`lastIssued()` of the previous run): every id from the
        /// new generator is greater than it. A plain `init` after a
        /// restart makes no such promise, because a fresh clock can start
        /// behind the ids the previous run already issued.
        /// If the clock is behind `last` (for example after a restart
        /// with a clock that was set back), next() reports
        /// `error.ClockMovedBackwards` instead of issuing duplicates.
        pub fn initAfter(options: Options, last: IdType) errors.ResumeError!Self {
            if (last.node() != options.node) {
                return error.NodeMismatch;
            }

            var self = init(options);
            self.state = .{ .after = last };
            return self;
        }

        /// Like initAfter, but continues after a whole millisecond:
        /// every id from the new generator has a timestamp later than
        /// `reserved`. For the reserve-ahead pattern: persist a timestamp a
        /// little in the future *before* handing out ids up to it, and
        /// resume after it on restart. A crash then can't repeat an id,
        /// even one issued after the last save. Can't fail: no id from
        /// another node is involved. Until the clock passes `reserved`,
        /// next() reports `error.ClockMovedBackwards` (clock behind it) or
        /// `error.SequenceExhausted` (clock at it). `nextRetrying` only
        /// waits out the second, so wait for the clock to pass `reserved`
        /// before the first id (the README shows a bounded wait).
        pub fn initAfterTimestamp(options: Options, reserved: Timestamp) Self {
            var self = init(options);
            self.state = .{ .after = lastIdAt(IdType, reserved, options.node) };
            return self;
        }

        /// The most recently issued id, or null before the first one. Store
        /// it (for example with `toString()`) so that a restarted process
        /// can resume with `initAfter` instead of risking repeats.
        pub fn lastIssued(self: *const Self) ?IdType {
            return switch (self.state) {
                .fresh => null,
                .after => |last| last,
            };
        }

        pub fn next(self: *Self) NextError!IdType {
            const timestamp = try IdType.timestampFromUnixMillis(self.clock.now().millis);
            const last: ?IdType, const node: Node = switch (self.state) {
                .fresh => |fresh_node| .{ null, fresh_node },
                .after => |previous| .{ previous, previous.node() },
            };
            const id = try successor(IdType, last, timestamp, node, self.skew_tolerance_ms);
            self.state = .{ .after = id };
            return id;
        }

        /// Like `next`, but when the millisecond's sequence is used up it
        /// calls `waiter.wait()` and tries again, until the clock moves
        /// on. Every other error is returned as is. `waiter` is any value
        /// with a `wait(self)` method: `zid.SpinWait{}` busy-waits, and a
        /// program with an event loop can sleep instead. If the clock never
        /// advances, this never returns, so don't pair it with a
        /// `ManualClock` that the waiter doesn't move. With a nonzero
        /// `clock_skew_tolerance_ms` the wait can last as long as the
        /// tolerance (see `Options.clock_skew_tolerance_ms`); use a
        /// sleeping waiter rather than `zid.SpinWait` if that matters.
        pub fn nextRetrying(self: *Self, waiter: anytype) NextError!IdType {
            return retryingNext(Self, self, waiter);
        }
    };
}

/// The id that follows `last` when the clock reads `timestamp`. Pure: it
/// reads no clock and keeps no state, so `Generator` and
/// `AtomicGenerator` share one definition of the sequencing rules.
/// Guarantees that the returned id is greater than `last`.
pub fn successor(
    comptime IdType: type,
    last: ?IdType,
    timestamp_now: IdType.Timestamp,
    node: IdType.Node,
    skew_tolerance_ms: u64,
) errors.NextError!IdType {
    var timestamp = timestamp_now;

    const sequence: IdType.Sequence = if (last) |l| sequence: {
        const last_timestamp = l.timestamp();

        if (timestamp < last_timestamp) {
            if (last_timestamp - timestamp > skew_tolerance_ms) {
                return error.ClockMovedBackwards;
            }
            // Small step back: keep issuing at the last timestamp.
            timestamp = last_timestamp;
        }
        if (timestamp > last_timestamp) {
            break :sequence 0;
        }
        if (l.sequence() == std.math.maxInt(IdType.Sequence)) {
            return error.SequenceExhausted;
        }
        break :sequence l.sequence() + 1;
    } else 0;

    const id = IdType.fromParts(.{
        .timestamp = timestamp,
        .node = node,
        .sequence = sequence,
    });

    // The generators' core promise: for a fixed node, ids strictly
    // increase. Checked here, where it is made, so both generators get
    // it.
    //
    // zid's rule for checks: an invariant whose failure would hand the
    // caller a wrong id gets a real check (`@panic`), kept in every build
    // mode, because a library doesn't choose the caller's build mode and a
    // failed `std.debug.assert` is undefined behaviour in ReleaseFast. This
    // is the only one: it costs one branch per id. Everything else (the
    // bit packing in Layout, fromParts's round trip) is guaranteed by the
    // field types and checked with `std.debug.assert`, which costs nothing
    // in ReleaseFast. See "Design Constraints" in the README.
    if (last) |l| {
        if (id.raw() <= l.raw()) {
            @panic("zid: successor produced an id that is not greater than the last");
        }
    }
    return id;
}

/// `nextRetrying` for both generators: `next()` until it reports anything
/// but `SequenceExhausted`, calling `waiter.wait()` in between.
pub fn retryingNext(comptime Gen: type, gen: *Gen, waiter: anytype) errors.NextError!Gen.Id {
    comptime checkWaiter(@TypeOf(waiter));

    while (true) {
        return gen.next() catch |err| switch (err) {
            error.SequenceExhausted => {
                waiter.wait();
                continue;
            },
            else => |e| return e,
        };
    }
}

/// A waiter is any value, or pointer to one, with a `wait()` method.
/// Checked up front so a wrong one fails at the call site with one message.
fn checkWaiter(comptime Waiter: type) void {
    const Target = switch (@typeInfo(Waiter)) {
        .pointer => |pointer| pointer.child,
        else => Waiter,
    };
    if (!isContainer(Target) or !@hasDecl(Target, "wait")) {
        @compileError("nextRetrying's waiter must have a `wait()` method (like zid.SpinWait), found " ++
            @typeName(Waiter));
    }
}

/// The largest id `node` can issue at `timestamp`: resuming after it skips
/// the rest of that millisecond. Shared by both generators'
/// `initAfterTimestamp`.
pub fn lastIdAt(comptime IdType: type, timestamp: IdType.Timestamp, node: IdType.Node) IdType {
    return IdType.fromParts(.{
        .timestamp = timestamp,
        .node = node,
        .sequence = std.math.maxInt(IdType.Sequence),
    });
}

/// The compile-time contract both generators place on their type
/// parameters. Called at the top of `Generator` and `AtomicGenerator`, so
/// a wrong type fails there with one message naming what's missing.
pub fn checkTypes(
    comptime generator_name: []const u8,
    comptime IdType: type,
    comptime ClockType: type,
) void {
    if (!isContainer(IdType) or !@hasDecl(IdType, "Layout") or !@hasDecl(IdType, "fromParts") or !@hasDecl(IdType, "timestampFromUnixMillis")) {
        @compileError(generator_name ++ "'s IdType must be a zid.OrderedId type, found " ++ @typeName(IdType));
    }

    const now_signature = "`pub fn now(self: *" ++ @typeName(ClockType) ++ ") zid.UnixMillis`";
    if (!isContainer(ClockType) or !@hasDecl(ClockType, "now")) {
        @compileError(generator_name ++ "'s ClockType must provide " ++ now_signature);
    }

    const now_info = @typeInfo(@TypeOf(ClockType.now));
    if (now_info != .@"fn") {
        @compileError(@typeName(ClockType) ++ ".now must be a function: " ++ now_signature);
    }

    const now_fn = now_info.@"fn";
    if (now_fn.params.len != 1 or now_fn.params[0].type != *ClockType) {
        @compileError(@typeName(ClockType) ++ ".now must take exactly `self: *" ++
            @typeName(ClockType) ++ "`: " ++ now_signature);
    }
    if (now_fn.return_type != clock.UnixMillis) {
        @compileError(@typeName(ClockType) ++ ".now must return zid.UnixMillis, which names its unit: " ++ now_signature);
    }
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
    .epoch = .unix,
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
        .epoch = .unix,
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

test "a clock clamped to zero: fine when fresh, ClockMovedBackwards after ids" {
    // A wall clock before 1970 is clamped to 0 by the system clocks.
    // With the default Unix epoch that is timestamp 0, not an error...
    var manual = clock.ManualClock{ .value = 0 };
    var gen = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });
    try std.testing.expectEqual(0, (try gen.next()).timestamp());

    // ...but once ids exist at a later time, it is a backwards step.
    manual.set(5_000);
    _ = try gen.next();
    manual.set(0);
    try std.testing.expectError(error.ClockMovedBackwards, gen.next());
}

test "inside the skew tolerance the sequence can run out while the clock is behind" {
    var manual = clock.ManualClock{ .value = 1_000 };
    var gen = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
        .clock_skew_tolerance_ms = 5,
    });
    _ = try gen.next(); // last timestamp is now 1000, sequence 0
    manual.set(998); // behind, but within the tolerance

    // Ids keep coming at timestamp 1000 until its sequence is used up...
    for (0..std.math.maxInt(TestId.Sequence)) |_| {
        try std.testing.expectEqual(1_000, (try gen.next()).timestamp());
    }
    try std.testing.expectError(error.SequenceExhausted, gen.next());

    // ...and stay exhausted until the clock passes 1000. A retry loop
    // would wait that long (up to the tolerance), not under a millisecond.
    try std.testing.expectError(error.SequenceExhausted, gen.next());
    manual.set(1_001);
    try std.testing.expectEqual(1_001, (try gen.next()).timestamp());
}

test "timestamp overflow is rejected" {

    // timestamp_bits = 2 means max_timestamp == 3.
    const TinyTimestampId = OrderedId(.{
        .timestamp_bits = 2,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
        .epoch = .unix,
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
        .epoch = .unix,
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

test "initAfterTimestamp issues nothing until the clock passes the reserved millisecond" {
    var manual = clock.ManualClock{ .value = 999 };
    var gen = Generator(TestId, clock.ManualClock).initAfterTimestamp(.{
        .node = 3,
        .clock = &manual,
    }, 1000);

    try std.testing.expectError(error.ClockMovedBackwards, gen.next());

    manual.set(1000); // At the reserved millisecond: all of it is used up.
    try std.testing.expectError(error.SequenceExhausted, gen.next());

    manual.set(1001);
    const id = try gen.next();
    try std.testing.expectEqual(1001, id.timestamp());
    try std.testing.expectEqual(0, id.sequence());
    try std.testing.expectEqual(3, id.node());
}

test "initAfterTimestamp works with a layout without sequence bits" {
    const NoSequenceId = OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 0,
        .tag = struct {},
        .epoch = .unix,
    });

    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(NoSequenceId, clock.ManualClock).initAfterTimestamp(.{ .node = 1, .clock = &manual }, 1000);
    try std.testing.expectError(error.SequenceExhausted, gen.next());

    manual.advance(1);
    try std.testing.expectEqual(1001, (try gen.next()).timestamp());
}

test "small clock steps back are absorbed within the tolerance" {
    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
        .clock_skew_tolerance_ms = 5,
    });

    const first = try gen.next();
    manual.set(997); // 3 ms back: inside the tolerance.
    const second = try gen.next();

    try std.testing.expectEqual(first.timestamp(), second.timestamp());
    try std.testing.expect(second.raw() > first.raw());

    manual.set(990); // 10 ms behind the last id: outside it.
    try std.testing.expectError(error.ClockMovedBackwards, gen.next());

    manual.set(1001); // The clock has caught up.
    const third = try gen.next();
    try std.testing.expectEqual(1001, third.timestamp());
    try std.testing.expectEqual(0, third.sequence());
}

test "a zero tolerance reports every step back" {
    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(TestId, clock.ManualClock).init(.{ .node = 1, .clock = &manual });

    _ = try gen.next();
    manual.set(999);
    try std.testing.expectError(error.ClockMovedBackwards, gen.next());
}

const AdvancingWaiter = struct {
    clock: *clock.ManualClock,
    waits: usize = 0,

    pub fn wait(self: *AdvancingWaiter) void {
        self.waits += 1;
        self.clock.advance(1);
    }
};

test "nextRetrying waits out sequence exhaustion" {
    const TinyId = OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 1,
        .tag = struct {},
        .epoch = .unix,
    });

    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(TinyId, clock.ManualClock).init(.{ .node = 1, .clock = &manual });
    var waiter = AdvancingWaiter{ .clock = &manual };

    var previous = try gen.nextRetrying(&waiter);
    for (0..10) |_| {
        const id = try gen.nextRetrying(&waiter);
        try std.testing.expect(id.raw() > previous.raw());
        previous = id;
    }
    // Two ids fit in a millisecond, so 11 ids need 5 waits.
    try std.testing.expectEqual(5, waiter.waits);
}

test "nextRetrying passes other errors through" {
    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(TestId, clock.ManualClock).init(.{ .node = 1, .clock = &manual });
    var waiter = AdvancingWaiter{ .clock = &manual };

    _ = try gen.nextRetrying(&waiter);
    manual.set(1);
    try std.testing.expectError(error.ClockMovedBackwards, gen.nextRetrying(&waiter));
    try std.testing.expectEqual(0, waiter.waits);
}

test "lastIssued is null at first, then the id next() just returned" {
    var manual = clock.ManualClock{ .value = 1000 };
    var gen = Generator(TestId, clock.ManualClock).init(.{ .node = 1, .clock = &manual });

    try std.testing.expectEqual(null, gen.lastIssued());

    const first = try gen.next();
    try std.testing.expectEqual(first, gen.lastIssued().?);

    const second = try gen.next();
    try std.testing.expectEqual(second, gen.lastIssued().?);

    // A failed next() doesn't change it.
    manual.set(1);
    try std.testing.expectError(error.ClockMovedBackwards, gen.next());
    try std.testing.expectEqual(second, gen.lastIssued().?);
}

test "persisting lastIssued as a string and resuming never repeats an id" {
    var manual = clock.ManualClock{ .value = 1000 };
    var before = Generator(TestId, clock.ManualClock).init(.{ .node = 1, .clock = &manual });

    _ = try before.next();
    _ = try before.next();
    const stored = before.lastIssued().?.toString();

    // "Restart": the new process's clock starts at the same millisecond.
    // A plain init would repeat the first id; initAfter does not.
    var fresh = Generator(TestId, clock.ManualClock).init(.{ .node = 1, .clock = &manual });
    try std.testing.expectEqual(0, (try fresh.next()).sequence());

    const last = try TestId.parse(&stored);
    var resumed = try Generator(TestId, clock.ManualClock).initAfter(.{ .node = 1, .clock = &manual }, last);
    try std.testing.expectEqual(2, (try resumed.next()).sequence());
}
