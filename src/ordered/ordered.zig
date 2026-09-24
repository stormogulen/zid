//! Strongly typed OrderedId.
//!
//! Two configs with different .tag values always produce
//! distinct types, even with identical bit widths.
//!
//! Responsibilities:
//!
//! - Build ids from typed fields (infallible: the field types already
//!   guarantee the values fit).
//! - Accept raw values and strings from outside only after checking
//!   that they could have been produced by this layout.
//! - Decode, compare, order, format, and encode ids.
//! - Give the smallest and largest possible id for a timestamp, for
//!   range queries.
//!
//! Does NOT:
//!
//! - Generate ids or read clocks (see Generator).

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

        pub const Layout = IdLayout;
        pub const Parts = IdLayout.Parts;
        pub const Timestamp = IdLayout.Timestamp;
        pub const Node = IdLayout.Node;
        pub const Sequence = IdLayout.Sequence;

        /// Always a value `IdLayout.pack` could produce: no bits set
        /// outside `IdLayout.used_mask`. Every constructor upholds this.
        raw_value: u64,

        // "Zero-cost": an id is exactly one u64 in memory, so arrays of
        // ids, hash map keys and struct fields cost no more than the
        // raw integer would.
        comptime {
            std.debug.assert(@sizeOf(Self) == @sizeOf(u64));
            std.debug.assert(@alignOf(Self) == @alignOf(u64));
        }

        pub fn fromParts(parts: Parts) Self {
            const result: Self = .{ .raw_value = IdLayout.pack(parts) };

            // Pairs with decode(): what goes in must come back out.
            std.debug.assert(std.meta.eql(result.decode(), parts));
            return result;
        }

        /// Accepts a raw value from outside (a database column, a wire
        /// message). Rejects values with bits outside the layout
        /// instead of silently ignoring them, which would let two
        /// different raw values decode to the same fields.
        pub fn fromRaw(raw_value: u64) errors.RawError!Self {
            if (raw_value & ~IdLayout.used_mask != 0) {
                return error.ReservedBitsSet;
            }
            return .{ .raw_value = raw_value };
        }

        pub fn raw(self: Self) u64 {
            return self.raw_value;
        }

        pub fn decode(self: Self) Parts {
            return IdLayout.unpack(self.raw_value);
        }

        pub fn timestamp(self: Self) Timestamp {
            return self.decode().timestamp;
        }

        pub fn node(self: Self) Node {
            return self.decode().node;
        }

        pub fn sequence(self: Self) Sequence {
            return self.decode().sequence;
        }

        /// Raw comparison is exact because every constructor keeps the
        /// bits outside the layout at zero.
        pub fn eql(self: Self, other: Self) bool {
            return self.raw_value == other.raw_value;
        }

        /// Orders ids by timestamp first, then node, then sequence (the
        /// order the fields are packed in). For ids from one generator
        /// this is the order they were issued in. Across nodes it is
        /// chronological to the millisecond, with ties broken by node.
        pub fn order(self: Self, other: Self) std.math.Order {
            return std.math.order(self.raw_value, other.raw_value);
        }

        /// For `std.mem.sort` and friends:
        /// `std.mem.sort(UserId, ids, {}, UserId.lessThan)`.
        pub fn lessThan(context: void, a: Self, b: Self) bool {
            _ = context;
            return a.order(b) == .lt;
        }

        /// The smallest id any node can produce at `at`. Together with
        /// `maxAt`, turns a time range into an id range:
        /// `WHERE id BETWEEN minAt(t0).raw() AND maxAt(t1).raw()`.
        pub fn minAt(at: Timestamp) Self {
            return fromParts(.{ .timestamp = at, .node = 0, .sequence = 0 });
        }

        /// The largest id any node can produce at `at`.
        pub fn maxAt(at: Timestamp) Self {
            return fromParts(.{
                .timestamp = at,
                .node = std.math.maxInt(Node),
                .sequence = std.math.maxInt(Sequence),
            });
        }

        /// Length of the string `toString` produces.
        pub const encoded_len = encoding.encoded_len;

        /// Encodes this id as a fixed-width, sort-preserving string:
        /// comparing two such strings with plain ASCII/byte ordering
        /// agrees with comparing the ids themselves, so encoded ids
        /// stay chronologically sortable as text (in a URL, a log
        /// line, a database column, ...).
        pub fn toString(self: Self) [encoding.encoded_len]u8 {
            return encoding.encode(self.raw_value);
        }

        /// Decodes a string produced by `toString` back into an id.
        /// Rejects malformed input rather than silently misreading it:
        /// the string must be well-formed, and the value it encodes
        /// must fit this layout.
        pub fn parse(s: []const u8) errors.ParseError!Self {
            return fromRaw(try encoding.decode(s));
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const parts = self.decode();

            try writer.print(
                "OrderedId({d})[t={d},n={d},s={d}]",
                .{ self.raw_value, parts.timestamp, parts.node, parts.sequence },
            );
        }
    };
}

