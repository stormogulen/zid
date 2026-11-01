//! Several threads making RandomOrderedIds, each with its own generator.
//!
//!     zig build run-random-threaded
//!
//! Compare examples/threaded: there every thread needs its own node id,
//! and getting that wrong means duplicates. Here there is nothing to hand
//! out. Each thread owns a generator, nothing is shared, and the threads
//! stay apart because their random bits differ.

const std = @import("std");
const zid = @import("zid");

const EventId = zid.RandomOrderedId(.{
    .timestamp_bits = 48,
    .random_bits = 80,
    .tag = struct {},
    .epoch = .fromUnixMillis(1_735_689_600_000), // 2025-01-01T00:00:00Z
});

const thread_count = 4;
const ids_per_thread = 20_000;

/// One thread's work. Nothing here is shared with another thread.
const Worker = struct {
    out: []EventId,
    /// Set if the worker stopped early; `out` is only fully written when null.
    err: ?zid.NextError = null,

    fn run(self: *Worker, io: std.Io) void {
        var clock = zid.MonotonicClock.init(io);
        var random = zid.IoRandom.init(io);
        var gen = zid.RandomGenerator(EventId, zid.MonotonicClock, zid.IoRandom).init(.{
            .clock = &clock,
            .random = &random,
        });

        for (self.out) |*slot| {
            slot.* = gen.nextRetrying(zid.SpinWait{}) catch |err| {
                self.err = err;
                return;
            };
        }
    }
};

/// Runs every worker on its own thread; no thread outlives this function.
fn runAll(io: std.Io, workers: *[thread_count]Worker) !void {
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |thread| thread.join();

    for (workers, 0..) |*worker, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ worker, io });
        spawned += 1;
    }
    for (threads) |thread| thread.join();
}

/// Checks a result in every build mode; see examples/testing.
fn check(ok: bool, comptime what: []const u8) !void {
    if (!ok) {
        std.debug.print("check failed: " ++ what ++ "\n", .{});
        return error.CheckFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const ids = try gpa.alloc(EventId, thread_count * ids_per_thread);
    defer gpa.free(ids);

    var workers: [thread_count]Worker = undefined;
    for (&workers, 0..) |*worker, i| {
        worker.* = .{ .out = ids[i * ids_per_thread .. (i + 1) * ids_per_thread] };
    }

    try runAll(init.io, &workers);

    for (workers) |worker| {
        if (worker.err) |err| return err;
        // Within a thread, ids strictly increase.
        for (worker.out[1..], worker.out[0 .. worker.out.len - 1]) |later, earlier| {
            try check(later.raw() > earlier.raw(), "a thread's ids increase");
        }
    }

    // Across threads, every id is unique, with no node ids involved.
    std.mem.sort(EventId, ids, {}, EventId.lessThan);
    for (ids[1..], ids[0 .. ids.len - 1]) |later, earlier| {
        try check(later.raw() > earlier.raw(), "no collisions across threads");
    }

    std.debug.print(
        "{d} threads x {d} ids = {d} total, all unique, no node ids assigned\n",
        .{ thread_count, ids_per_thread, ids.len },
    );
    std.debug.print("earliest: {f}\nlatest:   {f}\n", .{ ids[0].fmtString(), ids[ids.len - 1].fmtString() });
}
