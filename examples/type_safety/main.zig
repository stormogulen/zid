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
    var clock = zid.MonotonicClock.init(init.io);

    var user_gen = zid.Generator(UserId, zid.MonotonicClock).init(.{
        .node = 7,
        .clock = &clock,
    });

    var order_gen = zid.Generator(OrderId, zid.MonotonicClock).init(.{
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
    try check(user_id.eql(user_id), "an id equals itself");

    // Negative assertion: two ids generated back-to-back from the
    // same generator differ in sequence, so they are not equal —
    // eql() reflects that correctly.
    const another_user_id = try user_gen.next();
    std.debug.print(
        "user_id.eql(another_user_id) = {}\n",
        .{user_id.eql(another_user_id)},
    );
    try check(!user_id.eql(another_user_id), "consecutive ids differ");
}
