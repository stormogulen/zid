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

    //
        // Type-safety example
        //
        const type_safety_module = b.createModule(.{
            .root_source_file = b.path("examples/type_safety/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        type_safety_module.addImport(
            "zid",
            zid_module,
        );

        const type_safety_example = b.addExecutable(.{
            .name = "zid-type-safety",
            .root_module = type_safety_module,
        });

        const run_type_safety = b.addRunArtifact(type_safety_example);
        const run_type_safety_step = b.step(
            "run-type-safety",
            "Run zid type-safety example",
        );
        run_type_safety_step.dependOn(&run_type_safety.step);

        //
            // Testing example
            //
            const testing_module = b.createModule(.{
                .root_source_file = b.path("examples/testing/main.zig"),
                .target = target,
                .optimize = optimize,
            });
            testing_module.addImport(
                "zid",
                zid_module,
            );

            const testing_example = b.addExecutable(.{
                .name = "zid-testing",
                .root_module = testing_module,
            });

            const run_testing = b.addRunArtifact(testing_example);
            const run_testing_step = b.step(
                "run-testing",
                "Run zid testing example",
            );
            run_testing_step.dependOn(&run_testing.step);

    run_step.dependOn(
        &run_example.step,
    );
}
