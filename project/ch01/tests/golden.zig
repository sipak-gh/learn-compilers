//! The golden test runner: `golden PEBC TESTS_DIR OUT_DIR`.
//!
//! For every run/NAME.peb in TESTS_DIR it compiles the program with
//! `pebc build` into OUT_DIR, runs it, and compares what it prints with
//! run/NAME.out, the "golden" expected output.
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

    var runner: Runner = .{
        .arena = arena,
        .io = io,
        .pebc = args[1],
        .tests_path = args[2],
        .out_path = args[3],
        .out = out,
    };
    try runner.runAll("run");

    try out.print("golden: {d} passed, {d} failed\n", .{ runner.passed, runner.failed });
    try out.flush();
    return if (runner.failed == 0) 0 else 1;
}

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
    fn runAll(r: *Runner, suite: []const u8) !void {
        const dir_path = try std.fs.path.join(r.arena, &.{ r.tests_path, suite });
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
            const ok = try r.runOne(suite, name);
            try r.out.print("{s} {s}/{s}\n", .{ if (ok) "PASS" else "FAIL", suite, name });
            if (ok) r.passed += 1 else r.failed += 1;
        }
    }

    /// Compiles and runs one program; returns whether its output matched.
    fn runOne(r: *Runner, suite: []const u8, name: []const u8) !bool {
        const stem = name[0 .. name.len - ".peb".len];
        const src_path = try std.fs.path.join(r.arena, &.{ r.tests_path, suite, name });
        const exe_path = try std.fs.path.join(r.arena, &.{ r.out_path, stem });

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
        const expected_path = try std.fmt.allocPrint(r.arena, "{s}/{s}/{s}.out", .{ r.tests_path, suite, stem });
        const expected = try Io.Dir.cwd().readFileAlloc(r.io, expected_path, r.arena, .limited(1 << 20));
        if (!std.mem.eql(u8, expected, program.stdout)) {
            try r.out.print("  expected stdout:\n{s}  actual stdout:\n{s}", .{ expected, program.stdout });
            return false;
        }
        return true;
    }

    fn exec(r: *Runner, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(r.arena, r.io, .{ .argv = argv });
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
