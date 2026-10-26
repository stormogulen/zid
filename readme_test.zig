//! Every Zig code block in README.md, compiled and run.
//!
//! README.md puts `<!-- zig-snippet: NAME -->` before each Zig block.
//! This file holds the same code between a `// snippet: NAME` line and a
//! `// end snippet` line, inside just enough context to compile and run
//! it. The last test compares the two, so an example in the README can't
//! drift away from code that builds. The name `unchecked` marks a block
//! that can't be compiled here (the build.zig fragment).
//!
//! To change an example: edit it here, then copy the region (without its
//! indentation) into the README. The comparison test says which one is
//! out of date.

const std = @import("std");
const zid = @import("zid");

/// Examples that share one `UserId`. The examples that declare their own
/// `UserId` live in sibling structs, so the two never meet in one scope.
const shared = struct {
    const UserId = zid.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
        .epoch = .fromUnixMillis(1_735_689_600_000), // 2025-01-01T00:00:00Z
    });

    // ------------------------------------------------------- Resuming after a restart

    /// Stands in for wherever a program keeps state across restarts.
    const Store = struct {
        text: ?[UserId.encoded_len]u8 = null,
        timestamp: UserId.Timestamp = 0,

        fn save(self: *Store, text: *const [UserId.encoded_len]u8) !void {
            self.text = text.*;
        }

        fn load(self: *Store) ![]const u8 {
            if (self.text) |*text| return text;
            return error.NothingSaved;
        }

        fn saveTimestamp(self: *Store, timestamp: UserId.Timestamp) !void {
            self.timestamp = timestamp;
        }

        fn loadTimestamp(self: *const Store) !UserId.Timestamp {
            return self.timestamp;
        }
    };

    fn runBeforeRestart(clock: *zid.MonotonicClock, store: *Store) !UserId {
        var gen = zid.Generator(UserId, zid.MonotonicClock).init(.{ .clock = clock, .node = 1 });
        _ = try gen.next();
        _ = try gen.next();

        // snippet: resume-save
        // While running, or on shutdown: keep the last id.
        if (gen.lastIssued()) |last| try store.save(&last.toString());
        // end snippet

        return gen.lastIssued().?;
    }

    fn runAfterRestart(io: std.Io, store: *Store) !UserId {
        var clock = zid.MonotonicClock.init(io);

        // snippet: resume-start
        const last = try UserId.parse(try store.load());
        var gen = try zid.Generator(UserId, zid.MonotonicClock).initAfter(.{
            .clock = &clock,
            .node = 1,
        }, last); // error.NodeMismatch if it came from another node
        // end snippet

        return gen.next();
    }

    test "README: resuming after a restart continues after the saved id" {
        var store: Store = .{};
        var clock = zid.MonotonicClock.init(std.testing.io);

        const before = try runBeforeRestart(&clock, &store);
        const after = try runAfterRestart(std.testing.io, &store);
        try std.testing.expect(after.raw() > before.raw());
    }

    fn runReservingAhead(io: std.Io, store: *Store, ids: []UserId) !void {
        var clock = zid.MonotonicClock.init(io);

        // snippet: reserve-start
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
        if (reserved_unix -| clock.now().millis > block_ms) return error.ClockMovedBackwards;
        const spin: zid.SpinWait = .{};
        while (clock.now().millis <= reserved_unix) spin.wait();
        // end snippet

        for (ids) |*slot| {
            // snippet: reserve-each
            const id = try gen.nextRetrying(zid.SpinWait{});
            if (id.timestamp() > reserved_until) {
                reserved_until = id.timestamp() +| block_ms;
                try store.saveTimestamp(reserved_until); // Saved before the id leaves.
            }
            // end snippet

            // What the pattern promises: no id leaves past the saved reservation.
            try std.testing.expect(id.timestamp() <= store.timestamp);
            slot.* = id;
        }
    }

    test "README: reserving time ahead never repeats an id across a restart" {
        var store: Store = .{};

        var first: [20_000]UserId = @splat(.minAt(0));
        try runReservingAhead(std.testing.io, &store, &first);

        // Pretend the first run was near the end of its block, so its
        // reservation ends 20 ms from now rather than up to a second: the
        // second run then waits 20 ms, which keeps the test fast and still
        // exercises the wait. The first run's ids are all at or before now.
        var probe = zid.MonotonicClock.init(std.testing.io);
        store.timestamp = try UserId.timestampFromUnixMillis(probe.now().millis + 20);
        const reserved_by_first = store.timestamp;

        // A restart straight away: the second run waits out the reservation
        // and then issues only later ids.
        var second: [20_000]UserId = @splat(.minAt(0));
        try runReservingAhead(std.testing.io, &store, &second);
        try std.testing.expect(second[0].timestamp() > reserved_by_first);
        try std.testing.expect(second[0].raw() > first[first.len - 1].raw());

        // A reservation far ahead of the clock means the clock was set back.
        store.timestamp +|= 10_000;
        try std.testing.expectError(error.ClockMovedBackwards, runReservingAhead(std.testing.io, &store, &second));
    }

    // ------------------------------------------------------------------- Lifetime

    test "README: lifetime" {
        // snippet: lifetime
        const expires_at_ms = UserId.max_unix_millis; // last representable Unix ms
        // end snippet

        // 2^41 - 1 ms after the 2025-01-01 epoch: in 2094.
        try std.testing.expectEqual(1_735_689_600_000 + (1 << 41) - 1, expires_at_ms);
    }

    // ------------------------------------------------- Waiting out sequence exhaustion

    test "README: nextRetrying" {
        // 1 s after the epoch, so the timestamp is 1_000.
        var manual = zid.ManualClock{ .value = UserId.epoch.unix_millis + 1_000 };
        var gen = zid.Generator(UserId, zid.ManualClock).init(.{ .clock = &manual, .node = 1 });

        // snippet: retrying
        const id = try gen.nextRetrying(zid.SpinWait{});
        // end snippet

        try std.testing.expectEqual(1_000, id.timestamp());
    }

    // ------------------------------------------------- Tolerating small clock steps

    test "README: clock skew tolerance" {
        var clock = zid.SystemClock.init(std.testing.io);

        // snippet: skew
        var gen = zid.Generator(UserId, zid.SystemClock).init(.{
            .clock = &clock,
            .node = 1,
            .clock_skew_tolerance_ms = 5,
        });
        // end snippet

        _ = try gen.next();
    }

    // ------------------------------------------- Sharing a generator across threads

    test "README: AtomicGenerator" {
        // AtomicGenerator is a compile error on 32-bit targets by design.
        if (comptime !zid.atomic_generator_supported) return error.SkipZigTest;

        var clock = zid.MonotonicClock.init(std.testing.io);

        // snippet: atomic
        var gen = zid.AtomicGenerator(UserId, zid.MonotonicClock).init(.{
            .clock = &clock,
            .node = 1,
        });
        // from any thread:
        const id = try gen.nextRetrying(zid.SpinWait{});
        // end snippet

        try std.testing.expectEqual(1, id.node());
    }

    // ------------------------------------------------- Ordering and range queries

    test "README: ordering" {
        const a = UserId.fromParts(.{ .timestamp = 10, .node = 1, .sequence = 0 });
        const b = UserId.fromParts(.{ .timestamp = 11, .node = 0, .sequence = 0 });
        var storage = [_]UserId{ b, a };
        const ids: []UserId = &storage;

        // snippet: ordering
        std.mem.sort(UserId, ids, {}, UserId.lessThan);
        if (a.order(b) == .lt) {
            // a sorts first: an earlier millisecond, or the same one and a
            // lower node, or the same node and a lower sequence.
        }
        // end snippet

        try std.testing.expectEqualSlices(UserId, &.{ a, b }, ids);
    }

    test "README: range queries" {
        const start_ms: u64 = UserId.epoch.unix_millis + 1_000;
        const end_ms: u64 = UserId.epoch.unix_millis + 2_000;

        // snippet: range
        const from = UserId.minAt(try UserId.timestampFromUnixMillis(start_ms));
        const to = UserId.maxAt(try UserId.timestampFromUnixMillis(end_ms));
        // WHERE id BETWEEN from.raw() AND to.raw()
        // end snippet

        const inside = UserId.fromParts(.{ .timestamp = 1_500, .node = 3, .sequence = 7 });
        try std.testing.expect(from.raw() <= inside.raw() and inside.raw() <= to.raw());
    }

    // --------------------------------------------------- Building ids from integers

    test "README: fromInts" {
        const timestamp: u64 = 1_234;
        const node: u64 = 7;
        const sequence: u64 = 42;

        // snippet: from-ints
        const id = try UserId.fromInts(timestamp, node, sequence); // zid.FieldError
        // end snippet

        try std.testing.expectEqual(7, id.node());
    }

    // -------------------------------------------------------------- Printing ids

    test "README: printing ids" {
        const id = try UserId.parse("0DKQ1Z3T5W7A9");
        var buffer: [UserId.encoded_len]u8 = undefined;
        var fixed: std.Io.Writer = .fixed(&buffer);
        const writer = &fixed;

        // snippet: printing
        std.log.info("created {f}", .{id.fmtString()}); // created 0DKQ1Z3T5W7A9
        try id.writeString(writer);
        // end snippet

        try std.testing.expectEqualStrings("0DKQ1Z3T5W7A9", writer.buffered());
    }

    // ----------------------------------------------------------------- Boundaries

    test "README: boundaries" {
        const original = UserId.fromParts(.{ .timestamp = 9, .node = 8, .sequence = 7 });
        const raw_value: u64 = original.raw();
        const text: []const u8 = &original.toString();

        // snippet: boundaries
        const from_db = try UserId.fromRaw(raw_value); // error.ReservedBitsSet
        const from_url = try UserId.parse(text); // zid.DecodeError or error.ReservedBitsSet
        // end snippet

        try std.testing.expect(from_db.eql(original) and from_url.eql(original));
    }
};

