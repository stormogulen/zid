//! Error sets.
//!
//! Each fallible operation gets its own, minimal error set, so callers
//! can switch over exactly the failures that operation can produce.

const encoding = @import("encoding.zig");

/// `Generator.next`.
pub const NextError = error{
    /// The clock reads earlier than the generator's epoch.
    ClockBeforeEpoch,
    /// The epoch-relative timestamp no longer fits the layout's
    /// timestamp field.
    TimestampOverflow,
    /// The clock reads earlier than the previous id's timestamp.
    ClockMovedBackwards,
    /// Every sequence value for the current millisecond is used up.
    SequenceExhausted,
};

/// `OrderedId.fromRaw`.
pub const RawError = error{
    /// The value has bits set outside the layout's fields, so it could
    /// not have been produced by `fromParts` or a `Generator`.
    ReservedBitsSet,
};

/// `OrderedId.parse`.
pub const ParseError = encoding.DecodeError || RawError;

/// `Generator.unixMillis`, `Epoch.fromUnixSeconds`.
pub const OverflowError = error{
    /// The result does not fit in a u64 of Unix milliseconds.
    Overflow,
};
