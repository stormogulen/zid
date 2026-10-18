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
    /// hold, so the string represents a number larger than a u64. Such
    /// a string could never have come from `encode`, and decoding it
    /// as-is would silently misinterpret bits. (Deliberately not
    /// `error.Overflow`: Zig error names are global, and that name
    /// already means arithmetic overflow in `std.math`.)
    ValueTooLarge,
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
        return DecodeError.ValueTooLarge;
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
    var boundary: u6 = 5;
    while (boundary < 60) : (boundary += 5) {
        const base = @as(u64, 1) << boundary;
        for ([_]u64{ base - 1, base, base + 1 }) |value| {
            const current = encode(value);
            try std.testing.expect(std.mem.order(u8, &previous, &current) != .gt);
            previous = current;
        }
    }
}
