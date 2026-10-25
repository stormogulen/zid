# Changelog

## Unreleased

### Documentation and CI
- Document that `AtomicGenerator` ids are ordered by allocation, not by
  the order calls return, that it does not compile on 32-bit targets
  (checked for x86-linux and arm-linux-gnueabihf), and that
  lock-freedom needs a non-blocking clock.
- Document that a clock skew tolerance can make `nextRetrying` wait up
  to the tolerance, and that plain `initAfter` is not crash-safe.
- CI compiles the benchmark (`zig build examples`) and cross-compiles
  the tests for `aarch64-linux` and `riscv64-linux` (`zig build check`,
  informational).
- CI compiles `Generator` for `x86-linux` (`zig build check-generator`).
- Package `examples/` with the library.

### Added
- `AtomicGenerator`: generator that several threads can share for a
  single node id (compare-and-swap on the last id). Lock-free; does not
  compile on 32-bit targets, where `Generator` remains available.
- `Generator.nextRetrying` / `AtomicGenerator.nextRetrying`: wait out
  `SequenceExhausted` with a caller-supplied waiter; `zid.SpinWait`
  is a ready-made busy-wait.
- `clock_skew_tolerance_ms` option: absorb small backwards clock steps
  instead of returning `ClockMovedBackwards`. Default 0 (unchanged).
- `OrderedId.max_unix_millis`: the last Unix millisecond a type can
  represent.
- `examples/shared_generator`, run with `zig build run-shared-generator`.
- `OrderedId.writeString` and `OrderedId.fmtString()`: print the encoded
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

- `initAfterTimestamp` on `Generator` and `AtomicGenerator`: resume after
  a whole reserved millisecond, for the reserve-ahead pattern (save a
  future timestamp before handing out ids up to it). README shows how.

- README examples are compiled and run (`readme_test.zig`, part of
  `zig build test`), and a test fails when a README block and its
  compiled version differ.
- `zig build examples` compiles every example without running it; CI
  runs it, so the benchmark can't stop building unnoticed.
- `Generator.Id` and `AtomicGenerator.Id`: the id type a generator makes.
- A test for `SystemClock`.

### Changed
- Both generators' `nextRetrying` share one implementation, which checks
  up front that the waiter has a `wait()` method (a clear compile error
  instead of one from inside the loop).
- Renamed `OrderedId.string()` to `fmtString()`: it returns a `{f}`
  formatter, not a string, and `toString` already names the conversion.
- The "ids strictly increase" check moved from `Generator.next` into
  `successor`, so `AtomicGenerator` is covered by it too.
- `Generator` and `AtomicGenerator` validate their type parameters with
  one shared check. `AtomicGenerator` now gives the same clear compile
  errors as `Generator`, and both reject a `now` that isn't a function
  taking `self: *ClockType`.
- The skew tolerance property test now also checks that a step back is
  only absorbed when it is within the tolerance.
- The encoding ordering test now covers the leading character's 60-bit
  boundary and checks strict ordering.
- Fuzz tests for `parse` and `fromRaw` now run against every layout in
  the property tests (including the 1-bit, 0-bit and 64-bit edge
  layouts), not just the 41/10/12 one.
- `ManualClock.advance` saturates at the maximum instead of panicking
  on overflow in safe build modes.
- README: the restart section now explains how a restart without
  `initAfter` can repeat ids, and that cross-node order is approximate.
- Sequencing rules live in one pure function (`successor`) shared by
  both generators. Behavior of `Generator` is unchanged.
