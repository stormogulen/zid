//! Generator for `RandomOrderedId`.
//!
//! Responsibilities:
//!
//! - Combine a clock and a random source into ids that strictly increase
//!   for this generator.
//! - On a new millisecond, start from fresh random bits (with the top bit
//!   clear); within a millisecond, add one to the previous id's random
//!   bits. That is what keeps one generator's ids increasing, and fresh
//!   bits are what keep different generators apart.
//! - Report a clock that steps back, and random bits that run out, as
//!   errors, like `Generator` does.
//!
//! Does NOT:
//!
//! - Need or coordinate node ids: that is the point of this id type.
//! - Guarantee anything across threads. Give each thread its own
//!   generator; with no node ids there is nothing to hand out.
//! - Persist the last id (store `lastIssued()` and use `initAfter`).
//!
//! Collisions: two generators issue the same id only if, in the same
//! millisecond, their counting ranges overlap. Each starts at a random
//! point below the top random bit, so for two generators that each issue
//! n ids in one millisecond the chance is about 2n / 2^(random_bits - 1):
//! with 80 bits, negligible. Adding one within a millisecond makes this
//! slightly likelier than fully random ids would be; that is the price of
//! ordered ids.

const std = @import("std");
const errors = @import("../errors.zig");
const generator = @import("../generator.zig");
const clock = @import("../clock.zig");
const RandomOrderedId = @import("id.zig").RandomOrderedId;

pub fn RandomGenerator(
    comptime IdType: type,
    comptime ClockType: type,
    comptime RandomType: type,
) type {
    comptime {
        if (!generator.isContainer(IdType) or !@hasDecl(IdType, "Random") or !@hasDecl(IdType, "fromParts") or !@hasDecl(IdType, "timestampFromUnixMillis")) {
            @compileError("RandomGenerator's IdType must be a zid.RandomOrderedId type, found " ++ @typeName(IdType));
        }
        generator.checkClock("RandomGenerator", ClockType);
        checkRandomSource(RandomType);
    }

    return struct {
        const Self = @This();

        pub const Id = IdType;
        pub const Timestamp = IdType.Timestamp;
        pub const NextError = errors.NextError;

        /// Before the first id there is nothing to continue from; after
        /// it, the last id is all the state the generator needs.
        pub const State = union(enum) {
            fresh,
            after: IdType,
        };

        // Internal state; construct with init/initAfter/initAfterTimestamp.
        clock: *ClockType,
        random: *RandomType,
        skew_tolerance_ms: u64,
        state: State,

        pub const Options = struct {
            /// Borrowed: must outlive the generator.
            clock: *ClockType,
            /// Borrowed: must outlive the generator. `zid.IoRandom` in a
            /// program; a seeded `std.Random.DefaultPrng` in tests.
            random: *RandomType,
            /// Same meaning as `Generator.Options.clock_skew_tolerance_ms`.
            /// `std.math.maxInt(u64)` absorbs every step back, which is
            /// what TigerBeetle's clients do.
            clock_skew_tolerance_ms: u64 = 0,
        };

        pub fn init(options: Options) Self {
            return .{
                .clock = options.clock,
                .random = options.random,
                .skew_tolerance_ms = options.clock_skew_tolerance_ms,
                .state = .fresh,
            };
        }

        /// Continues after `last`, an id this generator's previous run
        /// issued: every new id is greater. Can't fail: there is no node
        /// to check. Same clock rules as `Generator.initAfter`.
        pub fn initAfter(options: Options, last: IdType) Self {
            var self = init(options);
            self.state = .{ .after = last };
            return self;
        }

        /// Continues after a whole reserved millisecond; the same
        /// reserve-ahead pattern as `Generator.initAfterTimestamp`.
        pub fn initAfterTimestamp(options: Options, reserved: Timestamp) Self {
            return initAfter(options, IdType.maxAt(reserved));
        }

        pub fn lastIssued(self: *const Self) ?IdType {
            return switch (self.state) {
                .fresh => null,
                .after => |last| last,
            };
        }

        /// Draws once from the random source on every call, first, even
        /// when the bits end up unused (same millisecond) or the call
        /// fails. So the draws never depend on the clock, which keeps a
        /// seeded test deterministic in the simplest way.
        pub fn next(self: *Self) NextError!IdType {
            const fresh = drawStart(IdType, self.random);
            const timestamp = try IdType.timestampFromUnixMillis(self.clock.now().millis);
            const id = try successor(IdType, self.lastIssued(), timestamp, fresh, self.skew_tolerance_ms);
            self.state = .{ .after = id };
            return id;
        }

        /// Like `next`, but waits out `SequenceExhausted` (rare: see
        /// `RandomConfig.random_bits`). See `Generator.nextRetrying`.
        pub fn nextRetrying(self: *Self, waiter: anytype) NextError!IdType {
            return generator.retryingNext(Self, self, waiter);
        }
    };
}

