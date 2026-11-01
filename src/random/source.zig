//! Random sources for `RandomGenerator`.
//!
//! A random source is any type with
//! `pub fn fill(self: *Self, buffer: []u8) void`. `std.Random.DefaultPrng`
//! already has that shape, which makes tests deterministic: seed it and
//! every id is known in advance.

const std = @import("std");

/// The operating system's randomness, through `std.Io`: a
/// cryptographically secure generator that `std.Io` seeds itself. What a
/// program should use outside tests.
pub const IoRandom = struct {
    io: std.Io,

    pub fn init(io: std.Io) IoRandom {
        return .{ .io = io };
    }

    pub fn fill(self: *IoRandom, buffer: []u8) void {
        self.io.random(buffer);
    }
};

test "IoRandom fills buffers with different bytes" {
    var source = IoRandom.init(std.testing.io);
    var a: [16]u8 = @splat(0);
    var b: [16]u8 = @splat(0);
    source.fill(&a);
    source.fill(&b);
    // Equal by chance with probability 2^-128.
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
