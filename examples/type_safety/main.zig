const std = @import("std");
const zid = @import("zid");

const UserId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
});

const OrderId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
});

// Positive assertion: types with the same bit layout but different
// tags are still distinct — this actually compiles and runs, proving
// the claim rather than just asserting it in a comment.
comptime {
    std.debug.assert(UserId != OrderId);
}

pub fn main(init: std.process.Init) !void {
    var clock = zid.SystemClock.init(init.io);

    var user_gen = try zid.Generator(UserId, zid.SystemClock).init(.{
        .node = 7,
        .clock = &clock,
    });

    var order_gen = try zid.Generator(OrderId, zid.SystemClock).init(.{
        .node = 3,
        .clock = &clock,
    });

    const user_id = try user_gen.next();
        const order_id = try order_gen.next();

        std.debug.print("user_id:  {f}\n", .{user_id});
        std.debug.print("order_id: {f}\n", .{order_id});

        // Positive assertion: an id equals itself.
        std.debug.print(
            "user_id.eql(user_id) = {}\n",
            .{user_id.eql(user_id)},
        );
        std.debug.assert(user_id.eql(user_id));

        // Negative assertion: two ids generated back-to-back from the
        // same generator differ in sequence, so they are not equal —
        // eql() reflects that correctly.
        const another_user_id = try user_gen.next();
        std.debug.print(
            "user_id.eql(another_user_id) = {}\n",
            .{user_id.eql(another_user_id)},
        );
        std.debug.assert(!user_id.eql(another_user_id));
}
