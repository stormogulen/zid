//! Error sets.
//!
//! Each fallible operation gets its own, minimal error set, so callers
//! can switch over exactly the failures that operation can produce.

const encoding = @import("encoding.zig");

/// Converting Unix milliseconds to a layout timestamp
/// (`Generator.timestampFromUnixMillis`, and as part of `Generator.next`).
pub const TimestampError = error{
    /// The time is earlier than the generator's epoch.
    BeforeEpoch,
    /// The epoch-relative timestamp doesn't fit the layout's timestamp
    /// field.
    TimestampOverflow,
};

/// `Generator.next`.
pub const NextError = TimestampError || error{
    /// The clock reads earlier than the previous id's timestamp.
    ClockMovedBackwards,
    /// Every sequence value for the current millisecond is used up.
    SequenceExhausted,
};

/// `Generator.initAfter`.
pub const ResumeError = error{
    /// The id to resume after was issued for a different node.
    NodeMismatch,
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