// ---------------------------------------------------------------- Quick Start

const quick_start = struct {
    // snippet: quick-start
    const UserId = zid.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
        .epoch = .fromUnixMillis(1_735_689_600_000), // 2025-01-01T00:00:00Z
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
    // end snippet
};

test "README: quick start compiles" {
    // Building a std.process.Init needs a real process, so this one is
    // compiled but not run. Taking its address analyses the body.
    _ = &quick_start.main;
}

// --------------------------------------------------------------------- Epochs

const with_epoch = struct {
    const id = UserId.fromParts(.{ .timestamp = 500, .node = 1, .sequence = 0 });

    // snippet: epoch
    const UserId = zid.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
        .epoch = .fromUnixMillis(1_735_689_600_000), // 2025-01-01T00:00:00Z
    });

    const created_at = id.unixMillis();
    // end snippet

    test "README: epochs" {
        try std.testing.expectEqual(1_735_689_600_500, created_at);
    }
};

// --------------------------------------------- Making sure a config is checked

const checked_config = struct {
    // snippet: checked-config
    const UserId = zid.OrderedId(.{
        .timestamp_bits = 41,
        .node_bits = 10,
        .sequence_bits = 12,
        .tag = struct {},
        .epoch = .fromUnixMillis(1_735_689_600_000), // 2025-01-01T00:00:00Z
    });
    // An invalid config is a compile error from day one:
    comptime {
        _ = UserId;
    }
    // end snippet
};

