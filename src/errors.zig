//! Errors
//!

pub const Error = error{
    FieldOutOfRange,
    InvalidNode,
    ClockMovedBackwards,
    SequenceExhausted,
    ClockBeforeEpoch,
    TimestampOverflow,
};