/// Random bits to start a new millisecond from: uniform below the top
/// random bit, so at least half the field is left to count through.
pub fn drawStart(comptime IdType: type, source: anytype) IdType.Random {
    var bytes: [16]u8 = undefined;
    source.fill(&bytes);
    const drawn = std.mem.readInt(u128, &bytes, .little);
    return @intCast(drawn & (std.math.maxInt(IdType.Random) >> 1));
}

/// The id that follows `last` when the clock reads `timestamp_now`, given
/// fresh random bits for a new millisecond. Pure: no clock, no randomness
/// of its own, no state. Guarantees the result is greater than `last`.
pub fn successor(
    comptime IdType: type,
    last: ?IdType,
    timestamp_now: IdType.Timestamp,
    fresh: IdType.Random,
    skew_tolerance_ms: u64,
) errors.NextError!IdType {
    const previous = last orelse return IdType.fromParts(.{ .timestamp = timestamp_now, .random = fresh });

    var timestamp = timestamp_now;
    if (timestamp < previous.timestamp()) {
        if (previous.timestamp() - timestamp > skew_tolerance_ms) return error.ClockMovedBackwards;
        timestamp = previous.timestamp(); // Small step back: stay put.
    }

    const id = if (timestamp > previous.timestamp())
        IdType.fromParts(.{ .timestamp = timestamp, .random = fresh })
    else id: {
        if (previous.random() == std.math.maxInt(IdType.Random)) return error.SequenceExhausted;
        break :id IdType.fromParts(.{ .timestamp = timestamp, .random = previous.random() + 1 });
    };

    // The always-on check, by zid's rule (see generator.zig's successor).
    if (id.raw() <= previous.raw()) {
        @panic("zid: random successor produced an id that is not greater than the last");
    }
    return id;
}

fn checkRandomSource(comptime RandomType: type) void {
    const signature = "`pub fn fill(self: *" ++ @typeName(RandomType) ++ ", buffer: []u8) void` (std.Random.DefaultPrng and zid.IoRandom have it)";
    if (!generator.isContainer(RandomType) or !@hasDecl(RandomType, "fill")) {
        @compileError("RandomGenerator's RandomType must provide " ++ signature);
    }
    const info = @typeInfo(@TypeOf(RandomType.fill));
    if (info != .@"fn") @compileError(@typeName(RandomType) ++ ".fill must be a function: " ++ signature);
    const f = info.@"fn";
    if (f.params.len != 2 or f.params[0].type != *RandomType or f.params[1].type != []u8 or f.return_type != void) {
        @compileError(@typeName(RandomType) ++ ".fill has the wrong signature; expected " ++ signature);
    }
}

const TestId = RandomOrderedId(.{ .timestamp_bits = 48, .random_bits = 80, .tag = struct {}, .epoch = .unix });
const Gen = RandomGenerator(TestId, clock.ManualClock, std.Random.DefaultPrng);

test "a new millisecond starts below the top random bit; the same one counts up" {
    var manual = clock.ManualClock{ .value = 1_000 };
    var prng: std.Random.DefaultPrng = .init(1);
    var gen = Gen.init(.{ .clock = &manual, .random = &prng });

    const first = try gen.next();
    try std.testing.expectEqual(1_000, first.timestamp());
    try std.testing.expect(first.random() <= std.math.maxInt(TestId.Random) >> 1);

    const second = try gen.next();
    try std.testing.expectEqual(first.random() + 1, second.random());

    manual.advance(1);
    const third = try gen.next();
    try std.testing.expectEqual(1_001, third.timestamp());
    try std.testing.expect(third.raw() > second.raw());
}

