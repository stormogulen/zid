//! Time-ordered ids that need no node id: a timestamp and random bits.
//!
//! The layout TigerBeetle recommends and ULIDs use: the timestamp in the
//! high bits and random bits below it, in one u128. Two generators never
//! have to be told apart by a node id; they stay apart because their
//! random bits differ. That is probabilistic: two generators could issue
//! the same id, but with enough random bits the chance is negligible (see
//! the "Collisions" note in generator.zig).
//!
//! Responsibilities:
//!
//! - Build ids from typed fields (infallible: the field types already
//!   guarantee the values fit).
//! - Accept raw values and strings from outside only after checking that
//!   they could have been produced by this layout.
//! - Decode, compare, order, format, and encode ids. With 48 timestamp
//!   bits, 80 random bits and `.epoch = .unix`, the encoded string is a
//!   valid ULID.
//! - Convert between epoch-relative timestamps and Unix milliseconds.
//!
//! Does NOT:
//!
//! - Generate ids, read clocks or draw randomness (see RandomGenerator).

const std = @import("std");
const errors = @import("../errors.zig");
const encoding = @import("../encoding.zig");
const Epoch = @import("../epoch.zig").Epoch;

const codec = encoding.Codec(u128);

pub const RandomConfig = struct {
    /// 48 for TigerBeetle- and ULID-style ids: with a 2025 epoch that
    /// lasts about 8,900 years.
    timestamp_bits: u8,
    /// 80 for TigerBeetle- and ULID-style ids. At least 2: a generator
    /// starts each millisecond with the top random bit clear, so it can
    /// always issue as many ids again before the field runs out.
    random_bits: u8,
    /// Makes ids with otherwise identical configs distinct types.
    tag: type,
    /// What the timestamp counts from. Required, as in `zid.Config`.
    epoch: Epoch,
    /// What `{f}` calls the id. Display only.
    name: []const u8 = "RandomOrderedId",
};

pub fn RandomOrderedId(comptime config: RandomConfig) type {
    const layout_bits = @as(u16, config.timestamp_bits) + config.random_bits;
    comptime {
        if (layout_bits > 128) @compileError("RandomOrderedId layout exceeds 128 bits");
        if (config.timestamp_bits == 0) @compileError("timestamp_bits must be greater than zero");
        if (config.random_bits < 2) {
            @compileError("random_bits must be at least 2: a generator starts each millisecond with the top random bit clear");
        }
    }

    const TimestampInt = std.meta.Int(.unsigned, config.timestamp_bits);
    const RandomInt = std.meta.Int(.unsigned, config.random_bits);

    comptime {
        // Every timestamp must map to a u64 Unix millisecond, as in OrderedId.
        // This also caps the timestamp at 64 bits, since clocks are u64.
        if (std.math.maxInt(TimestampInt) > std.math.maxInt(u64) - config.epoch.unix_millis) {
            @compileError("RandomOrderedId epoch plus the largest timestamp doesn't fit in u64 Unix milliseconds");
        }
    }

    const random_shift: u7 = @intCast(config.random_bits);
    const layout_mask: u128 = if (layout_bits == 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(layout_bits)) - 1;

    return enum(u128) {
        /// Always a value `fromParts` could produce: no bits set outside
        /// the layout. Every constructor upholds this.
        _,

        const Self = @This();

        pub const Timestamp = TimestampInt;
        pub const Random = RandomInt;
        pub const Parts = struct {
            timestamp: Timestamp,
            random: Random,
        };

        pub const Layout = struct {
            pub const timestamp_bits = config.timestamp_bits;
            pub const random_bits = config.random_bits;
            pub const total_bits: u8 = @intCast(layout_bits);
            /// The bits of a u128 this layout uses.
            pub const used_mask: u128 = layout_mask;
        };

        pub const epoch: Epoch = config.epoch;
        /// The last Unix millisecond this id type can represent.
        pub const max_unix_millis: u64 = config.epoch.unix_millis + std.math.maxInt(Timestamp);

        comptime {
            std.debug.assert(@sizeOf(Self) == @sizeOf(u128));
        }

        pub fn fromParts(parts: Parts) Self {
            const result: Self = @enumFromInt((@as(u128, parts.timestamp) << random_shift) | parts.random);
            // Pairs with decode(): what goes in must come back out.
            std.debug.assert(std.meta.eql(result.decode(), parts));
            return result;
        }

        /// Builds an id from runtime integers, checking each against its field.
        pub fn fromInts(timestamp_value: u64, random_value: u128) errors.RandomFieldError!Self {
            return fromParts(.{
                .timestamp = std.math.cast(Timestamp, timestamp_value) orelse return error.TimestampOutOfRange,
                .random = std.math.cast(Random, random_value) orelse return error.RandomOutOfRange,
            });
        }

        /// Accepts a raw value from outside, rejecting bits outside the layout.
        pub fn fromRaw(raw_value: u128) errors.RawError!Self {
            if (raw_value & ~layout_mask != 0) return error.ReservedBitsSet;
            return @enumFromInt(raw_value);
        }

        pub fn raw(self: Self) u128 {
            return @intFromEnum(self);
        }

        pub fn decode(self: Self) Parts {
            std.debug.assert(self.raw() & ~layout_mask == 0);
            return .{
                .timestamp = @truncate(self.raw() >> random_shift),
                .random = @truncate(self.raw()),
            };
        }

        pub fn timestamp(self: Self) Timestamp {
            return self.decode().timestamp;
        }

        pub fn random(self: Self) Random {
            return self.decode().random;
        }

        /// When this id was created, in Unix milliseconds.
        pub fn unixMillis(self: Self) u64 {
            return unixMillisFromTimestamp(self.timestamp());
        }

        pub fn timestampFromUnixMillis(unix_millis: u64) errors.TimestampError!Timestamp {
            if (unix_millis < epoch.unix_millis) return error.BeforeEpoch;
            return std.math.cast(Timestamp, unix_millis - epoch.unix_millis) orelse error.TimestampOverflow;
        }

        pub fn unixMillisFromTimestamp(at: Timestamp) u64 {
            return epoch.unix_millis + at;
        }

        pub fn eql(self: Self, other: Self) bool {
            return self == other;
        }

        /// Orders ids by timestamp, then random bits. For ids from one
        /// generator that is the order they were issued in; across
        /// generators it is chronological to the millisecond.
        pub fn order(self: Self, other: Self) std.math.Order {
            return std.math.order(self.raw(), other.raw());
        }

        pub fn lessThan(context: void, a: Self, b: Self) bool {
            _ = context;
            return a.order(b) == .lt;
        }

        /// The smallest id any generator can produce at `at`.
        pub fn minAt(at: Timestamp) Self {
            return fromParts(.{ .timestamp = at, .random = 0 });
        }

        /// The largest id any generator can produce at `at`.
        pub fn maxAt(at: Timestamp) Self {
            return fromParts(.{ .timestamp = at, .random = std.math.maxInt(Random) });
        }

        /// Length of the string `toString` produces: 26 characters.
        pub const encoded_len = codec.encoded_len;

        /// Fixed-width, sort-preserving string; see `OrderedId.toString`.
        pub fn toString(self: Self) [encoded_len]u8 {
            return codec.encode(self.raw());
        }

        /// Decodes a string produced by `toString`. Strict, like `OrderedId.parse`.
        pub fn parse(s: []const u8) errors.ParseError!Self {
            return fromRaw(try codec.decode(s));
        }

        pub fn writeString(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(&self.toString());
        }

        pub fn fmtString(self: Self) std.fmt.Alt(Self, writeString) {
            return .{ .data = self };
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const parts = self.decode();
            try writer.print("{s}({d})[t={d},r=0x{x}]", .{ config.name, self.raw(), parts.timestamp, parts.random });
        }
    };
}

