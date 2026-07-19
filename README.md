# zid — Zero-Cost Ordered Identity in Zig

A small, zero-cost, compile-time verified ordered identity primitive.

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