test "the same seed gives the same ids" {
    var clock_a = clock.ManualClock{ .value = 5 };
    var clock_b = clock.ManualClock{ .value = 5 };
    var prng_a: std.Random.DefaultPrng = .init(42);
    var prng_b: std.Random.DefaultPrng = .init(42);
    var a = Gen.init(.{ .clock = &clock_a, .random = &prng_a });
    var b = Gen.init(.{ .clock = &clock_b, .random = &prng_b });
    for (0..100) |i| {
        if (i % 7 == 0) {
            clock_a.advance(1);
            clock_b.advance(1);
        }
        try std.testing.expectEqual(try a.next(), try b.next());
    }
}

test "clock steps back: rejected by default, absorbed within the tolerance" {
    var manual = clock.ManualClock{ .value = 1_000 };
    var prng: std.Random.DefaultPrng = .init(2);
    var strict = Gen.init(.{ .clock = &manual, .random = &prng });
    _ = try strict.next();
    manual.set(999);
    try std.testing.expectError(error.ClockMovedBackwards, strict.next());

    manual.set(1_000);
    var lenient = Gen.init(.{ .clock = &manual, .random = &prng, .clock_skew_tolerance_ms = std.math.maxInt(u64) });
    const before = try lenient.next();
    manual.set(0);
    const after = try lenient.next();
    try std.testing.expectEqual(before.timestamp(), after.timestamp());
    try std.testing.expectEqual(before.random() + 1, after.random());
}

test "tiny random field: exhaustion is reported, then the next millisecond is fine" {
    const TinyId = RandomOrderedId(.{ .timestamp_bits = 8, .random_bits = 2, .tag = struct {}, .epoch = .unix });
    var manual = clock.ManualClock{ .value = 3 };
    var prng: std.Random.DefaultPrng = .init(3);
    var gen = RandomGenerator(TinyId, clock.ManualClock, std.Random.DefaultPrng).init(.{ .clock = &manual, .random = &prng });

    // Starts at 0 or 1 (top bit clear), so 3 or 2 ids fit before 3 runs out.
    var issued: usize = 0;
    while (gen.next()) |_| issued += 1 else |err| try std.testing.expectEqual(error.SequenceExhausted, err);
    try std.testing.expect(issued >= 3 - 1 and issued <= 3);

    manual.advance(1);
    try std.testing.expectEqual(4, (try gen.next()).timestamp());
}

test "initAfter and initAfterTimestamp never go at or below what they resume from" {
    var manual = clock.ManualClock{ .value = 1_000 };
    var prng: std.Random.DefaultPrng = .init(4);
    const last = TestId.fromParts(.{ .timestamp = 1_000, .random = 17 });

    var resumed = Gen.initAfter(.{ .clock = &manual, .random = &prng }, last);
    try std.testing.expectEqual(18, (try resumed.next()).random());

    var reserved = Gen.initAfterTimestamp(.{ .clock = &manual, .random = &prng }, 1_000);
    try std.testing.expectError(error.SequenceExhausted, reserved.next());
    manual.set(1_001);
    try std.testing.expectEqual(1_001, (try reserved.next()).timestamp());
}

test "two generators sharing a millisecond don't collide in practice" {
    var manual = clock.ManualClock{ .value = 1_000 };
    var prng_a: std.Random.DefaultPrng = .init(10);
    var prng_b: std.Random.DefaultPrng = .init(11);
    var a = Gen.init(.{ .clock = &manual, .random = &prng_a });
    var b = Gen.init(.{ .clock = &manual, .random = &prng_b });

    var ids: [2_000]TestId = undefined;
    for (ids[0..1_000], ids[1_000..]) |*x, *y| {
        x.* = try a.next();
        y.* = try b.next();
    }
    std.mem.sort(TestId, &ids, {}, TestId.lessThan);
    for (ids[1..], ids[0 .. ids.len - 1]) |later, earlier| {
        try std.testing.expect(later.raw() > earlier.raw());
    }
}
