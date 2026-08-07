//! OrderedId bit layout.
//!
//! Responsibilities:
//!
//! - Define field sizes.
//! - Pack fields into a u64.
//! - Decode fields from a u64.
//!
//! Does NOT:
//!
//! - Generate ids.
//! - Read clocks.
//! - Maintain state.

const std = @import("std");

pub const Config = struct {
    timestamp_bits: u8,
    node_bits: u8,
    sequence_bits: u8,
    tag: type,
};

pub const Parts = struct {
    timestamp: u64,
    node: u64,
    sequence: u64,
};

pub fn Layout(comptime config: Config) type {
    comptime {
        const total =
            @as(u16, config.timestamp_bits) +
            @as(u16, config.node_bits) +
            @as(u16, config.sequence_bits);

        if (total > 64) {
            @compileError(
                "OrderedId layout exceeds 64 bits",
            );
        }

        if (config.timestamp_bits == 0) {
            @compileError(
                "timestamp_bits must be greater than zero",
            );
        }
    }

    return struct {
        const Self = @This();

        pub const timestamp_bits = config.timestamp_bits;
        pub const node_bits = config.node_bits;
        pub const sequence_bits = config.sequence_bits;

        const sequence_shift: u6 = 0;

        const node_shift: u6 =
            @intCast(sequence_bits);

        const timestamp_shift: u6 =
            @intCast(sequence_bits + node_bits);

        pub const timestamp_mask =
            mask(timestamp_bits);

        pub const node_mask =
            mask(node_bits);

        pub const sequence_mask =
            mask(sequence_bits);

        fn mask(comptime bits: u8) u64 {
            if (bits == 64)
                return std.math.maxInt(u64);

            return (@as(u64, 1) << bits) - 1;
        }

        pub fn pack(
            timestamp: u64,
            node: u64,
            sequence: u64,
        ) u64 {
            return ((timestamp & timestamp_mask) << timestamp_shift) |
                ((node & node_mask) << node_shift) |
                ((sequence & sequence_mask) << sequence_shift);
        }

        pub fn unpack(raw: u64) Parts {
            return .{
                .timestamp = (raw >> timestamp_shift) & timestamp_mask,
                .node = (raw >> node_shift) & node_mask,
                .sequence = raw & sequence_mask,
            };
        }

        //
        // Same values as the masks,
        //
        pub fn maxTimestamp() u64 {
            return timestamp_mask;
        }

        pub fn maxNode() u64 {
            return node_mask;
        }

        pub fn maxSequence() u64 {
            return sequence_mask;
        }
    };
}

test "layout round trip" {
    const L = Layout(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    const raw =
        L.pack(1234, 7, 42);

    const parts =
        L.unpack(raw);

    try std.testing.expectEqual(
        1234,
        parts.timestamp,
    );

    try std.testing.expectEqual(
        7,
        parts.node,
    );

    try std.testing.expectEqual(
        42,
        parts.sequence,
    );
}

test "max*() report the exact value the field can hold" {
    const L = Layout(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    try std.testing.expectEqual(@as(u64, (1 << 41) - 1), L.maxTimestamp());
    try std.testing.expectEqual(@as(u64, 1023), L.maxNode());
    try std.testing.expectEqual(@as(u64, 4095), L.maxSequence());
}
