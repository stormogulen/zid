# zid — Zero-Cost Ordered Identity in Zig

A small, zero-cost, compile-time verified ordered identity primitive.

[![CI](https://github.com/stormogulen/zid/actions/workflows/main.yml/badge.svg)](https://github.com/stormogulen/zid/actions/workflows/main.yml)

[![Zig](https://img.shields.io/badge/zig-0.16.0-orange)](https://ziglang.org/)


## Install

```sh
zig fetch --save git+https://github.com/stormogulen/zid
```

<!-- zig-snippet: unchecked -->
```zig
// build.zig
const zid = b.dependency("zid", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zid", zid.module("zid"));
```

Requires Zig 0.16.0 or newer.

## Features

- **Type-level configuration** — Bit layout defined at type creation
- **Compile-time verified** — Invalid configs fail at compile time
- **Zero runtime cost** — All bit packing/unpacking is inlined
- **Explicit errors** — Clock drift, sequence exhaustion surfaced to caller
- **Testable** — Swappable clock implementations for deterministic tests

## Design Constraints

- **`Generator` is single-threaded** — it is not safe to share across
  threads; no locking is used, which is part of how it stays zero-cost.
  Give each thread its own `Generator` and node id (see
  `examples/threaded`), or share one node with `AtomicGenerator` (see
  [Sharing a generator across threads](#sharing-a-generator-across-threads)).
- **Monotonicity is always checked** — the generator's "ids strictly
  increase" guarantee is a real check (`@panic`), not a `std.debug.assert`,
  so it holds in every build mode, ReleaseFast included. The other
  assertions guard zid's own bit math and follow the usual build-mode
  rules.
- **Node id assignment is out of scope** — node ids are typed to the
  configured width (`UserId.Node` is a `u10` for 10 node bits), so an
  out-of-range node can't be passed in. Converting a runtime integer is
  the caller's boundary: `std.math.cast(UserId.Node, value)`. Assigning
  unique ids across a fleet is left to the caller. Two live generators
  with the same node id will issue duplicate ids, and zid cannot detect
  it.

## Extending zid

OrderedId is the reference implementation, not the only one. Anything
that follows the same shape counts as part of the zid ecosystem:

- **Strongly typed** — each config is its own type, not a raw u64.
- **Comptime config** — bad configs fail to compile, not to run.
- **Explicit errors** — failures come back as real Zig errors, never
  a magic value or a panic.
- **Swappable dependencies** — anything that isn't deterministic (a
  clock, randomness, a C library) gets passed in, so it can be swapped
  for a fake in tests.

`src/ordered/` is the reference to copy from.

A couple of things worth knowing if you're adding a new identifier type:

- **UUIDs or hash-based ids** don't sort the way `OrderedId` does —
  that's fine, just say so in the doc comment.
- **Wrapping a C library** is a different deal than pure Zig bit
  math — the FFI calls aren't free, C error codes should become real
  Zig errors, and it should be clear who owns any memory. Still
  welcome, just don't call it zero-cost.

## Examples & Tests

```sh
zig build test              # unit, property and fuzz-corpus tests, plus every README example
zig build examples           # compile every example without running it
zig build run                # basic Generator + decode walkthrough
zig build run-type-safety    # compile-time type distinctness, eql correctness
zig build run-testing        # deterministic testing with ManualClock
zig build run-threaded       # one Generator and node id per thread
zig build run-shared-generator  # several threads sharing one AtomicGenerator
zig build run-benchmark -Doptimize=ReleaseFast  # generator cost vs real-clock throughput
```

The Zig examples in this README are compiled and run by `readme_test.zig`,
which also fails if a README block and its compiled version drift apart.

## Quick Start
<!-- zig-snippet: quick-start -->
```zig
const UserId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
});

pub fn main(init: std.process.Init) !void {
    var clock = zid.MonotonicClock.init(init.io);

    var gen = zid.Generator(UserId, zid.MonotonicClock).init(.{
        .clock = &clock,
        .node = 1,
    });

    const id = try gen.next();
    _ = id;
}
```

### Clocks

- `MonotonicClock` (recommended): reads the wall clock once at init,
  then adds monotonic time. An NTP step or a manual change of the
  system time can't make ids go backwards within the process.
- `SystemClock`: reads the wall clock on every call, so it follows
  every change to the system time. If it steps backwards, `next()`
  returns `error.ClockMovedBackwards` until real time catches up.
- `ManualClock`: set by hand, for deterministic tests.

### Resuming after a restart

Monotonicity and uniqueness only hold within one generator. A freshly
started process makes no promise about ids the previous run issued, and
`init` after a restart can repeat them:

- Two runs can issue ids in the same millisecond.
- A new `MonotonicClock` re-anchors to the wall clock. If the old
  process's clock had drifted ahead of the wall clock (it runs on
  monotonic time and the two clocks tick at slightly different rates,
  so the gap grows with uptime), the new one can start *behind* ids the
  old one already issued.
- With `SystemClock`, the system time may simply have been set back.

With the same node id, any of these can produce an id that already
exists. To rule it out, store the last issued id and resume from it:

<!-- zig-snippet: resume-save -->
```zig
// While running, or on shutdown: keep the last id.
if (gen.lastIssued()) |last| try store.save(&last.toString());
```

On start, parse it back and resume after it:

<!-- zig-snippet: resume-start -->
```zig
const last = try UserId.parse(try store.load());
var gen = try zid.Generator(UserId, zid.MonotonicClock).initAfter(.{
    .clock = &clock,
    .node = 1,
}, last); // error.NodeMismatch if it came from another node
```

Every new id is greater than `last`. If the clock is behind it, `next()`
reports `error.ClockMovedBackwards` rather than issuing a duplicate, so
the caller can wait or fail loudly. `AtomicGenerator` has the same
`lastIssued` and `initAfter`.

`initAfter` alone is not crash-safe: a process that crashes can only
resume from the last id it managed to save, and ids issued after that
save can be issued again. For a strict guarantee, either give each run
its own node id or reserve time ahead: save a timestamp a little in the
future *before* handing out any id up to it, and resume after it with
`initAfterTimestamp`:

<!-- zig-snippet: reserve-start -->
```zig
const block_ms = 1_000;

// On start: skip everything up to the previous run's reservation.
const reserved = try store.loadTimestamp();
var gen = zid.Generator(UserId, zid.MonotonicClock).initAfterTimestamp(.{
    .clock = &clock,
    .node = 1,
}, reserved);
var reserved_until = reserved;

// The clock is normally a little behind the reservation after a restart:
// wait that out. Further behind than a block means the clock was set
// back, so fail loudly instead of spinning.
const reserved_unix = UserId.unixMillisFromTimestamp(reserved);
if (reserved_unix -| clock.now() > block_ms) return error.ClockMovedBackwards;
const spin: zid.SpinWait = .{};
while (clock.now() <= reserved_unix) spin.wait();
```

Then, for every id:

<!-- zig-snippet: reserve-each -->
```zig
const id = try gen.nextRetrying(zid.SpinWait{});
if (id.timestamp() > reserved_until) {
    reserved_until = id.timestamp() +| block_ms;
    try store.saveTimestamp(reserved_until); // Saved before the id leaves.
}
```

Until the clock passes `reserved`, `next()` reports
`error.ClockMovedBackwards` (or `error.SequenceExhausted` at that exact
millisecond). `nextRetrying` only waits out the second, which is why the
snippet waits for the clock first. The trade-off: a restart can wait up
to `block_ms`, and the store is written about once per block instead of
once per id. `AtomicGenerator` has
`initAfterTimestamp` too.

The same clock differences make ids from *different* nodes only roughly
chronological: each node's clock is anchored separately, so ids from two
nodes can sort a few milliseconds off their true creation order. Within
one node the order is exact.

### Bit layout

`OrderedId` packs three fields into one `u64`, most significant first.
With the 41/10/12 layout from the Quick Start:

```
 63  62                      22 21        12 11            0
+---+--------------------------+------------+---------------+
| 0 |   timestamp (41 bits)    | node (10)  | sequence (12) |
+---+--------------------------+------------+---------------+
```

- **timestamp** counts milliseconds since the id type's epoch.
- **node** says which generator issued the id.
- **sequence** counts ids issued in the same millisecond (4096 per
  millisecond per node here).

Ids compare as plain integers, so sorting by `raw()` sorts by time,
then node, then sequence. Any bits above the three fields are always
zero.

### Lifetime

A layout with `timestamp_bits` bits runs out after `2^timestamp_bits`
milliseconds from its epoch (41 bits is about 69.7 years). After that,
`next()` returns `error.TimestampOverflow`. `max_unix_millis` says
exactly when:

<!-- zig-snippet: lifetime -->
```zig
const expires_at_ms = UserId.max_unix_millis; // last representable Unix ms
```

With the default Unix epoch and 41 bits that is 2039-09-07, so pick a
recent `.epoch` for new systems.

### Waiting out sequence exhaustion

When all sequence values for the current millisecond are used,
`next()` returns `error.SequenceExhausted` and leaves the choice to the
caller. `nextRetrying` is the common choice: it calls your waiter and
tries again until the clock moves on.

<!-- zig-snippet: retrying -->
```zig
const id = try gen.nextRetrying(zid.SpinWait{});
```

A waiter is anything with a `wait(self)` method, so a program with an
event loop can sleep instead of spinning. Every error other than
`SequenceExhausted` is returned as is.

Normally the wait is shorter than a millisecond, so `zid.SpinWait` is a
good fit. With a clock skew tolerance (see below) it can last as long as
the tolerance, and a sleeping waiter is the better choice.

### Tolerating small clock steps

With `SystemClock`, an NTP correction can move time back a few
milliseconds. By default that makes `next()` return
`error.ClockMovedBackwards`. To absorb steps up to a limit instead:

<!-- zig-snippet: skew -->
```zig
var gen = zid.Generator(UserId, zid.SystemClock).init(.{
    .clock = &clock,
    .node = 1,
    .clock_skew_tolerance_ms = 5,
});
```

Within the tolerance the generator keeps issuing ids at the last
timestamp, so ids stay strictly increasing but run slightly ahead of
the wall clock, and the sequence can run out sooner. A step larger than
the tolerance is still an error. If the sequence runs out while the
clock is still behind, `next()` returns `error.SequenceExhausted` until
the clock catches up, which can take up to the tolerance; `nextRetrying`
with `zid.SpinWait` busy-waits for that long. `MonotonicClock` never
steps back, so it doesn't need this.

### Sharing a generator across threads

`AtomicGenerator` has the same API as `Generator`, but `next()` can be
called from any thread on one shared generator:

<!-- zig-snippet: atomic -->
```zig
var gen = zid.AtomicGenerator(UserId, zid.MonotonicClock).init(.{
    .clock = &clock,
    .node = 1,
});
// from any thread:
const id = try gen.nextRetrying(zid.SpinWait{});
```

Its whole state is the last id, advanced with a compare-and-swap, so
there is no lock in the generator itself. Things to know:

- It needs a target where Zig allows 64-bit atomics. With Zig 0.16.0 it
  does not compile for `x86-linux` or `arm-linux-gnueabihf`, whatever
  CPU model was tried (baseline, `pentium`, `i686`, `pentium4`,
  `cortex_a7`), so use `Generator` on 32-bit targets (CI compiles it
  for `x86-linux`). CI compiles the tests for `aarch64-linux` and
  `riscv64-linux` (`zig build check
  -Dtarget=...`) but does not run them. Lock-freedom also assumes the
  clock's `now` doesn't block.
- Ids are ordered by allocation, meaning the order in which the
  compare-and-swap succeeded. That is not necessarily the order in which
  `next()` calls return across threads: a thread can win the swap, be
  descheduled, and return after another thread has returned a later id.
- It is slower than `Generator` even without contention, because of the
  atomic operation. Run `zig build run-benchmark -Doptimize=ReleaseFast`
  to measure it on your machine. If each thread can have its own node
  id, a `Generator` per thread is faster.
- The clock's `now` is called from several threads at once, so it must
  be safe for that. `MonotonicClock` and `SystemClock` are; `ManualClock`
  is not.
- It needs a layout with at least one unused bit (the layout must use
  fewer than 64 bits). A full 64-bit layout is a compile error.

### Ordering and range queries

Ids order by timestamp, then node, then sequence:

<!-- zig-snippet: ordering -->
```zig
std.mem.sort(UserId, ids, {}, UserId.lessThan);
if (a.order(b) == .lt) {
    // a sorts first: an earlier millisecond, or the same one and a
    // lower node, or the same node and a lower sequence.
}
```

`minAt` and `maxAt` give the smallest and largest id any node can
produce in a millisecond, which turns a time range into an id range:

<!-- zig-snippet: range -->
```zig
const from = UserId.minAt(try UserId.timestampFromUnixMillis(start_ms));
const to = UserId.maxAt(try UserId.timestampFromUnixMillis(end_ms));
// WHERE id BETWEEN from.raw() AND to.raw()
```

No generator is needed for this: the conversions live on the id type.

### Building ids from integers

`fromParts` takes typed fields, so an out-of-range literal is a compile
error. For values that arrive at runtime, `fromInts` checks each one:

<!-- zig-snippet: from-ints -->
```zig
const id = try UserId.fromInts(timestamp, node, sequence); // zid.FieldError
```

### Epochs

The epoch is part of the id type, set in its config. A recent epoch
makes the timestamp bits last longer (41 bits last about 69 years):

<!-- zig-snippet: epoch -->
```zig
const UserId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
    .epoch = .fromUnixMillis(1_735_689_600_000), // 2025-01-01T00:00:00Z
});

const created_at = id.unixMillis();
```

Ids with different epochs are different types, so they can't be mixed
by accident. An epoch so late that the largest timestamp would overflow
u64 Unix milliseconds is a compile error.

### Printing ids

`toString()` returns the 13-character encoded id as a `[13]u8`. To print
it without an intermediate buffer, use `fmtString()` with `{f}`, or
`writeString` on any `std.Io.Writer`:

<!-- zig-snippet: printing -->
```zig
std.log.info("created {f}", .{id.fmtString()}); // created 0DKQ1Z3T5W7A9
try id.writeString(writer);
```

Plain `{f}` on the id itself prints the debug form with the decoded
fields, `OrderedId(<raw>)[t=..,n=..,s=..]`, which is better for logs you
read than for strings you parse.

Decoding is strict on purpose: `parse` accepts only the 32 uppercase
alphabet characters, exactly 13 of them. Lowercase letters and
look-alikes such as `O` or `l` are rejected rather than guessed at, so
every id has exactly one valid spelling.

### Boundaries

Ids coming from outside (a database column, a URL) go through a
checked boundary, which rejects anything this layout couldn't have
produced:

<!-- zig-snippet: boundaries -->
```zig
const from_db = try UserId.fromRaw(raw_value); // error.ReservedBitsSet
const from_url = try UserId.parse(text); // zid.DecodeError or error.ReservedBitsSet
```

Each fallible call returns only the errors it can actually produce
(`zid.NextError`, `zid.TimestampError`, `zid.ResumeError`,
`zid.RawError`, `zid.ParseError`, `zid.FieldError`), so callers can
`switch` over them exhaustively.

### Making sure a config is checked

Zig only analyses declarations that something uses. A config that is
declared but never referenced -- or only referenced from a function nobody
calls yet -- is never checked, so an invalid one compiles silently until
the day it's first used. One line next to the declaration forces the
check:

<!-- zig-snippet: checked-config -->
```zig
const UserId = zid.OrderedId(.{
    .timestamp_bits = 41,
    .node_bits = 10,
    .sequence_bits = 12,
    .tag = struct {},
});
// An invalid config is a compile error from day one:
comptime {
    _ = UserId;
}
```

## License

MIT, see [LICENSE](LICENSE). Changes are listed in [CHANGELOG.md](CHANGELOG.md).
