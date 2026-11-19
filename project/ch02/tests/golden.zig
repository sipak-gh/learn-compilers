//! The golden test runner: `golden PEBC TESTS_DIR OUT_DIR`.
//!
//! - run/NAME.peb: compile it with `pebc build` into OUT_DIR, run it, and
//!   compare what it prints with run/NAME.out, the "golden" output.
//! - errors/NAME.peb: compile it with `pebc ir`, which must fail, and
//!   compare the error messages with errors/NAME.err.
//!
//! pebc runs inside TESTS_DIR, so error messages show paths such as
//! "errors/NAME.peb" no matter where the tests are.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: golden PEBC TESTS_DIR OUT_DIR\n", .{});
        return 2;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    // pebc runs in another directory, so the paths must be absolute.
    const cwd = try std.process.currentPathAlloc(io, arena);
    var runner: Runner = .{
        .arena = arena,
        .io = io,
        .pebc = try std.fs.path.resolve(arena, &.{ cwd, args[1] }),
        .tests_path = try std.fs.path.resolve(arena, &.{ cwd, args[2] }),
        .out_path = try std.fs.path.resolve(arena, &.{ cwd, args[3] }),
        .out = out,
    };
    try runner.runAll(.run);
    try runner.runAll(.errors);

    try out.print("golden: {d} passed, {d} failed\n", .{ runner.passed, runner.failed });
    try out.flush();
    return if (runner.failed == 0) 0 else 1;
}

const Suite = enum { run, errors };

const Runner = struct {
    arena: std.mem.Allocator,
    io: Io,
    pebc: []const u8,
    tests_path: []const u8,
    out_path: []const u8,
    out: *Io.Writer,
    passed: usize = 0,
    failed: usize = 0,

    /// Runs every NAME.peb in the subdirectory `suite`, in name order.
    fn runAll(r: *Runner, suite: Suite) !void {
        const dir_path = try std.fs.path.join(r.arena, &.{ r.tests_path, @tagName(suite) });
        var dir = try Io.Dir.cwd().openDir(r.io, dir_path, .{ .iterate = true });
        defer dir.close(r.io);

        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(r.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".peb"))
                try names.append(r.arena, try r.arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);

        for (names.items) |name| {
            const ok = switch (suite) {
                .run => try r.runProgram(name),
                .errors => try r.checkErrors(name),
            };
            try r.out.print("{s} {t}/{s}\n", .{ if (ok) "PASS" else "FAIL", suite, name });
            if (ok) r.passed += 1 else r.failed += 1;
        }
    }

    /// Compiles and runs run/NAME; returns whether its output matched.
    fn runProgram(r: *Runner, name: []const u8) !bool {
        const stem = name[0 .. name.len - ".peb".len];
        const exe_path = try std.fs.path.join(r.arena, &.{ r.out_path, stem });
        const src_path = try std.fs.path.join(r.arena, &.{ "run", name });

        const compile = try r.exec(&.{ r.pebc, "build", src_path, "-o", exe_path });
        if (!compile.term.success()) {
            try r.out.print("  pebc failed:\n{s}", .{compile.stderr});
            return false;
        }
        const program = try r.exec(&.{exe_path});
        if (!program.term.success()) {
            try r.out.print("  the program failed: {any}\n", .{program.term});
            return false;
        }
        return r.expectEqual("stdout", try r.expected("run", stem, ".out"), program.stdout);
    }

    /// Compiles errors/NAME, which must fail with the expected messages.
    fn checkErrors(r: *Runner, name: []const u8) !bool {
        const stem = name[0 .. name.len - ".peb".len];
        const src_path = try std.fs.path.join(r.arena, &.{ "errors", name });
        const compile = try r.exec(&.{ r.pebc, "ir", src_path });
        if (compile.term != .exited or compile.term.exited != 1) {
            try r.out.print("  expected pebc to exit with status 1, got {any}\n", .{compile.term});
            return false;
        }
        return r.expectEqual("errors", try r.expected("errors", stem, ".err"), compile.stderr);
    }

    /// Reads the golden file SUITE/STEM.EXT.
    fn expected(r: *Runner, suite: []const u8, stem: []const u8, ext: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(r.arena, "{s}/{s}/{s}{s}", .{ r.tests_path, suite, stem, ext });
        return Io.Dir.cwd().readFileAlloc(r.io, path, r.arena, .limited(1 << 20));
    }

    fn expectEqual(r: *Runner, what: []const u8, expected_text: []const u8, actual: []const u8) !bool {
        if (std.mem.eql(u8, expected_text, actual)) return true;
        try r.out.print("  expected {s}:\n{s}  actual {s}:\n{s}", .{ what, expected_text, what, actual });
        return false;
    }

    /// Runs a program inside the tests directory and collects its output.
    fn exec(r: *Runner, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(r.arena, r.io, .{ .argv = argv, .cwd = .{ .path = r.tests_path } });
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