test "README: checked config" {
    _ = checked_config;
}

test {
    _ = shared;
    _ = quick_start;
    _ = with_epoch;
    _ = checked_config;
}

// ------------------------------------------------- README and this file agree

const readme = @embedFile("README.md");
const this_file = @embedFile("readme_test.zig");

const readme_marker = "<!-- zig-snippet: ";
const region_start = "// snippet: ";
const region_end = "// end snippet";

/// Line without a trailing '\r', so a CRLF checkout compares equal.
fn stripCr(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

/// The region named `name` in this file, with the indentation of its
/// `// snippet:` line removed from every line. Null if there is none.
fn region(gpa: std.mem.Allocator, name: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, this_file, '\n');
    while (lines.next()) |raw_line| {
        const line = stripCr(raw_line);
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, trimmed, region_start)) continue;
        if (!std.mem.eql(u8, trimmed[region_start.len..], name)) continue;

        const indent = line.len - trimmed.len;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        while (lines.next()) |raw_body| {
            const body = stripCr(raw_body);
            if (std.mem.eql(u8, std.mem.trimStart(u8, body, " "), region_end)) {
                return try out.toOwnedSlice(gpa);
            }
            if (body.len > 0) {
                if (body.len < indent or !std.mem.allEqual(u8, body[0..indent], ' ')) {
                    return error.RegionLineLessIndentedThanItsMarker;
                }
                try out.appendSlice(gpa, body[indent..]);
            }
            try out.append(gpa, '\n');
        }
        return error.RegionWithoutEnd;
    }
    return null;
}

