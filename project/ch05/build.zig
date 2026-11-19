const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The compiler itself: zig-out/bin/pebc.
    const pebc = b.addExecutable(.{
        .name = "pebc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(pebc);

    // `zig build run -- ARGS` runs pebc with ARGS.
    const run_cmd = b.addRunArtifact(pebc);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run pebc");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs two kinds of tests.
    const test_step = b.step("test", "Run unit tests and golden tests");

    // 1. Unit tests: the `test` blocks in src/.
    const unit_tests = b.addTest(.{ .root_module = pebc.root_module });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // 2. Golden tests: tests/golden.zig compiles every program in tests/
    //    with pebc, runs it, and compares its output with the expected one.
    const golden = b.addExecutable(.{
        .name = "golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_golden = b.addRunArtifact(golden);
    run_golden.addArtifactArg(pebc);
    run_golden.addDirectoryArg(b.path("tests"));
    // A scratch directory inside .zig-cache for the compiled test programs.
    _ = run_golden.addOutputDirectoryArg("golden");
    // The results depend on qbe and cc, which the build system can't see,
    // so never skip this step because "nothing changed".
    run_golden.has_side_effects = true;
    test_step.dependOn(&run_golden.step);

    // `zig build demo` compiles a sample program and runs it:
    // `zig build demo -Dsample=samples/other.peb` picks another one.
    const sample = b.option([]const u8, "sample", "Program for `zig build demo`") orelse
        "samples/answer.peb";
    const compile_sample = b.addRunArtifact(pebc);
    compile_sample.addArg("build");
    compile_sample.addFileArg(b.path(sample));
    compile_sample.addArg("-o");
    const sample_exe = compile_sample.addOutputFileArg(std.fs.path.stem(sample));
    const run_sample = std.Build.Step.Run.create(b, "run sample");
    run_sample.addFileArg(sample_exe);
    const demo_step = b.step("demo", "Compile and run a sample program");
    demo_step.dependOn(&run_sample.step);
}
