# Changelog

## Unreleased

### Documentation and CI
- Both generators are checked against an independent reference model
  (a property test over every layout, and a fuzz target driving random
  clock walks). The model doesn't use `successor`, so it catches bugs the
  generators would share; for example a new millisecond starting at
  sequence 1, which keeps ids increasing and passed every earlier
  property test.
- Property test running both generators over every test layout,
  including zero-width fields and the full 64-bit timestamp.
- Compile-time check that the Base32 alphabet is 32 symbols in strictly
  increasing ASCII order.
- Document that `AtomicGenerator` ids are ordered by allocation, not by
  the order calls return, that it does not compile on 32-bit targets
  (checked for x86-linux and arm-linux-gnueabihf), and that
  lock-freedom needs a non-blocking clock.
- Document that a clock skew tolerance can make `nextRetrying` wait up
  to the tolerance, and that plain `initAfter` is not crash-safe.
- CI compiles the benchmark (`zig build examples`), compiles the tests
  for `aarch64-linux`, `riscv64-linux` and `arm-linux-gnueabihf`
  (`zig build check -Dtarget=...`), and runs them on `x86-linux`.
- Package `examples/` with the library.

### Added
- `zid.UnixMillis`, what every clock's `now` returns: a struct with a
  `millis` field and `fromNanoseconds`, so the unit is written where a
  reading is made.
- `Config.name`: what `{f}` calls the id (`UserId(…)[t=…]`), so log
  lines say which id type they show. Display only; defaults to
  `OrderedId`.
- `zid.atomic_generator_supported`: whether the target has the 64-bit
  atomics `AtomicGenerator` needs, for code that builds for both 32- and
  64-bit targets.
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
- **Breaking:** a clock's `now` returns `zid.UnixMillis` instead of a
  bare `u64`. Custom clocks change `return ms;` to
  `return .{ .millis = ms };`. The built-in clocks share one
  nanoseconds-to-milliseconds conversion.
- Docs: zid uses Crockford's Base32 alphabet but not his lenient
  decoding (lowercase, `I`/`L` as `1`, `O` as `0`), so every id has
  exactly one string. Said plainly in the code and README now.
- The README's reserve-ahead test waits 20 ms instead of up to a second.
- **Breaking:** `Config.epoch` is required. It used to default to
  `.unix`, which with the common 41-bit timestamp runs out in 2039; a
  recent epoch such as 2025-01-01 lasts until 2094. Add
  `.epoch = .unix` to keep the old behaviour. The README and examples
  now use a 2025-01-01 epoch.
- On a 32-bit target, `AtomicGenerator` is one clear compile error
  ("needs 64-bit atomics ... use Generator there") instead of several
  from inside `std.atomic`, and the rest of the test suite builds and
  runs there. `zig build check-generator` is gone; `zig build check`
  covers 32-bit targets.
- The Base32 alphabet's compile-time check names the problem (wrong
  length, or which pair is out of order) instead of failing an assert.
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
