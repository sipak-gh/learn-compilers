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

    // 1. Unit tests: the `test` blocks in src/, including the fuzz tests
    //    in src/fuzz.zig. `zig build test --fuzz=100K` fuzzes for 100,000
    //    runs; Zig's fuzzer needs the LLVM backend.
    const unit_tests = b.addTest(.{ .root_module = pebc.root_module, .use_llvm = true });
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
    // `zig build test -Dupdate` rewrites the golden files with the actual
    // output; `-Dfilter=TEXT` runs only the tests whose path contains TEXT.
    if (b.option(bool, "update", "Rewrite the golden files with the actual output") orelse false)
        run_golden.addArg("--update");
    if (b.option([]const u8, "filter", "Run only the golden tests whose path contains this")) |filter|
        run_golden.addArgs(&.{ "--filter", filter });
    // `-Dno-fold` runs the golden tests and difftest with `pebc --no-fold`.
    const no_fold = b.option(bool, "no-fold", "Test pebc --no-fold") orelse false;
    if (no_fold) run_golden.addArg("--no-fold");
    test_step.dependOn(&run_golden.step);

    // `zig build difftest` generates random programs in Pebble and in C,
    // compiles them with pebc and cc, and checks that they print the same.
    // `-Dseed=N -Dcount=N` picks which programs; `-Dkeep` keeps them all.
    const difftest = b.addExecutable(.{
        .name = "difftest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/difftest.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_difftest = b.addRunArtifact(difftest);
    run_difftest.addArtifactArg(pebc);
    _ = run_difftest.addOutputDirectoryArg("difftest");
    const seed = b.option(u64, "seed", "First seed for `zig build difftest`") orelse 1;
    const count = b.option(u64, "count", "How many programs `zig build difftest` tries") orelse 100;
    run_difftest.addArgs(&.{ "--seed", b.fmt("{d}", .{seed}), "--count", b.fmt("{d}", .{count}) });
    if (b.option(bool, "keep", "Keep every program `zig build difftest` generates") orelse false)
        run_difftest.addArg("--keep");
    if (no_fold) run_difftest.addArg("--no-fold");
    run_difftest.has_side_effects = true;
    const difftest_step = b.step("difftest", "Compare pebc with cc on random programs");
    difftest_step.dependOn(&run_difftest.step);

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
