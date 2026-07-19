//! Strongly typed OrderedId.
//!
//! Every invocation creates a unique Zig type.
//!

const std = @import("std");
const layout = @import("layout.zig");
const errors = @import("../errors.zig");

pub fn OrderedId(
    comptime config: layout.Config,
) type {
    const IdLayout = layout.Layout(config);

    return struct {
        const Self = @This();

        pub const Parts = layout.Parts;
        pub const Layout = IdLayout;

        raw_value: u64,

        pub fn fromParts(
            timestamp_value: u64,
            node_value: u64,
            sequence_value: u64,
        ) errors.Error!Self {
            if (timestamp_value > IdLayout.timestamp_mask) {
                return errors.Error.FieldOutOfRange;
            }

            if (node_value > IdLayout.node_mask) {
                return errors.Error.FieldOutOfRange;
            }

            if (sequence_value > IdLayout.sequence_mask) {
                return errors.Error.FieldOutOfRange;
            }

            return .{
                .raw_value = IdLayout.pack(
                    timestamp_value,
                    node_value,
                    sequence_value,
                ),
            };
        }

        pub fn fromRaw(
            raw_value: u64,
        ) Self {
            return .{
                .raw_value = raw_value,
            };
        }

        pub fn raw(
            self: Self,
        ) u64 {
            return self.raw_value;
        }

        pub fn decode(
            self: Self,
        ) Parts {
            return IdLayout.unpack(
                self.raw_value,
            );
        }

        pub fn timestamp(
            self: Self,
        ) u64 {
            return self.decode().timestamp;
        }

        pub fn node(
            self: Self,
        ) u64 {
            return self.decode().node;
        }

        pub fn sequence(
            self: Self,
        ) u64 {
            return self.decode().sequence;
        }

        pub fn eql(
            self: Self,
            other: Self,
        ) bool {
            return self.raw_value == other.raw_value;
        }

        pub fn format(
            self: Self,
            writer: *std.Io.Writer,
        ) !void {
            const parts = self.decode();

            try writer.print(
                "OrderedId({d})[t={d},n={d},s={d}]",
                .{ self.raw_value, parts.timestamp, parts.node, parts.sequence },
            );
        }
    };
}

test "fromParts rejects out-of-range fields" {
    const TestId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} });

    try std.testing.expectError(
        error.FieldOutOfRange,
        TestId.fromParts(0, TestId.Layout.maxNode() + 1, 0),
    );

    try std.testing.expectError(
        error.FieldOutOfRange,
        TestId.fromParts(0, 0, TestId.Layout.maxSequence() + 1),
    );

    _ = try TestId.fromParts(0, TestId.Layout.maxNode(), TestId.Layout.maxSequence());
}

test "eql compares by raw value" {
    const TestId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} });

    const a = try TestId.fromParts(100, 1, 1);
    const b = try TestId.fromParts(100, 1, 1);
    const c = try TestId.fromParts(100, 1, 2);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "identical bit widths still produce distinct types" {
    const A = OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    const B = OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
    });

    // NOTE: If this didn't compile, A and B would be the same type
    // and this comparison itself wouldn't type-check as written.
    try std.testing.expect(A != B);
}
