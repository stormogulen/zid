//! Strongly typed OrderedId.
//!
//! "Two configs with different .tag values always produce
//! distinct types, even with identical bit widths.
//!

const std = @import("std");
const layout = @import("layout.zig");
const errors = @import("../errors.zig");
const encoding = @import("../encoding.zig");

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

        /// Length of the string `toString` produces.
        pub const encoded_len = encoding.encoded_len;

        /// Encodes this id as a fixed-width, sort-preserving string:
        /// comparing two such strings with plain ASCII/byte ordering
        /// agrees with comparing the ids themselves, so encoded ids
        /// stay chronologically sortable as text (in a URL, a log
        /// line, a database column, ...).
        pub fn toString(
            self: Self,
        ) [encoding.encoded_len]u8 {
            return encoding.encode(self.raw_value);
        }

        /// Decodes a string produced by `toString` back into an id.
        /// Rejects malformed input rather than silently misreading it;
        /// see `encoding.DecodeError` for the specific failure modes.
        pub fn parse(
            s: []const u8,
        ) encoding.DecodeError!Self {
            return .{ .raw_value = try encoding.decode(s) };
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

test "fromRaw round trips through decode" {
    const TestId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} });

    const original = try TestId.fromParts(999, 5, 3);
    const reconstructed = TestId.fromRaw(original.raw());

    try std.testing.expect(original.eql(reconstructed));
    try std.testing.expectEqual(@as(u64, 999), reconstructed.timestamp());
    try std.testing.expectEqual(@as(u64, 5), reconstructed.node());
    try std.testing.expectEqual(@as(u64, 3), reconstructed.sequence());
}

test "format produces the expected string" {
    const TestId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} });

    const id = try TestId.fromParts(1234, 7, 42);

    const formatted = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{id});
    defer std.testing.allocator.free(formatted);

    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "OrderedId({d})[t=1234,n=7,s=42]",
        .{id.raw()},
    );
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, formatted);
}

test "toString/parse round trip preserves the id" {
    const TestId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} });

    const original = try TestId.fromParts(1234, 7, 42);
    const s = original.toString();
    const reconstructed = try TestId.parse(&s);

    try std.testing.expect(original.eql(reconstructed));
}

test "toString output sorts the same way the ids do" {
    const TestId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} });

    const earlier = try TestId.fromParts(100, 0, 0);
    const later = try TestId.fromParts(200, 0, 0);

    const earlier_s = earlier.toString();
    const later_s = later.toString();

    try std.testing.expect(std.mem.order(u8, &earlier_s, &later_s) == .lt);
}

test "parse rejects malformed strings" {
    const TestId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} });

    try std.testing.expectError(error.InvalidLength, TestId.parse("TOOSHORT"));
    try std.testing.expectError(error.InvalidCharacter, TestId.parse("I000000000000"));
}

// test "format produces the expected string" {
//     const TestId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} });

//     const id = try TestId.fromParts(1234, 7, 42);

//     const formatted = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{id});
//     defer std.testing.allocator.free(formatted);

//     const expected = try std.fmt.allocPrint(
//         std.testing.allocator,
//         "OrderedId({d})[t=1234,n=7,s=42]",
//         .{id.raw()},
//     );
//     defer std.testing.allocator.free(expected);

//     try std.testing.expectEqualStrings(expected, formatted);
// }
