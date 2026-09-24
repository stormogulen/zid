const std = @import("std");
const zid = @import("zid");

// Generator is deliberately not thread-safe (see the README's "Design
// Constraints" section): no locking is used internally, which is part
// of how it stays zero-cost. The supported way to use it from more
// than one thread is the same contract the library already documents
// for node ids in general -- "assigning unique ids across a fleet is
// left to the caller" -- just applied to threads within one process
// instead of machines across a fleet: give each thread its own
// Generator, with its own node id. No shared mutable state, so no
// lock is needed anywhere, and ids from different threads can never
// collide because each one carries a distinct node id.

const WorkerId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
});

const thread_count = 4;
const ids_per_thread = 2_000;

// Each thread gets its own node id, so there must be enough of them.
comptime {
    std.debug.assert(thread_count <= std.math.maxInt(WorkerId.Node) + 1);
}

/// One thread's work: its own node id, its own region of the output
/// buffer, and a place to report failure. Nothing here is shared with
/// another thread.
const Worker = struct {
    node: WorkerId.Node,
    out: []WorkerId,
    /// Set if the worker stopped early. `out` is only fully written
    /// when this is null.
    err: ?zid.NextError = null,

    fn run(self: *Worker, io: std.Io) void {
        var clock = zid.MonotonicClock.init(io);
        var gen = zid.Generator(WorkerId, zid.MonotonicClock).init(.{
            .node = self.node,
            .clock = &clock,
        });

        var written: usize = 0;
        while (written < self.out.len) {
            self.out[written] = gen.next() catch |err| switch (err) {
                // The millisecond is full: retry until the clock moves on.
                error.SequenceExhausted => continue,
                error.BeforeEpoch,
                error.TimestampOverflow,
                error.ClockMovedBackwards,
                => {
                    self.err = err;
                    return;
                },
            };
            written += 1;
        }
    }
};

/// Runs every worker on its own thread and returns once all of them
/// have finished. The workers write into memory the caller owns, so no
/// thread may outlive this function, including when a spawn fails
/// part-way.
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

/// Checks a result in every build mode. `std.debug.assert` is for
/// programmer assumptions and is undefined behaviour when it fails in
/// ReleaseFast; an example verifying what the library produced needs a
/// check that always fails loudly.
fn check(ok: bool, comptime what: []const u8) !void {
    if (!ok) {
        std.debug.print("check failed: " ++ what ++ "\n", .{});
        return error.CheckFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // One buffer, sliced so each thread only ever writes into its own
    // region. That's what lets this stay lock-free: there is no
    // memory two threads ever touch at once.
    const ids = try gpa.alloc(WorkerId, thread_count * ids_per_thread);
    defer gpa.free(ids);

    var workers: [thread_count]Worker = undefined;
    for (&workers, 0..) |*worker, i| {
        worker.* = .{
            // Distinct node id per thread == the uniqueness guarantee.
            // The cast can't fail: thread_count is checked against Node
            // above.
            .node = @intCast(i),
            .out = ids[i * ids_per_thread .. (i + 1) * ids_per_thread],
        };
    }

    try runAll(init.io, &workers);

    for (workers) |worker| {
        if (worker.err) |err| {
            std.debug.print("worker for node {d} failed: {t}\n", .{ worker.node, err });
            return err;
        }
    }

    // Verify what the design promises: every id is unique across all
    // threads, and every id's node field matches the thread that
    // produced it.
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    try seen.ensureTotalCapacity(gpa, @intCast(ids.len));

    for (ids, 0..) |id, idx| {
        const owner_thread = idx / ids_per_thread;
        try check(id.node() == owner_thread, "every id carries its thread's node");

        const gop = seen.getOrPutAssumeCapacity(id.raw());
        try check(!gop.found_existing, "no collisions across threads");
    }

    std.debug.print(
        "{d} threads x {d} ids = {d} total, all unique, all correctly node-tagged\n",
        .{ thread_count, ids_per_thread, ids.len },
    );
}
