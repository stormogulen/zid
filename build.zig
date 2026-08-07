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

    const ExampleDef = struct { name: []const u8, path: []const u8, step_name: []const u8, desc: []const u8 };
    const examples = [_]ExampleDef{
        .{ .name = "zid-example", .path = "examples/basic/main.zig", .step_name = "run", .desc = "Run zid example" },
        .{ .name = "zid-type-safety", .path = "examples/type_safety/main.zig", .step_name = "run-type-safety", .desc = "Run zid type-safety example" },
        .{ .name = "zid-testing", .path = "examples/testing/main.zig", .step_name = "run-testing", .desc = "Run zid testing example" },
        .{ .name = "zid-threaded", .path = "examples/threaded/main.zig", .step_name = "run-threaded", .desc = "Run zid multithreaded example" },
        .{ .name = "zid-ordering", .path = "examples/ordering/main.zig", .step_name = "run-ordering", .desc = "Id has stable ordering semantics" },
    };
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
        const run_cmd = b.addRunArtifact(exe);

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step(ex.step_name, ex.desc);
        run_step.dependOn(&run_cmd.step);
    }
}
