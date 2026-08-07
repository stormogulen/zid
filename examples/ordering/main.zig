// The packed representation deliberately places timestamp bits first,
// followed by node and sequence bits, so ordinary integer comparison
// preserves chronological order.

const std = @import("std");
const zid = @import("zid");

const ExampleId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
});

pub fn main(init: std.process.Init) !void {
    _ = init;

    const earlier = try ExampleId.fromParts(1000, 1, 0);
    const middle = try ExampleId.fromParts(1000, 1, 1);
    const later = try ExampleId.fromParts(1001, 1, 0);

    std.debug.print("earlier: {f}\n", .{earlier});
    std.debug.print("middle:  {f}\n", .{middle});
    std.debug.print("later:   {f}\n\n", .{later});

    std.debug.print("raw ordering:\n", .{});
    std.debug.print(
        "earlier < middle < later = {}\n\n",
        .{
            earlier.raw() < middle.raw() and
                middle.raw() < later.raw(),
        },
    );

    const earlier_text = earlier.toString();
    const middle_text = middle.toString();
    const later_text = later.toString();

    std.debug.print("encoded ordering:\n", .{});
    std.debug.print(
        "earlier < middle < later = {}\n",
        .{
            std.mem.order(u8, &earlier_text, &middle_text) == .lt and
                std.mem.order(u8, &middle_text, &later_text) == .lt,
        },
    );
}
