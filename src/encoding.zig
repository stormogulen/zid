//! Fixed-width, sort-preserving string encoding for raw id values.
//!
//! Responsibilities:
//!
//! - Encode an unsigned integer (a u64 in 13 characters, a u128 in 26)
//!   as a fixed-width string using Crockford's Base32
//!   alphabet, most-significant bits first, so that plain ASCII
//!   string comparison of two encoded ids agrees with the numeric
//!   (and therefore chronological, for an OrderedId) order of the
//!   underlying u64 values.
//! - Decode that string back into a u64, rejecting malformed input
//!   instead of silently truncating or wrapping.
//!
//! Crockford's alphabet, not Crockford's decoding. His spec also has
//! the decoder accept lowercase and read `I` and `L` as `1` and `O` as
//! `0`. zid's decoder doesn't: it accepts exactly the uppercase
//! characters the encoder writes. That gives every value exactly one
//! valid string, so two strings name the same id if and only if they
//! are equal, which matters when the string is a database key or a URL.
//! Normalize user-typed input yourself before `parse` if you want the
//! lenient rules. Crockford's optional check symbol isn't used either.
//!
//! Does NOT:
//!
//! - Know about OrderedId, layouts, node ids, or clocks. Encodes and
//!   decodes plain u64 values only; OrderedId.toString/OrderedId.parse
//!   are thin wrappers around this module.
//! - Allocate. Encoding writes into a caller-sized `[encoded_len]u8`;
//!   decoding reads a `[]const u8` slice.

const std = @import("std");

/// Crockford's Base32 alphabet: excludes I, L, O, U to avoid visual
/// confusion (I and L with 1, O with 0, U with V). Both the alphabet's
/// symbol order and its ASCII byte order increase together, which is
/// what makes lexicographic string comparison agree with numeric
/// comparison.
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

// The sort-preserving property depends on exactly this: 32 symbols,
// strictly increasing in ASCII order. Checked here so a change to the
// alphabet fails the build, not just a test that happens to notice.
comptime {
    if (alphabet.len != 32) {
        @compileError(std.fmt.comptimePrint("Base32 alphabet must have 32 symbols, has {d}", .{alphabet.len}));
    }
    for (alphabet[0 .. alphabet.len - 1], alphabet[1..], 0..) |a, b, i| {
        if (a >= b) {
            @compileError(std.fmt.comptimePrint(
                "Base32 alphabet must be in strictly increasing ASCII order: '{c}' (index {d}) is not below '{c}'",
                .{ a, i, b },
            ));
        }
    }
}

const invalid_value: u8 = 0xFF;

/// alphabet character -> 5-bit value, or `invalid_value` for any byte that
/// isn't in the alphabet. Built at compile time: no runtime init,
/// no shared mutable state, safe to call from any number of threads.
const decode_table: [256]u8 = blk: {
    var table: [256]u8 = undefined;
    for (&table) |*entry| entry.* = invalid_value;
    for (alphabet, 0..) |c, i| {
        table[c] = i;
    }
    break :blk table;
};

pub const DecodeError = error{
    /// Input was not exactly the encoded length.
    InvalidLength,
    /// Input contained a byte outside the alphabet. That includes
    /// lowercase letters and `I`, `L`, `O` and `U`, which Crockford's own
    /// decoding would accept or map; see the top of this file.
    InvalidCharacter,
    /// The leading character encoded a value greater than its few bits
    /// can hold, so the string represents a number larger than the
    /// integer type. Such a string could never have come from `encode`,
    /// and decoding it as-is would silently misinterpret bits.
    /// (Deliberately not `error.Overflow`: Zig error names are global,
    /// and that name already means arithmetic overflow in `std.math`.)
    ValueTooLarge,
};

