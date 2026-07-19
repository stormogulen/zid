# zid — Zero-Cost Ordered Identity in Zig

A small, zero-cost, compile-time verified ordered identity primitive.

## Features

- **Type-level configuration** — Bit layout defined at type creation
- **Compile-time verified** — Invalid configs fail at compile time
- **Zero runtime cost** — All bit packing/unpacking is inlined
- **Explicit errors** — Clock drift, sequence exhaustion surfaced to caller
- **Testable** — Swappable clock implementations for deterministic tests

## Quick Start
const UserId = zid.OrderedId(.{ .timestamp_bits = 41, .node_bits = 10, .sequence_bits = 12, });

const clock = zid.SystemClock.init(io); 
const gen = try zid.Generator(UserId, zid.SystemClock).init(.{ .clock = &clock, .node = 1, });

const id = try gen.next();

