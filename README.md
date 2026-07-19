# zid — Zero-Cost Ordered Identity in Zig

A small, zero-cost, compile-time verified ordered identity primitive.
[![CI](https://github.com/stormogulen/zid/actions/workflows/ci.yml/badge.svg)](https://github.com/stormogulen/zid/actions/workflows/main.yml)

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
- **Node id assignment is out of scope** — the library validates that a
  node id fits the configured bits, but assigning unique ids across a
  fleet is left to the caller.

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
zig build test              # run the unit test suite
zig build run                # basic Generator + decode walkthrough
zig build run-type-safety    # compile-time type distinctness, eql correctness
zig build run-testing        # deterministic testing with ManualClock
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
    var clock = zid.SystemClock.init(init.io);

    var gen = try zid.Generator(UserId, zid.SystemClock).init(.{
        .clock = &clock,
        .node = 1,
    });

    const id = try gen.next();
}
```
