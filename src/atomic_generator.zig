//! Id generator that several threads can share without a lock.
//!
//! Lock-free on targets with native 64-bit compare-and-swap, provided
//! the clock's `now` is non-blocking too.
//!
//! Not available on 32-bit targets: with Zig 0.16.0 it fails to compile
//! for `x86-linux` (baseline, `pentium`, `i686`, `pentium4`) and
//! `arm-linux-gnueabihf` (baseline, `cortex_a7`), because Zig rejects
//! 64-bit atomics there whatever the CPU model. Use `Generator` on such
//! targets. CI compiles the tests for `aarch64-linux` and
//! `riscv64-linux` (`zig build check -Dtarget=...`) but does not run
//! them.
//!
//! Responsibilities:
//!
//! - Do what `Generator` does, from any number of threads at once, for a
//!   single node id.
//! - Keep ids unique and strictly increasing across all threads, with
//!   no lock: the whole state is the last id, one u64, advanced with a
//!   compare-and-swap.
//!
//! Does NOT:
//!
//! - Coordinate node ids across processes (same as `Generator`).
//! - Retry on exhaustion (callers decide; see `Generator.nextRetrying`
//!   for the single-threaded version of the same idea).
//! - Cost nothing. A contended compare-and-swap is slower than
//!   `Generator`. If each thread can have its own node id, giving each
//!   its own `Generator` stays faster (see examples/threaded).
//! - Support layouts that use all 64 bits: one value of the u64 marks
//!   "nothing issued yet", so it can never be a real id.

const std = @import("std");
const errors = @import("errors.zig");
const generator = @import("generator.zig");
const clock = @import("clock.zig");
const OrderedId = @import("ordered/id.zig").OrderedId;

pub fn AtomicGenerator(
    comptime IdType: type,
    comptime ClockType: type,
) type {
    comptime {
        generator.checkTypes("AtomicGenerator", IdType, ClockType);
        if (IdType.Layout.total_bits == 64) {
            @compileError("AtomicGenerator needs a layout with at least one unused bit; use Generator for a 64-bit layout");
        }
    }

    // Bit 63 is never set in a real id (the layout is under 64 bits),
    // so an all-ones value can't be one.
    const none: u64 = std.math.maxInt(u64);

    return struct {
        const Self = @This();

        pub const Id = IdType;
        pub const Node = IdType.Node;
        pub const NextError = errors.NextError;

        // Internal state; construct with init/initAfter.
        clock: *ClockType,
        node: Node,
        skew_tolerance_ms: u64,
        /// Raw value of the most recently issued id, or `none`.
        state: std.atomic.Value(u64),

        pub const Options = struct {
            node: Node,
            /// Borrowed, not copied. `ClockType.now` is called from
            /// several threads at once, so it must be safe to do that:
            /// `MonotonicClock` and `SystemClock` are, `ManualClock`
            /// (a plain field) is not.
            clock: *ClockType,
            /// Same meaning as `Generator.Options.clock_skew_tolerance_ms`.
            clock_skew_tolerance_ms: u64 = 0,
        };

        pub fn init(options: Options) Self {
            return .{
                .clock = options.clock,
                .node = options.node,
                .skew_tolerance_ms = options.clock_skew_tolerance_ms,
                .state = .init(none),
            };
        }

        /// Continues after `last`, an id this node issued earlier.
        /// Same contract as `Generator.initAfter`.
        pub fn initAfter(options: Options, last: IdType) errors.ResumeError!Self {
            if (last.node() != options.node) {
                return error.NodeMismatch;
            }

            var self = init(options);
            self.state = .init(last.raw());
            return self;
        }

        /// Continues after a whole millisecond. Same contract as
        /// `Generator.initAfterTimestamp`.
        pub fn initAfterTimestamp(options: Options, reserved: IdType.Timestamp) Self {
            var self = init(options);
            self.state = .init(generator.lastIdAt(IdType, reserved, options.node).raw());
            return self;
        }

        /// The most recently issued id, or null before the first one. Under
        /// concurrent `next()` calls it is a snapshot: another thread may
        /// have issued a later id by the time you use the result.
        pub fn lastIssued(self: *const Self) ?IdType {
            const observed = self.state.load(.acquire);
            return if (observed == none) null else @enumFromInt(observed);
        }

        /// Safe to call from any thread. Each id returned is unique, and
        /// ids are ordered by when their compare-and-swap succeeded (the
        /// order they were allocated in). That is not necessarily the
        /// order in which calls return or in which callers observe the
        /// ids: a thread can win the swap, be descheduled, and return
        /// after another thread has already returned a later id. Where
        /// the order of observation matters, synchronize on it yourself.
        pub fn next(self: *Self) NextError!IdType {
            var observed = self.state.load(.acquire);

            while (true) {
                // Read the clock after loading the state. The acquire
                // load pairs with the release half of the compare-and-
                // swap that stored `observed`, which that thread did
                // after its own clock reading. So this reading is no
                // earlier than that one, provided the clock is monotonic
                // across threads (`MonotonicClock` is; `SystemClock` is
                // not, and can still report a real step back). That is
                // what stops a thread that was descheduled from
                // reporting a step back that never happened, and it is
                // why the orderings here are not `.monotonic`.
                const timestamp = try IdType.timestampFromUnixMillis(self.clock.now());

                const last: ?IdType = if (observed == none) null else @enumFromInt(observed);
                // `successor` panics rather than return an id at or below
                // `last`, so the compare-and-swap only ever moves forward.
                const id = try generator.successor(IdType, last, timestamp, self.node, self.skew_tolerance_ms);

                // On failure another thread issued an id first; the
                // value it left is the new `observed`.
                observed = self.state.cmpxchgWeak(observed, id.raw(), .acq_rel, .acquire) orelse return id;
            }
        }

        /// Like `next`, but waits out sequence exhaustion. See
        /// `Generator.nextRetrying`.
        pub fn nextRetrying(self: *Self, waiter: anytype) NextError!IdType {
            return generator.retryingNext(Self, self, waiter);
        }
    };
}

