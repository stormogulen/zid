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

fn worker(io: std.Io, node: u64, out: []WorkerId) !void {
    var clock = zid.SystemClock.init(io);

    var gen = try zid.Generator(WorkerId, zid.SystemClock).init(.{
        .node = node,
        .clock = &clock,
    });

    for (out) |*slot| {
        slot.* = try gen.next();
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // One buffer, sliced so each thread only ever writes into its own
    // region. That's what lets this stay lock-free: there is no
    // memory two threads ever touch at once.
    const ids = try gpa.alloc(WorkerId, thread_count * ids_per_thread);
    defer gpa.free(ids);

    var threads: [thread_count]std.Thread = undefined;

    for (0..thread_count) |i| {
        const node: u64 = i; // distinct node id per thread == the uniqueness guarantee
        const slice = ids[i * ids_per_thread .. (i + 1) * ids_per_thread];
        threads[i] = try std.Thread.spawn(.{}, worker, .{ init.io, node, slice });
    }

    for (threads) |t| t.join();

    // Verify what the design promises: every id is unique across all
    // threads, and every id's node field matches the thread that
    // produced it.
    var seen = std.AutoHashMap(u64, void).init(gpa);
    defer seen.deinit();
    try seen.ensureTotalCapacity(@intCast(ids.len));

    for (ids, 0..) |id, idx| {
        const owner_thread = idx / ids_per_thread;
        std.debug.assert(id.node() == owner_thread);

        const gop = try seen.getOrPut(id.raw());
        std.debug.assert(!gop.found_existing); // no collisions across threads
    }

    std.debug.print(
        "{d} threads x {d} ids = {d} total, all unique, all correctly node-tagged\n",
        .{ thread_count, ids_per_thread, ids.len },
    );
}
