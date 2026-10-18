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
- `lastIssued()` on `Generator` and `AtomicGenerator`: read the most
  recent id so it can be stored and passed to `initAfter` after a
  restart.
- Property tests for the skew tolerance (it rejects exactly when the
  clock is behind by more than the tolerance), for `initAfter`, and for
  `AtomicGenerator` agreeing with `Generator` call for call under a
  random clock.
- MIT `LICENSE`, this changelog, and a macOS/Windows CI matrix.

### Changed
- Fuzz tests for `parse` and `fromRaw` now run against every layout in
  the property tests (including the 1-bit, 0-bit and 64-bit edge
  layouts), not just the 41/10/12 one.
- `ManualClock.advance` saturates at the maximum instead of panicking
  on overflow in safe build modes.
- README: the restart section now explains how a restart without
  `initAfter` can repeat ids, and that cross-node order is approximate.
- Sequencing rules live in one pure function (`successor`) shared by
  both generators. Behavior of `Generator` is unchanged.
