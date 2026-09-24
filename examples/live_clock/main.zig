// Every other example either uses ManualClock (testing) or calls
// gen.next() a couple of times back-to-back (basic) -- both
// land in the same millisecond, so sequence never has to reset and
// the clock-advance branch in Generator.next() never actually runs.
//
// This one calls gen.next() in a loop with a real io.sleep() between
// calls, alternating a 0ms and a 3ms wait. That's just enough to force
// both code paths for real: some calls land in the same millisecond
// (sequence increments), others land after the clock moved on
// (sequence resets to 0) -- and we check both hold on every id we get
// back, rather than trusting it by construction.

const std = @import("std");
const zid = @import("zid");

const LiveId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
});

const iterations = 20;

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
    const io = init.io;
    var clock = zid.MonotonicClock.init(io);

    var gen = zid.Generator(LiveId, zid.MonotonicClock).init(.{
        .node = 1,
        .clock = &clock,
    });

    var previous: ?LiveId = null;

    for (0..iterations) |i| {
        const id = try gen.next();
        const parts = id.decode();

        std.debug.print(
            "id={d:>20}  ts={d:>13}  seq={d:>4}\n",
            .{ id.raw(), parts.timestamp, parts.sequence },
        );

        if (previous) |prev| {
            const prev_parts = prev.decode();

            // Raw value must be strictly increasing regardless of
            // which branch produced it.
            try check(id.raw() > prev.raw(), "ids strictly increase");

            if (parts.timestamp == prev_parts.timestamp) {
                // Same millisecond: sequence must have incremented by
                // exactly one, not reset or jumped.
                try check(parts.sequence == prev_parts.sequence + 1, "sequence increments by exactly one");
            } else {
                // Clock moved forward: sequence must have reset, and
                // time must never run backwards.
                try check(parts.timestamp > prev_parts.timestamp, "time never runs backwards");
                try check(parts.sequence == 0, "sequence resets in a new millisecond");
            }
        }

        previous = id;

        // Alternate 0ms/3ms so roughly half the calls land in the same
        // millisecond as the previous one and half don't.
        const sleep_ms: i64 = if (i % 2 == 0) 0 else 3;
        try io.sleep(.fromMilliseconds(sleep_ms), .awake);
    }

    std.debug.print("\n{d} ids generated under a real MonotonicClock, all monotonic.\n", .{iterations});
}