const TestId = OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, .tag = struct {} });

test "fromParts accepts every field at its maximum" {
    const id = TestId.fromParts(.{
        .timestamp = std.math.maxInt(TestId.Timestamp),
        .node = std.math.maxInt(TestId.Node),
        .sequence = std.math.maxInt(TestId.Sequence),
    });

    try std.testing.expectEqual(std.math.maxInt(TestId.Node), id.node());
    try std.testing.expectEqual(std.math.maxInt(TestId.Sequence), id.sequence());
}

test "eql compares by raw value" {
    const a = TestId.fromParts(.{ .timestamp = 100, .node = 1, .sequence = 1 });
    const b = TestId.fromParts(.{ .timestamp = 100, .node = 1, .sequence = 1 });
    const c = TestId.fromParts(.{ .timestamp = 100, .node = 1, .sequence = 2 });

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

    // Type comparison happens at compile time: if the two `tag`
    // structs didn't make A and B distinct, this test would fail.
    try std.testing.expect(A != B);
}

test "fromRaw round trips through decode" {
    const original = TestId.fromParts(.{ .timestamp = 999, .node = 5, .sequence = 3 });
    const reconstructed = try TestId.fromRaw(original.raw());

    try std.testing.expect(original.eql(reconstructed));
    try std.testing.expectEqual(original.decode(), reconstructed.decode());
}

test "fromRaw rejects bits outside the layout" {
    // 41 + 10 + 12 = 63 bits, so bit 63 is never used.
    const valid = TestId.fromParts(.{ .timestamp = 5, .node = 1, .sequence = 1 });

    try std.testing.expectError(
        error.ReservedBitsSet,
        TestId.fromRaw(valid.raw() | (1 << 63)),
    );
}

test "format produces the expected string" {
    const id = TestId.fromParts(.{ .timestamp = 1234, .node = 7, .sequence = 42 });

    var buf: [128]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{f}", .{id});

    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "OrderedId({d})[t=1234,n=7,s=42]",
        .{id.raw()},
    );

    try std.testing.expectEqualStrings(expected, formatted);
}

test "toString/parse round trip preserves the id" {
    const original = TestId.fromParts(.{ .timestamp = 1234, .node = 7, .sequence = 42 });
    const s = original.toString();
    const reconstructed = try TestId.parse(&s);

    try std.testing.expect(original.eql(reconstructed));
}

test "toString output sorts the same way the ids do" {
    const earlier = TestId.fromParts(.{ .timestamp = 100, .node = 0, .sequence = 0 });
    const later = TestId.fromParts(.{ .timestamp = 200, .node = 0, .sequence = 0 });

    const earlier_s = earlier.toString();
    const later_s = later.toString();

    try std.testing.expect(std.mem.order(u8, &earlier_s, &later_s) == .lt);
}

test "parse rejects malformed strings" {
    try std.testing.expectError(error.InvalidLength, TestId.parse("TOOSHORT"));
    try std.testing.expectError(error.InvalidCharacter, TestId.parse("I000000000000"));
}

test "parse rejects a well-formed string whose value doesn't fit the layout" {
    // "8000000000000" encodes 1 << 63: valid Base32, but bit 63 is
    // outside this 63-bit layout.
    try std.testing.expectError(error.ReservedBitsSet, TestId.parse("8000000000000"));
}

test "order and lessThan follow timestamp, then node, then sequence" {
    const a = TestId.fromParts(.{ .timestamp = 100, .node = 9, .sequence = 9 });
    const b = TestId.fromParts(.{ .timestamp = 101, .node = 0, .sequence = 0 });
    const c = TestId.fromParts(.{ .timestamp = 101, .node = 0, .sequence = 1 });

    try std.testing.expectEqual(.lt, a.order(b));
    try std.testing.expectEqual(.gt, c.order(b));
    try std.testing.expectEqual(.eq, b.order(b));

    var ids = [_]TestId{ c, a, b };
    std.mem.sort(TestId, &ids, {}, TestId.lessThan);
    try std.testing.expectEqualSlices(TestId, &.{ a, b, c }, &ids);
}

test "minAt and maxAt bound every id at that timestamp" {
    const min = TestId.minAt(500);
    const max = TestId.maxAt(500);
    const inside = TestId.fromParts(.{ .timestamp = 500, .node = 3, .sequence = 7 });

    try std.testing.expect(min.order(inside) != .gt);
    try std.testing.expect(inside.order(max) != .gt);

    // The neighbouring milliseconds fall outside.
    try std.testing.expectEqual(.lt, TestId.maxAt(499).order(min));
    try std.testing.expectEqual(.gt, TestId.minAt(501).order(max));
}
