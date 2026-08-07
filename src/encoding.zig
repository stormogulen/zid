//! Fixed-width, sort-preserving string encoding for raw id values.
//!
//! Responsibilities:
//!
//! - Encode a u64 as a 13-character string using Crockford's Base32
//!   alphabet, most-significant bits first, so that plain ASCII
//!   string comparison of two encoded ids agrees with the numeric
//!   (and therefore chronological, for an OrderedId) order of the
//!   underlying u64 values.
//! - Decode that string back into a u64, rejecting malformed input
//!   instead of silently truncating or wrapping.
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
/// confusion with 1, 1, 0, V. Both the alphabet's symbol order and
/// its ASCII byte order increase together, which is what makes
/// lexicographic string comparison agree with numeric comparison.
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

const invalid_value: u8 = 0xFF;

/// alphabet character -> 5-bit value, or `invalid` for any byte that
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

/// Number of characters needed to encode a full u64: the leading
/// character holds the top 4 bits, and the remaining 12 characters
/// hold 5 bits each -- 4 + 12*5 = 64 bits, exactly, with no spare
/// or missing bits.
pub const encoded_len = 13;

pub const DecodeError = error{
    /// Input was not exactly `encoded_len` bytes.
    InvalidLength,
    /// Input contained a byte outside the Crockford alphabet.
    InvalidCharacter,
    /// The leading character encoded a value greater than 4 bits can
    /// hold. Such a string could never have come from `encode`, and
    /// decoding it as-is would silently misinterpret bits.
    Overflow,
};

/// Encodes `value` as a fixed-width, sort-preserving string.
pub fn encode(value: u64) [encoded_len]u8 {
    var out: [encoded_len]u8 = undefined;

    // Leading character: top 4 bits (bits 60-63).
    out[0] = alphabet[@as(usize, @intCast((value >> 60) & 0xF))];

    // Remaining characters: 5 bits each, most-significant first,
    // covering bits 0-59.
    inline for (1..encoded_len) |i| {
        const shift: u6 = (encoded_len - 1 - i) * 5;
        out[i] = alphabet[@as(usize, @intCast((value >> shift) & 0x1F))];
    }

    return out;
}

/// Decodes a string produced by `encode` back into a u64. Rejects
/// anything that isn't exactly `encoded_len` bytes of alphabet
/// characters with a leading character that fits in 4 bits.
pub fn decode(s: []const u8) DecodeError!u64 {
    if (s.len != encoded_len) {
        return DecodeError.InvalidLength;
    }

    const first = decode_table[s[0]];
    if (first == invalid_value) {
        return DecodeError.InvalidCharacter;
    }
    if (first > 0xF) {
        return DecodeError.Overflow;
    }

    var value: u64 = first;

    for (s[1..]) |c| {
        const digit = decode_table[c];
        if (digit == invalid_value) {
            return DecodeError.InvalidCharacter;
        }
        value = (value << 5) | digit;
    }

    return value;
}

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
    try std.testing.expectError(error.Overflow, decode("G000000000000"));

    // 'F' is alphabet index 15 (0xF), which fits exactly.
    _ = try decode("F000000000000");
}