const TestId = OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
});

test "matches Generator on a single thread" {
    var manual_a = clock.ManualClock{ .value = 1000 };
    var manual_b = clock.ManualClock{ .value = 1000 };
    var plain = generator.Generator(TestId, clock.ManualClock).init(.{ .node = 3, .clock = &manual_a });
    var atomic = AtomicGenerator(TestId, clock.ManualClock).init(.{ .node = 3, .clock = &manual_b });

    for (0..5000) |i| {
        if (i % 700 == 0) {
            manual_a.advance(1);
            manual_b.advance(1);
        }
        const expected = plain.next();
        if (expected) |id| {
            try std.testing.expectEqual(id, try atomic.next());
        } else |err| {
            try std.testing.expectError(err, atomic.next());
        }
    }
}

test "lastIssued follows next() and survives a resume" {
    var manual = clock.ManualClock{ .value = 1000 };
    var gen = AtomicGenerator(TestId, clock.ManualClock).init(.{ .node = 2, .clock = &manual });

    try std.testing.expectEqual(null, gen.lastIssued());
    const id = try gen.next();
    try std.testing.expectEqual(id, gen.lastIssued().?);

    var resumed = try AtomicGenerator(TestId, clock.ManualClock).initAfter(
        .{ .node = 2, .clock = &manual },
        gen.lastIssued().?,
    );
    try std.testing.expect((try resumed.next()).raw() > id.raw());
}

test "reports exhaustion and clock regression" {
    const TinyId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 1, .tag = struct {} });
    var manual = clock.ManualClock{ .value = 1000 };
    var gen = AtomicGenerator(TinyId, clock.ManualClock).init(.{ .node = 1, .clock = &manual });

    _ = try gen.next();
    _ = try gen.next();
    try std.testing.expectError(error.SequenceExhausted, gen.next());

    manual.set(999);
    try std.testing.expectError(error.ClockMovedBackwards, gen.next());

    manual.set(1001);
    try std.testing.expectEqual(0, (try gen.next()).sequence());
}

test "initAfter resumes and rejects another node" {
    var manual = clock.ManualClock{ .value = 1000 };
    const last = TestId.fromParts(.{ .timestamp = 1000, .node = 4, .sequence = 7 });

    var gen = try AtomicGenerator(TestId, clock.ManualClock).initAfter(.{ .node = 4, .clock = &manual }, last);
    try std.testing.expectEqual(8, (try gen.next()).sequence());

    try std.testing.expectError(
        error.NodeMismatch,
        AtomicGenerator(TestId, clock.ManualClock).initAfter(.{ .node = 5, .clock = &manual }, last),
    );
}

test "initAfterTimestamp matches Generator.initAfterTimestamp" {
    var manual_a = clock.ManualClock{ .value = 999 };
    var manual_b = clock.ManualClock{ .value = 999 };
    var plain = generator.Generator(TestId, clock.ManualClock).initAfterTimestamp(.{ .node = 6, .clock = &manual_a }, 1000);
    var atomic = AtomicGenerator(TestId, clock.ManualClock).initAfterTimestamp(.{ .node = 6, .clock = &manual_b }, 1000);

    try std.testing.expectEqual(plain.lastIssued(), atomic.lastIssued());
    for ([_]u64{ 999, 1000, 1001, 1001 }) |now| {
        manual_a.set(now);
        manual_b.set(now);
        const expected = plain.next();
        if (expected) |id| {
            try std.testing.expectEqual(id, try atomic.next());
        } else |err| {
            try std.testing.expectError(err, atomic.next());
        }
    }
    try std.testing.expectEqual(1, atomic.lastIssued().?.sequence());
}

test "threads sharing one generator never collide" {
    const thread_count = 4;
    const ids_per_thread = 5_000;

    const Gen = AtomicGenerator(TestId, clock.MonotonicClock);
    var mono = clock.MonotonicClock.init(std.testing.io);
    var gen = Gen.init(.{ .node = 1, .clock = &mono });

    const Worker = struct {
        gen: *Gen,
        out: []TestId,
        failed: bool = false,

        fn run(self: *@This()) void {
            const waiter: @import("wait.zig").SpinWait = .{};
            for (self.out) |*slot| {
                slot.* = self.gen.nextRetrying(waiter) catch {
                    self.failed = true;
                    return;
                };
            }
        }
    };

    var storage: [thread_count * ids_per_thread]TestId = undefined;
    var workers: [thread_count]Worker = undefined;
    var threads: [thread_count]std.Thread = undefined;

    for (&workers, 0..) |*worker, i| {
        worker.* = .{ .gen = &gen, .out = storage[i * ids_per_thread ..][0..ids_per_thread] };
    }
    for (&threads, &workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    for (threads) |thread| thread.join();

    for (workers) |worker| {
        try std.testing.expect(!worker.failed);
        // Within a thread, ids strictly increase.
        for (worker.out[1..], worker.out[0 .. worker.out.len - 1]) |b, a| {
            try std.testing.expect(b.raw() > a.raw());
        }
    }

    // Across threads, all ids are unique.
    std.mem.sort(TestId, &storage, {}, TestId.lessThan);
    for (storage[1..], storage[0 .. storage.len - 1]) |b, a| {
        try std.testing.expect(b.raw() > a.raw());
    }
}
