//! Sequential id generator.
//!
//! Responsibilities:
//!
//! - Combine a clock, a node id, and a sequence counter into ids.
//! - Guarantee ids increase monotonically for a fixed node,
//!   as long as the clock does not move backwards.
//! - Detect sequence exhaustion within a millisecond and report it,
//!   rather than silently wrapping and colliding.
//! - Measure timestamps relative to a configurable epoch, and
//!   convert back to Unix milliseconds on request.
//!
//! Does NOT:
//!
//! - Read wall-clock time directly (delegates to ClockType).
//! - Retry, sleep, or spin on exhaustion (caller's decision).
//! - Coordinate node ids across processes.
//! - Guarantee correctness across threads (not thread-safe).

const std = @import("std");
const errors = @import("errors.zig");
const epoch_mod = @import("epoch.zig");
const ordered = @import("ordered/ordered.zig");
const clock = @import("clock.zig");

pub fn Generator(
    comptime IdType: type,
    comptime ClockType: type,
) type {
    const max_node = IdType.Layout.node_mask;
    const max_sequence = IdType.Layout.sequence_mask;
    const max_timestamp = IdType.Layout.timestamp_mask;

    return struct {
        const Self = @This();

        clock: *ClockType,
        node: u64,
        epoch: epoch_mod.Epoch = epoch_mod.Epoch.unix(),
        last_timestamp: ?u64 = null,
        sequence: u64 = 0,

        pub fn init(
            options: struct {
                node: u64,
                clock: *ClockType,
                epoch: epoch_mod.Epoch = epoch_mod.Epoch.unix(),
            },
        ) errors.Error!Self {
            if (options.node > max_node) {
                return errors.Error.InvalidNode;
            }

            return .{
                .clock = options.clock,
                .node = options.node,
                .epoch = options.epoch,
            };
        }

        pub fn next(
            self: *Self,
        ) errors.Error!IdType {
            const now = self.clock.now();

            if (now < self.epoch.unix_millis) {
                return errors.Error.ClockBeforeEpoch;
            }

            const timestamp = now - self.epoch.unix_millis;

            if (timestamp > max_timestamp) {
                return errors.Error.TimestampOverflow;
            }

            if (self.last_timestamp) |last| {
                if (timestamp < last) {
                    return errors.Error.ClockMovedBackwards;
                }

                if (timestamp == last) {
                    // sequence is about to become self.sequence + 1; reject if that would overflow
                    if (self.sequence >= max_sequence) {
                        return errors.Error.SequenceExhausted;
                    }
                    self.sequence += 1;
                    std.debug.assert(self.sequence <= max_sequence);
                } else {
                    self.sequence = 0;
                }
            } else {
                self.sequence = 0;
            }

            self.last_timestamp = timestamp;

            return IdType.fromParts(
                timestamp,
                self.node,
                self.sequence,
            );
        }

        /// Converts an id's decoded (epoch-relative) timestamp back
        /// into Unix milliseconds, using this generator's epoch.
        pub fn unixMillis(
            self: Self,
            id: IdType,
        ) u64 {
            return id.timestamp() + self.epoch.unix_millis;
        }
    };
}

test "first id starts at sequence zero" {

    const TestId = ordered.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    var manual = clock.ManualClock{ .value = 1000 };
    var gen = try Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    const id = try gen.next();

    try std.testing.expectEqual(@as(u64, 1000), id.timestamp());
    try std.testing.expectEqual(@as(u64, 0), id.sequence());
}

test "sequence increments within the same millisecond" {

    const TestId = ordered.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    var manual = clock.ManualClock{ .value = 1000 };
    var gen = try Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    const first = try gen.next();
    const second = try gen.next();

    try std.testing.expectEqual(first.timestamp(), second.timestamp());
    try std.testing.expectEqual(@as(u64, 0), first.sequence());
    try std.testing.expectEqual(@as(u64, 1), second.sequence());
}

test "sequence exhaustion is reported, not silently wrapped" {

    // sequence_bits = 1 means max_sequence == 1.
    const TestId = ordered.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 1,
        .tag = struct {},
    });

    var manual = clock.ManualClock{ .value = 1000 };
    var gen = try Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    _ = try gen.next(); // sequence 0
    _ = try gen.next(); // sequence 1, field now full

    try std.testing.expectError(
        error.SequenceExhausted,
        gen.next(),
    );

    // Advancing the clock
    // NOTE: Generator holds a *pointer* to this ManualClock, not a copy.
    manual.advance(1);

    const id = try gen.next();
    try std.testing.expectEqual(@as(u64, 1001), id.timestamp());
    try std.testing.expectEqual(@as(u64, 0), id.sequence());
}

test "clock moving backwards is rejected" {

    const TestId = ordered.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    var manual = clock.ManualClock{ .value = 1000 };
    var gen = try Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    _ = try gen.next();
    manual.set(500);

    try std.testing.expectError(
        error.ClockMovedBackwards,
        gen.next(),
    );
}

test "invalid node is rejected at init" {

    const TestId = ordered.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 2, // max_node == 3
        .sequence_bits = 21,
        .tag = struct {},
    });

    var manual = clock.ManualClock{};

    try std.testing.expectError(
        error.InvalidNode,
        Generator(TestId, clock.ManualClock).init(.{
            .node = 4,
            .clock = &manual,
        }),
    );
}

test "custom epoch offsets stored timestamp; unixMillis recovers it" {

    const TestId = ordered.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    var manual = clock.ManualClock{ .value = 1_700_000_500 };

    var gen = try Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
        .epoch = epoch_mod.Epoch.fromUnixMillis(1_700_000_000),
    });

    const id = try gen.next();

    try std.testing.expectEqual(@as(u64, 500), id.timestamp());
    try std.testing.expectEqual(@as(u64, 1_700_000_500), gen.unixMillis(id));
}

test "clock reading before the epoch is rejected" {

    const TestId = ordered.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    var manual = clock.ManualClock{ .value = 100 };

    var gen = try Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
        .epoch = epoch_mod.Epoch.fromUnixMillis(1_000),
    });

    try std.testing.expectError(error.ClockBeforeEpoch, gen.next());
}

test "clock reading exactly at the epoch yields timestamp zero" {

    const TestId = ordered.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    var manual = clock.ManualClock{ .value = 1_000 };
    var gen = try Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
        .epoch = epoch_mod.Epoch.fromUnixMillis(1_000),
    });

    const id = try gen.next();
    try std.testing.expectEqual(@as(u64, 0), id.timestamp());
}

test "timestamp overflow is rejected" {

    // timestamp_bits = 2 means max_timestamp == 3.
    const TestId = ordered.OrderedId(.{
        .timestamp_bits = 2,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    // One past max_timestamp (3), with the default unix epoch (offset 0),
    // so the epoch-relative timestamp equals the clock value directly.
    var manual = clock.ManualClock{ .value = 4 };

    var gen = try Generator(TestId, clock.ManualClock).init(.{
        .node = 1,
        .clock = &manual,
    });

    try std.testing.expectError(
        error.TimestampOverflow,
        gen.next(),
    );
}