const TestId = RandomOrderedId(.{ .timestamp_bits = 48, .random_bits = 80, .tag = struct {}, .epoch = .unix });

test "fields round trip and sit where the layout says" {
    const id = TestId.fromParts(.{ .timestamp = 1234, .random = 0xABCDEF });
    try std.testing.expectEqual(1234, id.timestamp());
    try std.testing.expectEqual(0xABCDEF, id.random());
    try std.testing.expectEqual((@as(u128, 1234) << 80) | 0xABCDEF, id.raw());
}

test "ids order by timestamp, then random bits" {
    const a = TestId.fromParts(.{ .timestamp = 10, .random = std.math.maxInt(TestId.Random) });
    const b = TestId.fromParts(.{ .timestamp = 11, .random = 0 });
    const c = TestId.fromParts(.{ .timestamp = 11, .random = 1 });
    try std.testing.expectEqual(.lt, a.order(b));
    try std.testing.expectEqual(.lt, b.order(c));
    try std.testing.expect(TestId.minAt(11).order(b) != .gt and c.order(TestId.maxAt(11)) == .lt);
}

test "fromInts and fromRaw reject what doesn't fit" {
    try std.testing.expectError(error.TimestampOutOfRange, TestId.fromInts(1 << 48, 0));
    try std.testing.expectError(error.RandomOutOfRange, TestId.fromInts(0, 1 << 80));

    const Small = RandomOrderedId(.{ .timestamp_bits = 20, .random_bits = 20, .tag = struct {}, .epoch = .unix });
    try std.testing.expectError(error.ReservedBitsSet, Small.fromRaw(1 << 40));
    _ = try Small.fromRaw((1 << 40) - 1);
}

test "a 48/80 id with the Unix epoch encodes as a ULID" {
    // From the ULID spec: the largest ULID, and its timestamp field.
    const max = TestId.fromParts(.{
        .timestamp = std.math.maxInt(TestId.Timestamp),
        .random = std.math.maxInt(TestId.Random),
    });
    try std.testing.expectEqualStrings("7ZZZZZZZZZZZZZZZZZZZZZZZZZ", &max.toString());
    try std.testing.expectEqual(std.math.maxInt(u48), max.unixMillis());
}

test "toString and parse round trip; parse is strict" {
    const id = TestId.fromParts(.{ .timestamp = 1_735_689_600_000, .random = 42 });
    const text = id.toString();
    try std.testing.expect(id.eql(try TestId.parse(&text)));
    try std.testing.expectError(error.InvalidLength, TestId.parse("TOOSHORT"));
    try std.testing.expectError(error.InvalidCharacter, TestId.parse("0" ** 25 ++ "a"));
}

test "format uses the name and shows the random bits in hex" {
    const Named = RandomOrderedId(.{ .timestamp_bits = 48, .random_bits = 80, .tag = struct {}, .epoch = .unix, .name = "OrderKey" });
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{Named.fromParts(.{ .timestamp = 7, .random = 255 })});
    try std.testing.expect(std.mem.startsWith(u8, text, "OrderKey("));
    try std.testing.expect(std.mem.endsWith(u8, text, ")[t=7,r=0xff]"));
}

test "max_unix_millis: a 2025 epoch with 48 bits lasts thousands of years" {
    const AppId = RandomOrderedId(.{ .timestamp_bits = 48, .random_bits = 80, .tag = struct {}, .epoch = .fromUnixMillis(1_735_689_600_000) });
    try std.testing.expectEqual(1_735_689_600_000 + (1 << 48) - 1, AppId.max_unix_millis);
    try std.testing.expectError(error.BeforeEpoch, AppId.timestampFromUnixMillis(0));
}
