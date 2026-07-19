const std = @import("std");
const zid = @import("zid");

const UserId = zid.OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} });

// An arbitrary recent reference point instead of 1970  from Unix epoch directly.
const app_epoch = zid.Epoch.fromUnixMillis(1_735_689_600_000); // 2025-01-01T00:00:00Z

pub fn main(init: std.process.Init) !void {
    var clock = zid.SystemClock.init(init.io);

    var gen = try zid.Generator(UserId, zid.SystemClock).init(.{
        .node = 7,
        .clock = &clock,
        .epoch = app_epoch,
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
            gen.unixMillis(first),
            first_parts.node,
            first_parts.sequence,
        },
    );

    std.debug.print(
        "next id={d} epoch_relative_ms={d} unix_ms={d} sequence={d}\n",
        .{
            second.raw(),
            second_parts.timestamp,
            gen.unixMillis(second),
            second_parts.sequence,
        },
    );

    std.debug.print("first.eql(first)  = {}\n", .{first.eql(first)});
    std.debug.print("first.eql(second) = {}\n", .{first.eql(second)});

    std.debug.print("formatted: {f}\n", .{first});
}