/// Fixed-width, sort-preserving Base32 for an unsigned integer type `T`,
/// most-significant bits first. Every character holds 5 bits except the
/// leading one, which holds what is left over: for a u64, 4 + 12*5 = 64
/// bits in 13 characters; for a u128, 3 + 25*5 = 128 bits in 26
/// characters (the same width and alphabet as a ULID).
pub fn Codec(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .int or info.int.signedness != .unsigned) {
        @compileError("Codec needs an unsigned integer type, found " ++ @typeName(T));
    }
    const bits = info.int.bits;
    const len = (bits + 4) / 5;
    const lead_bits = bits - 5 * (len - 1);
    const Shift = std.math.Log2Int(T);

    return struct {
        /// Length of every encoded string for `T`.
        pub const encoded_len = len;

        /// Encodes `value` as a fixed-width, sort-preserving string.
        pub fn encode(value: T) [len]u8 {
            var out: [len]u8 = undefined;
            inline for (0..len) |i| {
                const shift: Shift = @intCast((len - 1 - i) * 5);
                const mask: T = if (i == 0) (1 << lead_bits) - 1 else 0x1F;
                out[i] = alphabet[@intCast((value >> shift) & mask)];
            }
            return out;
        }

        /// Decodes a string produced by `encode` back into a `T`. Rejects
        /// anything that isn't exactly `encoded_len` alphabet characters
        /// with a leading character that fits its bits.
        pub fn decode(s: []const u8) DecodeError!T {
            if (s.len != len) {
                return DecodeError.InvalidLength;
            }

            var value: T = 0;
            for (s, 0..) |c, i| {
                const digit = decode_table[c];
                if (digit == invalid_value) {
                    return DecodeError.InvalidCharacter;
                }
                if (i == 0 and digit >= (1 << lead_bits)) {
                    return DecodeError.ValueTooLarge;
                }
                value = (value << 5) | digit;
            }
            return value;
        }
    };
}

/// The u64 codec, which `OrderedId` uses: 13 characters.
const codec64 = Codec(u64);
pub const encoded_len = codec64.encoded_len;
pub const encode = codec64.encode;
pub const decode = codec64.decode;

test "round trips zero, max, and arbitrary values" {
    const cases = [_]u64{
        0,
        1,
        std.math.maxInt(u64),
        1_700_000_000_123,
        0xDEAD_BEEF_0000_0001,
    };

    for (cases) |value| {
        const s = encode(value);
        try std.testing.expectEqual(value, try decode(&s));
    }
}

test "encoded strings sort the same way the underlying values do" {
    const values = [_]u64{
        0,
        1,
        2,
        1_000,
        1_000_000,
        std.math.maxInt(u64) - 1,
        std.math.maxInt(u64),
    };

    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const smaller = encode(values[i - 1]);
        const larger = encode(values[i]);

        try std.testing.expect(std.mem.order(u8, &smaller, &larger) == .lt);
    }
}

test "decode rejects the wrong length" {
    try std.testing.expectError(error.InvalidLength, decode("TOOSHORT"));
    try std.testing.expectError(error.InvalidLength, decode("WAYTOOLONGTOBEVALID"));
}

test "decode rejects characters outside the alphabet" {
    // 'I', 'L', 'O', 'U' are deliberately excluded from Crockford's
    // alphabet, and lowercase is not accepted either.
    try std.testing.expectError(error.InvalidCharacter, decode("I000000000000"));
    try std.testing.expectError(error.InvalidCharacter, decode("000000000000u"));
}

test "decode rejects a leading character that doesn't fit in 4 bits" {
    // 'G' is alphabet index 16 (0x10), which needs 5 bits -- too
    // wide for the leading character's 4-bit budget.
    try std.testing.expectError(error.ValueTooLarge, decode("G000000000000"));

    // 'F' is alphabet index 15 (0xF), which fits exactly.
    _ = try decode("F000000000000");
}

test "known vectors" {
    // Fixed expected strings, so a change to the alphabet, the width or
    // the bit order can't pass by round-tripping against itself.
    try std.testing.expectEqualStrings("0000000000000", &encode(0));
    try std.testing.expectEqualStrings("0000000000001", &encode(1));
    try std.testing.expectEqualStrings("000000000000Z", &encode(31));
    try std.testing.expectEqualStrings("0000000000010", &encode(32));
    try std.testing.expectEqualStrings("0000000000100", &encode(1024));
    try std.testing.expectEqualStrings("1000000000000", &encode(1 << 60));
    try std.testing.expectEqualStrings("7ZZZZZZZZZZZZ", &encode(std.math.maxInt(i64)));
    try std.testing.expectEqualStrings("8000000000000", &encode(1 << 63));
    try std.testing.expectEqualStrings("FZZZZZZZZZZZZ", &encode(std.math.maxInt(u64)));
}

