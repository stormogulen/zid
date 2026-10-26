//! Facts about the target being compiled for.
//!
//! Its own file so that asking whether `AtomicGenerator` is supported
//! doesn't pull in `atomic_generator.zig` (and, in a test build, its
//! tests, which can't compile on a target that lacks 64-bit atomics).

/// Whether Zig provides 64-bit atomics on this target, which
/// `AtomicGenerator` needs.
///
/// An approximation: it assumes 64-bit atomics exactly on targets with
/// 64-bit pointers. That holds for every target tested with Zig 0.16.0
/// (64-bit ones have them; x86 and 32-bit ARM don't). It is wrong for
/// rarities such as the x32 ABI, which has 32-bit pointers and 64-bit
/// atomics; there `AtomicGenerator` is refused although it would work.
/// Use `Generator` there, or change this line.
pub const has_64_bit_atomics = @sizeOf(usize) >= 8;
