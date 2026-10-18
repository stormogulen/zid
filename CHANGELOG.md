# Changelog

## Unreleased

### Added
- `AtomicGenerator`: lock-free generator that several threads can share
  for a single node id (compare-and-swap on the last id).
- `Generator.nextRetrying` / `AtomicGenerator.nextRetrying`: wait out
  `SequenceExhausted` with a caller-supplied waiter; `zid.SpinWait`
  is a ready-made busy-wait.
- `clock_skew_tolerance_ms` option: absorb small backwards clock steps
  instead of returning `ClockMovedBackwards`. Default 0 (unchanged).
- `OrderedId.max_unix_millis`: the last Unix millisecond a type can
  represent.
- `examples/shared_generator`, run with `zig build run-shared-generator`.
- `OrderedId.writeString` and `OrderedId.string()`: print the encoded
  id to a writer or through `{f}` without a temporary buffer.
- Encoding tests: fixed known vectors, an every-byte-in-every-position
  alphabet check, length checks, single-bit placement, and ordering
  across character boundaries. Strict decoding (uppercase only) is now
  covered by a test.
- MIT `LICENSE`, this changelog, and a macOS/Windows CI matrix.

### Changed
- Sequencing rules live in one pure function (`successor`) shared by
  both generators. Behavior of `Generator` is unchanged.