test "decode accepts exactly the alphabet, in every position" {
    // Every byte value, in every position: accepted if and only if it is
    // an alphabet character (and, in the leading position, fits in 4
    // bits). Lowercase letters and Crockford's I/L/O aliases are not in
    // the alphabet, so they are rejected too: decoding is strict.
    for (0..256) |byte| {
        const c: u8 = @intCast(byte);
        const index = std.mem.indexOfScalar(u8, alphabet, c);

        for (0..encoded_len) |position| {
            var text: [encoded_len]u8 = @splat('0');
            text[position] = c;

            if (index == null) {
                try std.testing.expectError(error.InvalidCharacter, decode(&text));
            } else if (position == 0 and index.? > 0xF) {
                try std.testing.expectError(error.ValueTooLarge, decode(&text));
            } else {
                _ = try decode(&text);
            }
        }
    }
}

test "decoding is strict about case and look-alike characters" {
    try std.testing.expectError(error.InvalidCharacter, decode("000000000000a"));
    try std.testing.expectError(error.InvalidCharacter, decode("000000000000O"));
    try std.testing.expectError(error.InvalidCharacter, decode("000000000000l"));
    try std.testing.expectError(error.InvalidCharacter, decode("00000000000-0"));
    try std.testing.expectError(error.InvalidCharacter, decode("00000000000 0"));
}

test "every length but encoded_len is rejected" {
    const text = "0" ** (encoded_len + 3);
    for (0..text.len + 1) |len| {
        if (len == encoded_len) continue;
        try std.testing.expectError(error.InvalidLength, decode(text[0..len]));
    }
}

test "each bit of a u64 lands in its own place and round trips" {
    for (0..64) |bit| {
        const value = @as(u64, 1) << @intCast(bit);
        const text = encode(value);

        try std.testing.expectEqual(value, try decode(&text));

        // A single set bit lands in exactly one character and never
        // spreads into its neighbours.
        var nonzero: usize = 0;
        for (text) |c| {
            if (c != '0') nonzero += 1;
        }
        try std.testing.expectEqual(1, nonzero);
    }
}

test "ordering holds across character boundaries" {
    // Values just below and above each 5-bit boundary, plus the 4-bit
    // leading character's boundary.
    var previous = encode(0);
    var boundary: u7 = 5;
    while (boundary <= 60) : (boundary += 5) {
        const base = @as(u64, 1) << @intCast(boundary);
        for ([_]u64{ base - 1, base, base + 1 }) |value| {
            const current = encode(value);
            // Every value here is distinct and larger than the one before.
            try std.testing.expectEqual(.lt, std.mem.order(u8, &previous, &current));
            previous = current;
        }
    }
}

test "u128: known vectors, including the largest ULID" {
    const C = Codec(u128);
    try std.testing.expectEqual(26, C.encoded_len);
    try std.testing.expectEqualStrings("0" ** 26, &C.encode(0));
    try std.testing.expectEqualStrings("0" ** 25 ++ "1", &C.encode(1));
    // The ULID spec gives this as the largest valid ULID.
    try std.testing.expectEqualStrings("7ZZZZZZZZZZZZZZZZZZZZZZZZZ", &C.encode(std.math.maxInt(u128)));
    try std.testing.expectEqual(std.math.maxInt(u128), try C.decode("7ZZZZZZZZZZZZZZZZZZZZZZZZZ"));
}

test "u128: the leading character holds 3 bits" {
    const C = Codec(u128);
    try std.testing.expectError(error.ValueTooLarge, C.decode("8" ++ "0" ** 25));
    try std.testing.expectError(error.InvalidLength, C.decode("0" ** 13));
    try std.testing.expectError(error.InvalidCharacter, C.decode("0" ** 25 ++ "u"));
}

test "u128: each bit lands in its own place and round trips" {
    const C = Codec(u128);
    for (0..128) |bit| {
        const value = @as(u128, 1) << @intCast(bit);
        const text = C.encode(value);
        try std.testing.expectEqual(value, try C.decode(&text));

        var nonzero: usize = 0;
        for (text) |c| {
            if (c != '0') nonzero += 1;
        }
        try std.testing.expectEqual(1, nonzero);
    }
}
