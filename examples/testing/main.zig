const std = @import("std");
const zid = @import("zid");

const DeterministicId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 2, // deliberately tiny: max_sequence == 3, easy to exhaust
    .tag = struct {},
});

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

pub fn main() !void {
    var clock = zid.ManualClock{ .value = 1_000 };

    var gen = zid.Generator(DeterministicId, zid.ManualClock).init(.{
        .node = 1,
        .clock = &clock,
    });

    // Deterministic timestamp: with ManualClock, the id's timestamp is
    // exactly whatever the clock says — no waiting on real time, no
    // flakiness in CI.
    const first = try gen.next();
    std.debug.print("first:  {f}\n", .{first});
    try check(first.timestamp() == 1_000, "timestamp is exactly the clock value");
    try check(first.sequence() == 0, "first id starts at sequence 0");

    // Calling next() again without advancing the clock increments
    // sequence within the same millisecond.
    const second = try gen.next();
    std.debug.print("second: {f}\n", .{second});
    try check(second.timestamp() == 1_000, "same millisecond");
    try check(second.sequence() == 1, "sequence increments within a millisecond");

    // Exhaust the (deliberately tiny) sequence field: 2 bits means
    // max_sequence == 3, so two more calls use up what's left.
    _ = try gen.next(); // sequence 2
    _ = try gen.next(); // sequence 3, field now full

    if (gen.next()) |_| {
        return error.CheckFailed; // sequence field is full; this must fail
    } else |err| {
        std.debug.print("exhausted: {}\n", .{err});
        try check(err == error.SequenceExhausted, "a full sequence field is reported");
    }

    // Advancing the clock resets sequence for the new millisecond —
    // the recovery a real caller would perform after seeing
    // SequenceExhausted.
    clock.advance(1);
    const after_tick = try gen.next();
    std.debug.print("after_tick: {f}\n", .{after_tick});
    try check(after_tick.timestamp() == 1_001, "timestamp follows the clock");
    try check(after_tick.sequence() == 0, "sequence resets in a new millisecond");

    // A clock that moves backwards is rejected outright, rather than
    // silently producing an id that could collide with or precede
    // one already handed out.
    clock.set(500);
    if (gen.next()) |_| {
        return error.CheckFailed; // clock went backwards; this must fail
    } else |err| {
        std.debug.print("backwards: {}\n", .{err});
        try check(err == error.ClockMovedBackwards, "a backwards clock is rejected");
    }
}