test "README: every Zig block matches its region in this file" {
    const gpa = std.testing.allocator;

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);

    var lines = std.mem.splitScalar(u8, readme, '\n');
    var pending_name: ?[]const u8 = null;
    var line_number: usize = 0;

    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = stripCr(raw_line);

        if (std.mem.startsWith(u8, line, readme_marker)) {
            const rest = line[readme_marker.len..];
            const end = std.mem.indexOf(u8, rest, " -->") orelse return error.MalformedMarker;
            pending_name = rest[0..end];
            continue;
        }
        if (!std.mem.eql(u8, line, "```zig")) continue;

        const name = pending_name orelse {
            std.debug.print("README.md:{d}: Zig block without a `{s}NAME -->` line before it\n", .{ line_number, readme_marker });
            return error.UnmarkedReadmeBlock;
        };
        pending_name = null;

        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(gpa);
        while (lines.next()) |raw_body| {
            line_number += 1;
            const body = stripCr(raw_body);
            if (std.mem.eql(u8, body, "```")) break;
            try block.appendSlice(gpa, body);
            try block.append(gpa, '\n');
        }

        if (std.mem.eql(u8, name, "unchecked")) continue;
        for (names.items) |seen| {
            if (std.mem.eql(u8, seen, name)) return error.DuplicateSnippetName;
        }
        try names.append(gpa, name);

        const expected = try region(gpa, name) orelse {
            std.debug.print("README.md:{d}: no `{s}{s}` region in readme_test.zig\n", .{ line_number, region_start, name });
            return error.MissingRegion;
        };
        defer gpa.free(expected);

        std.testing.expectEqualStrings(expected, block.items) catch |err| {
            std.debug.print("README.md block `{s}` differs from its region in readme_test.zig\n", .{name});
            return err;
        };
    }

    // The other direction: every region here is shown in the README.
    var file_lines = std.mem.splitScalar(u8, this_file, '\n');
    while (file_lines.next()) |raw_line| {
        const trimmed = std.mem.trimStart(u8, stripCr(raw_line), " ");
        if (!std.mem.startsWith(u8, trimmed, region_start)) continue;
        const name = trimmed[region_start.len..];
        for (names.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else {
            std.debug.print("readme_test.zig: region `{s}` isn't in README.md\n", .{name});
            return error.RegionNotInReadme;
        }
    }

    try std.testing.expect(names.items.len > 0);
}
