// Every other example either uses ManualClock (testing) or calls
// SystemClock.next() a couple of times back-to-back (basic) -- both
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var clock = zid.SystemClock.init(io);

    var gen = try zid.Generator(LiveId, zid.SystemClock).init(.{
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
            std.debug.assert(id.raw() > prev.raw());

            if (parts.timestamp == prev_parts.timestamp) {
                // Same millisecond: sequence must have incremented by
                // exactly one, not reset or jumped.
                std.debug.assert(parts.sequence == prev_parts.sequence + 1);
            } else {
                // Clock moved forward: sequence must have reset, and
                // time must never run backwards.
                std.debug.assert(parts.timestamp > prev_parts.timestamp);
                std.debug.assert(parts.sequence == 0);
            }
        }

        previous = id;

        // Alternate 0ms/3ms so roughly half the calls land in the same
        // millisecond as the previous one and half don't.
        const sleep_ms: u64 = if (i % 2 == 0) 0 else 3;
        try io.sleep(.fromMilliseconds(sleep_ms), .awake);
    }

    std.debug.print("\n{d} ids generated under a real SystemClock, all monotonic.\n", .{iterations});
}
