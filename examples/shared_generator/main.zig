const std = @import("std");
const zid = @import("zid");

// One AtomicGenerator shared by several threads: a single node id, no
// lock. Compare examples/threaded, where every thread owns a Generator
// and a node id. Prefer that when you have node ids to spare; use this
// when the threads must share one node.

const SharedId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
    .epoch = .fromUnixMillis(1_735_689_600_000), // 2025-01-01T00:00:00Z
});

const Gen = zid.AtomicGenerator(SharedId, zid.MonotonicClock);

const thread_count = 4;
const ids_per_thread = 2_000;

const Worker = struct {
    gen: *Gen,
    out: []SharedId,
    err: ?zid.NextError = null,

    fn run(self: *Worker) void {
        const waiter: zid.SpinWait = .{};
        for (self.out) |*slot| {
            // Waits for the next millisecond if this one is full.
            slot.* = self.gen.nextRetrying(waiter) catch |err| {
                self.err = err;
                return;
            };
        }
    }
};

fn check(ok: bool, comptime what: []const u8) !void {
    if (!ok) {
        std.debug.print("check failed: " ++ what ++ "\n", .{});
        return error.CheckFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var clock = zid.MonotonicClock.init(init.io);
    var gen = Gen.init(.{ .node = 1, .clock = &clock });

    const ids = try gpa.alloc(SharedId, thread_count * ids_per_thread);
    defer gpa.free(ids);

    var workers: [thread_count]Worker = undefined;
    var threads: [thread_count]std.Thread = undefined;

    for (&workers, 0..) |*worker, i| {
        worker.* = .{
            .gen = &gen,
            .out = ids[i * ids_per_thread .. (i + 1) * ids_per_thread],
        };
    }

    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |thread| thread.join();
    for (&workers, 0..) |*worker, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{worker});
        spawned += 1;
    }
    for (threads) |thread| thread.join();

    for (workers) |worker| {
        if (worker.err) |err| return err;
    }

    // Every id is unique even though all threads used the same node.
    std.mem.sort(SharedId, ids, {}, SharedId.lessThan);
    for (ids[1..], ids[0 .. ids.len - 1]) |b, a| {
        try check(b.raw() > a.raw(), "no collisions across threads");
    }

    std.debug.print(
        "{d} threads x {d} ids = {d} total from one shared node, all unique\n",
        .{ thread_count, ids_per_thread, ids.len },
    );
}
