const std = @import("std");
const zid = @import("zid");

// A recent reference point instead of 1970, so the 41 timestamp bits
// last until about 2094 instead of 2039. The epoch is part of the id
// type: ids with a different epoch are a different type.
const UserId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
    .epoch = .fromUnixMillis(1_735_689_600_000), // 2025-01-01T00:00:00Z
});

pub fn main(init: std.process.Init) !void {
    var clock = zid.MonotonicClock.init(init.io);

    var gen = zid.Generator(UserId, zid.MonotonicClock).init(.{
        .node = 7,
        .clock = &clock,
    });

    const first = try gen.next();
    const second = try gen.next();

    const first_parts = first.decode();
    const second_parts = second.decode();

    std.debug.print(
        "id={d} epoch_relative_ms={d} unix_ms={d} node={d} sequence={d}\n",
        .{
            first.raw(),
            first_parts.timestamp,
            first.unixMillis(),
            first_parts.node,
            first_parts.sequence,
        },
    );

    std.debug.print(
        "next id={d} epoch_relative_ms={d} unix_ms={d} sequence={d}\n",
        .{
            second.raw(),
            second_parts.timestamp,
            second.unixMillis(),
            second_parts.sequence,
        },
    );

    std.debug.print("first.eql(first)  = {}\n", .{first.eql(first)});
    std.debug.print("first.eql(second) = {}\n", .{first.eql(second)});

    std.debug.print("formatted: {f}\n", .{first});
}
