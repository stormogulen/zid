# zid — Zero-Cost Ordered Identity in Zig

A small, zero-cost, compile-time verified ordered identity primitive.

[![CI](https://github.com/stormogulen/zid/actions/workflows/main.yml/badge.svg)](https://github.com/stormogulen/zid/actions/workflows/main.yml)

[![Zig](https://img.shields.io/badge/zig-0.16.0-orange)](https://ziglang.org/)


## Features

- **Type-level configuration** — Bit layout defined at type creation
- **Compile-time verified** — Invalid configs fail at compile time
- **Zero runtime cost** — All bit packing/unpacking is inlined
- **Explicit errors** — Clock drift, sequence exhaustion surfaced to caller
- **Testable** — Swappable clock implementations for deterministic tests

## Design Constraints

- **Single-threaded** — `Generator` is not safe to share across threads;
  no locking is used, which is part of how it stays zero-cost.
- **Node id assignment is out of scope** — node ids are typed to the
  configured width (`UserId.Node` is a `u10` for 10 node bits), so an
  out-of-range node can't be passed in. Converting a runtime integer is
  the caller's boundary: `std.math.cast(UserId.Node, value)`. Assigning
  unique ids across a fleet is left to the caller.

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
zig build test              # unit, property and fuzz-corpus tests
zig build run                # basic Generator + decode walkthrough
zig build run-type-safety    # compile-time type distinctness, eql correctness
zig build run-testing        # deterministic testing with ManualClock
zig build run-benchmark -Doptimize=ReleaseFast  # generator cost vs real-clock throughput
```

## Quick Start
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

Monotonicity only holds within one generator. To keep it across
restarts, store the last issued id and resume from it:

```zig
var gen = try zid.Generator(UserId, zid.MonotonicClock).initAfter(.{
    .clock = &clock,
    .node = 1,
}, last_issued_id); // error.NodeMismatch if it came from another node
```

Every new id is greater than `last_issued_id`. If the clock is behind
it, `next()` reports `error.ClockMovedBackwards` rather than issuing a
duplicate.

### Ordering and range queries

Ids order by timestamp, then node, then sequence:

```zig
std.mem.sort(UserId, ids, {}, UserId.lessThan);
if (a.order(b) == .lt) { ... }
```

`minAt` and `maxAt` give the smallest and largest id any node can
produce in a millisecond, which turns a time range into an id range:

```zig
const from = UserId.minAt(try gen.timestampFromUnixMillis(start_ms));
const to = UserId.maxAt(try gen.timestampFromUnixMillis(end_ms));
// WHERE id BETWEEN from.raw() AND to.raw()
```

### Boundaries

Ids coming from outside (a database column, a URL) go through a
checked boundary, which rejects anything this layout couldn't have
produced:

```zig
const from_db = try UserId.fromRaw(raw_value); // error.ReservedBitsSet
const from_url = try UserId.parse(text); // DecodeError or error.ReservedBitsSet
```

Each fallible call returns only the errors it can actually produce
(`zid.NextError`, `zid.TimestampError`, `zid.ResumeError`,
`zid.RawError`, `zid.ParseError`, `zid.OverflowError`), so callers
can `switch` over them exhaustively.
