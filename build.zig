const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zid_module = b.addModule("zid", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Test
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // Compiles the unit tests without running them, so CI can check that
    // the library builds for targets it can't execute. Works on 32-bit
    // targets too: AtomicGenerator's tests are left out there.
    const check_step = b.step("check", "Compile the unit tests without running them");
    check_step.dependOn(&tests.step);

    // Every Zig block in README.md, compiled, run, and compared with the
    // README text (see readme_test.zig).
    const readme_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("readme_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zid", .module = zid_module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(readme_tests).step);

    // Format
    const fmt_step = b.step("fmt", "Format Zig source files");
    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "readme_test.zig", "src", "examples" } });
    fmt_step.dependOn(&fmt.step);

    const ExampleDef = struct { name: []const u8, path: []const u8, step_name: []const u8, desc: []const u8 };
    const examples = [_]ExampleDef{
        .{ .name = "zid-example", .path = "examples/basic/main.zig", .step_name = "run", .desc = "Run zid example" },
        .{ .name = "zid-type-safety", .path = "examples/type_safety/main.zig", .step_name = "run-type-safety", .desc = "Run zid type-safety example" },
        .{ .name = "zid-testing", .path = "examples/testing/main.zig", .step_name = "run-testing", .desc = "Run zid testing example" },
        .{ .name = "zid-threaded", .path = "examples/threaded/main.zig", .step_name = "run-threaded", .desc = "Run zid multithreaded example" },
        .{ .name = "zid-shared-generator", .path = "examples/shared_generator/main.zig", .step_name = "run-shared-generator", .desc = "Several threads sharing one AtomicGenerator" },
        .{ .name = "zid-ordering", .path = "examples/ordering/main.zig", .step_name = "run-ordering", .desc = "Id has stable ordering semantics" },
        .{ .name = "zid-live-clock", .path = "examples/live_clock/main.zig", .step_name = "run-live-clock", .desc = "Generator + SystemClock under a real io runtime" },
        .{ .name = "zid-benchmark", .path = "examples/benchmark/main.zig", .step_name = "run-benchmark", .desc = "Benchmark generator cost and real-clock throughput" },
    };
    // Compiles every example without running it, so one that isn't run in
    // CI (the benchmark) still can't stop building unnoticed.
    const examples_step = b.step("examples", "Build every example");

    inline for (examples) |ex| {
        const mod = b.createModule(.{
            .root_source_file = b.path(ex.path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("zid", zid_module);
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = mod,
        });

        examples_step.dependOn(&exe.step);

        const run_cmd = b.addRunArtifact(exe);

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step(ex.step_name, ex.desc);
        run_step.dependOn(&run_cmd.step);
    }
}
