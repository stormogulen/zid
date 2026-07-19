const std = @import("std");
const zid = @import("zid");

const DeterministicId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 2, // deliberately tiny: max_sequence == 3, easy to exhaust
    .tag = struct {},
});

pub fn main() !void {
    var clock = zid.ManualClock{ .value = 1_000 };

    var gen = try zid.Generator(DeterministicId, zid.ManualClock).init(.{
        .node = 1,
        .clock = &clock,
    });

    // Deterministic timestamp: with ManualClock, the id's timestamp is
    // exactly whatever the clock says — no waiting on real time, no
    // flakiness in CI.
    const first = try gen.next();
    std.debug.print("first:  {f}\n", .{first});
    std.debug.assert(first.timestamp() == 1_000);
    std.debug.assert(first.sequence() == 0);

    // Calling next() again without advancing the clock increments
    // sequence within the same millisecond.
    const second = try gen.next();
    std.debug.print("second: {f}\n", .{second});
    std.debug.assert(second.timestamp() == 1_000);
    std.debug.assert(second.sequence() == 1);

    // Exhaust the (deliberately tiny) sequence field: 2 bits means
    // max_sequence == 3, so two more calls use up what's left.
    _ = try gen.next(); // sequence 2
    _ = try gen.next(); // sequence 3, field now full

    if (gen.next()) |_| {
        unreachable; // sequence field is full; this must fail
    } else |err| {
        std.debug.print("exhausted: {}\n", .{err});
        std.debug.assert(err == error.SequenceExhausted);
    }

    // Advancing the clock resets sequence for the new millisecond —
    // the recovery a real caller would perform after seeing
    // SequenceExhausted.
    clock.advance(1);
    const after_tick = try gen.next();
    std.debug.print("after_tick: {f}\n", .{after_tick});
    std.debug.assert(after_tick.timestamp() == 1_001);
    std.debug.assert(after_tick.sequence() == 0);

    // A clock that moves backwards is rejected outright, rather than
    // silently producing an id that could collide with or precede
    // one already handed out.
    clock.set(500);
    if (gen.next()) |_| {
        unreachable; // clock went backwards; this must fail
    } else |err| {
        std.debug.print("backwards: {}\n", .{err});
        std.debug.assert(err == error.ClockMovedBackwards);
    }
}
