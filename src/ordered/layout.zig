//! OrderedId bit layout.
//!
//! Responsibilities:
//!
//! - Define field sizes, and a field type sized to each one, so an
//!   out-of-range field value cannot be constructed.
//! - Pack fields into a u64.
//! - Decode fields from a u64.
//! - Say which bits of a u64 the layout uses.
//!
//! Does NOT:
//!
//! - Generate ids.
//! - Read clocks.
//! - Maintain state.

const std = @import("std");
const Epoch = @import("../epoch.zig").Epoch;

pub const Config = struct {
    timestamp_bits: u8,
    node_bits: u8,
    sequence_bits: u8,
    /// Makes ids with otherwise identical configs distinct types.
    tag: type,
    /// What the timestamp counts from. Part of the id's format: ids
    /// with different epochs are different types, and can't be mixed.
    epoch: Epoch = .unix,
};

pub fn Layout(comptime config: Config) type {
    comptime {
        const total =
            @as(u16, config.timestamp_bits) +
            @as(u16, config.node_bits) +
            @as(u16, config.sequence_bits);

        if (total > 64) {
            @compileError("OrderedId layout exceeds 64 bits");
        }

        if (config.timestamp_bits == 0) {
            @compileError("timestamp_bits must be greater than zero");
        }
    }

    return struct {
        pub const timestamp_bits = config.timestamp_bits;
        pub const node_bits = config.node_bits;
        pub const sequence_bits = config.sequence_bits;
        pub const total_bits: u7 = timestamp_bits + node_bits + sequence_bits;

        /// Field types sized exactly to the layout. A value of these
        /// types always fits its field, so packing never has to check.
        pub const Timestamp = std.meta.Int(.unsigned, timestamp_bits);
        pub const Node = std.meta.Int(.unsigned, node_bits);
        pub const Sequence = std.meta.Int(.unsigned, sequence_bits);

        pub const Parts = struct {
            timestamp: Timestamp,
            node: Node,
            sequence: Sequence,
        };

        const sequence_shift: u6 = 0;
        const node_shift: u6 = @intCast(sequence_bits);
        const timestamp_shift: u6 = @intCast(sequence_bits + node_bits);

        /// The bits of a u64 this layout uses. Any raw value with a
        /// bit set outside this mask could not have come from `pack`.
        pub const used_mask: u64 = if (total_bits == 64)
            std.math.maxInt(u64)
        else
            (@as(u64, 1) << @intCast(total_bits)) - 1;

        pub fn pack(parts: Parts) u64 {
            const raw =
                (@as(u64, parts.timestamp) << timestamp_shift) |
                (@as(u64, parts.node) << node_shift) |
                (@as(u64, parts.sequence) << sequence_shift);

            // Pairs with unpack()'s precondition.
            std.debug.assert(raw & ~used_mask == 0);
            return raw;
        }

        /// `raw` must only use bits inside `used_mask`. Untrusted
        /// values go through `OrderedId.fromRaw`, which checks this.
        pub fn unpack(raw: u64) Parts {
            // Pairs with pack()'s postcondition.
            std.debug.assert(raw & ~used_mask == 0);

            return .{
                .timestamp = @truncate(raw >> timestamp_shift),
                .node = @truncate(raw >> node_shift),
                .sequence = @truncate(raw >> sequence_shift),
            };
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

    const parts: L.Parts = .{ .timestamp = 1234, .node = 7, .sequence = 42 };
    try std.testing.expectEqual(parts, L.unpack(L.pack(parts)));
}

test "field types are sized exactly to the layout" {
    const L = Layout(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    try std.testing.expectEqual((1 << 41) - 1, std.math.maxInt(L.Timestamp));
    try std.testing.expectEqual(1023, std.math.maxInt(L.Node));
    try std.testing.expectEqual(4095, std.math.maxInt(L.Sequence));
    try std.testing.expectEqual((1 << 63) - 1, L.used_mask);
}

test "a full 64-bit layout uses every bit" {
    const L = Layout(.{
        .timestamp_bits = 64,
        .node_bits = 0,
        .sequence_bits = 0,
        .tag = struct {},
    });

    try std.testing.expectEqual(std.math.maxInt(u64), L.used_mask);

    const parts: L.Parts = .{ .timestamp = std.math.maxInt(u64), .node = 0, .sequence = 0 };
    try std.testing.expectEqual(parts, L.unpack(L.pack(parts)));
}

test "maximum field values pack without spilling into neighbours" {
    const L = Layout(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    const parts: L.Parts = .{
        .timestamp = std.math.maxInt(L.Timestamp),
        .node = std.math.maxInt(L.Node),
        .sequence = std.math.maxInt(L.Sequence),
    };
    const raw = L.pack(parts);

    try std.testing.expectEqual(L.used_mask, raw);
    try std.testing.expectEqual(parts, L.unpack(raw));
}
