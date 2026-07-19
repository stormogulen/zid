const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // Library module
    //
    const zid_module = b.addModule("zid", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });


    //
    // Example program
    //
    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/basic/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    example_module.addImport(
        "zid",
        zid_module,
    );

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


    const example = b.addExecutable(.{
        .name = "zid-example",
        .root_module = example_module,
    });


    const run_example = b.addRunArtifact(example);


    const run_step = b.step(
        "run",
        "Run zid example",
    );

    run_step.dependOn(
        &run_example.step,
    );
}
