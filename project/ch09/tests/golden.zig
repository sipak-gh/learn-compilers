//! The golden test runner: `golden PEBC TESTS_DIR OUT_DIR [--update] [--filter TEXT] [--no-fold]`.
//!
//! - run/NAME.peb: compile it with `pebc build` into OUT_DIR, run it, and
//!   compare what it prints with run/NAME.out, the "golden" output.
//! - errors/NAME.peb: compile it with `pebc ir`, which must fail, and
//!   compare the error messages with errors/NAME.err.
//! - ast/NAME.peb: compare the output of `pebc ast` with ast/NAME.ast.
//!
//! pebc runs inside TESTS_DIR, so error messages show paths such as
//! "errors/NAME.peb" no matter where the tests are.
//!
//! --update writes the actual output into the golden file instead of
//! comparing (`zig build test -Dupdate`); review the change with a diff
//! before you commit it. --filter runs only the tests whose path contains
//! TEXT (`zig build test -Dfilter=structs`). --no-fold passes --no-fold
//! to pebc (`zig build test -Dno-fold`): the tests must pass both ways.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.debug.print("usage: golden PEBC TESTS_DIR OUT_DIR [--update] [--filter TEXT] [--no-fold]\n", .{});
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
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--update")) {
            runner.update = true;
        } else if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
            i += 1;
            runner.filter = args[i];
        } else if (std.mem.eql(u8, args[i], "--no-fold")) {
            runner.fold = false;
        } else {
            std.debug.print("golden: unexpected argument '{s}'\n", .{args[i]});
            return 2;
        }
    }
    try runner.runAll(.run);
    try runner.runAll(.errors);
    try runner.runAll(.ast);

    try out.print("golden: {d} passed, {d} failed", .{ runner.passed, runner.failed });
    if (runner.update) try out.print(", {d} updated", .{runner.updated});
    try out.writeByte('\n');
    try out.flush();
    return if (runner.failed == 0) 0 else 1;
}

const Suite = enum { run, errors, ast };

const Runner = struct {
    arena: std.mem.Allocator,
    io: Io,
    pebc: []const u8,
    tests_path: []const u8,
    out_path: []const u8,
    out: *Io.Writer,
    update: bool = false,
    filter: ?[]const u8 = null,
    fold: bool = true,
    passed: usize = 0,
    failed: usize = 0,
    updated: usize = 0,

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
            const test_path = try std.fmt.allocPrint(r.arena, "{t}/{s}", .{ suite, name });
            if (r.filter) |f| if (std.mem.find(u8, test_path, f) == null) continue;
            const ok = switch (suite) {
                .run => try r.runProgram(name),
                .errors => try r.checkErrors(name),
                .ast => try r.checkTree(name),
            };
            try r.out.print("{s} {s}\n", .{ if (ok) "PASS" else "FAIL", test_path });
            if (ok) r.passed += 1 else r.failed += 1;
        }
    }

    /// Compiles and runs run/NAME; returns whether its output matched.
    fn runProgram(r: *Runner, name: []const u8) !bool {
        const stem = name[0 .. name.len - ".peb".len];
        const exe_path = try std.fs.path.join(r.arena, &.{ r.out_path, stem });
        const src_path = try std.fs.path.join(r.arena, &.{ "run", name });

        const compile = try r.exec(try r.pebcCommand(&.{ "build", src_path, "-o", exe_path }), .none);
        if (!compile.term.success()) {
            try r.out.print("  pebc failed:\n{s}", .{compile.stderr});
            return false;
        }
        // A program that loops forever must not hang the test suite.
        const program = r.exec(&.{exe_path}, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {
                try r.out.writeAll("  the program ran for more than 10 seconds\n");
                return false;
            },
            error.StreamTooLong => {
                try r.out.writeAll("  the program printed more than 1 MiB\n");
                return false;
            },
            else => |e| return e,
        };
        if (!program.term.success()) {
            try r.out.print("  the program failed: {any}\n", .{program.term});
            return false;
        }
        return r.compare("run", stem, ".out", program.stdout);
    }

    /// Compiles errors/NAME, which must fail with the expected messages.
    fn checkErrors(r: *Runner, name: []const u8) !bool {
        const stem = name[0 .. name.len - ".peb".len];
        const src_path = try std.fs.path.join(r.arena, &.{ "errors", name });
        const compile = try r.exec(try r.pebcCommand(&.{ "ir", src_path }), .none);
        if (compile.term != .exited or compile.term.exited != 1) {
            try r.out.print("  expected pebc to exit with status 1, got {any}\n", .{compile.term});
            return false;
        }
        return r.compare("errors", stem, ".err", compile.stderr);
    }

    /// Parses ast/NAME and compares the printed tree.
    fn checkTree(r: *Runner, name: []const u8) !bool {
        const stem = name[0 .. name.len - ".peb".len];
        const src_path = try std.fs.path.join(r.arena, &.{ "ast", name });
        const parse = try r.exec(&.{ r.pebc, "ast", src_path }, .none);
        if (!parse.term.success()) {
            try r.out.print("  pebc failed:\n{s}", .{parse.stderr});
            return false;
        }
        return r.compare("ast", stem, ".ast", parse.stdout);
    }

    /// Compares `actual` with the golden file SUITE/STEM.EXT, or with
    /// --update, makes `actual` the new golden file.
    fn compare(r: *Runner, suite: []const u8, stem: []const u8, ext: []const u8, actual: []const u8) !bool {
        const path = try std.fmt.allocPrint(r.arena, "{s}/{s}/{s}{s}", .{ r.tests_path, suite, stem, ext });
        const expected = Io.Dir.cwd().readFileAlloc(r.io, path, r.arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
        if (expected != null and std.mem.eql(u8, expected.?, actual)) return true;
        if (r.update) {
            try Io.Dir.cwd().writeFile(r.io, .{ .sub_path = path, .data = actual });
            try r.out.print("  updated {s}/{s}{s}\n", .{ suite, stem, ext });
            r.updated += 1;
            return true;
        }
        if (expected) |text| {
            try r.out.print("  --- {s}/{s}{s} (expected)\n  +++ actual\n", .{ suite, stem, ext });
            try writeDiff(r.arena, r.out, text, actual);
        } else {
            try r.out.print("  {s}/{s}{s} is missing; `zig build test -Dupdate` creates it\n", .{ suite, stem, ext });
        }
        return false;
    }

    /// Runs a program inside the tests directory and collects its output,
    /// at most 1 MiB of each stream.
    /// pebc with `args`, and --no-fold if the tests run without folding.
    fn pebcCommand(r: *Runner, args: []const []const u8) ![]const []const u8 {
        const flags: []const []const u8 = if (r.fold) &.{} else &.{"--no-fold"};
        return std.mem.concat(r.arena, []const u8, &.{ &.{r.pebc}, args, flags });
    }

    fn exec(r: *Runner, argv: []const []const u8, timeout: Io.Timeout) !std.process.RunResult {
        return std.process.run(r.arena, r.io, .{
            .argv = argv,
            .cwd = .{ .path = r.tests_path },
            .timeout = timeout,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        });
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Prints the lines that differ between `a` and `b`: "-" for a line only in
/// `a`, "+" for a line only in `b`, and up to two unchanged lines around
/// each change. It finds the longest common subsequence of lines with the
/// classic table: lcs[i][j] is the LCS length of a[i..] and b[j..].
/// That takes time and memory proportional to lines(a) × lines(b), which
/// is fine for golden files (git uses Myers' faster algorithm).
fn writeDiff(arena: std.mem.Allocator, w: *Io.Writer, a_text: []const u8, b_text: []const u8) !void {
    const a = try splitLines(arena, a_text);
    const b = try splitLines(arena, b_text);
    const width = b.len + 1;
    const lcs = try arena.alloc(u32, (a.len + 1) * width);
    @memset(lcs, 0);
    var i = a.len;
    while (i > 0) {
        i -= 1;
        var j = b.len;
        while (j > 0) {
            j -= 1;
            lcs[i * width + j] = if (std.mem.eql(u8, a[i], b[j]))
                lcs[(i + 1) * width + j + 1] + 1
            else
                @max(lcs[(i + 1) * width + j], lcs[i * width + j + 1]);
        }
    }

    // Walk the table from the start, collecting one edit per line.
    const Edit = struct { kind: u8, line: []const u8 };
    var edits: std.ArrayList(Edit) = .empty;
    i = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        if (i < a.len and j < b.len and std.mem.eql(u8, a[i], b[j])) {
            try edits.append(arena, .{ .kind = ' ', .line = a[i] });
            i += 1;
            j += 1;
        } else if (i < a.len and (j == b.len or lcs[(i + 1) * width + j] >= lcs[i * width + j + 1])) {
            try edits.append(arena, .{ .kind = '-', .line = a[i] });
            i += 1;
        } else {
            try edits.append(arena, .{ .kind = '+', .line = b[j] });
            j += 1;
        }
    }

    const context = 2;
    var last_printed: ?usize = null;
    for (edits.items, 0..) |edit, k| {
        const near_change = for (edits.items[k -| context..@min(k + context + 1, edits.items.len)]) |e| {
            if (e.kind != ' ') break true;
        } else false;
        if (!near_change) continue;
        if (last_printed) |l| if (k > l + 1) try w.writeAll("  ...\n");
        try w.print("  {c} {s}\n", .{ edit.kind, edit.line });
        last_printed = k;
    }
}

/// The lines of `text`, without their newlines. A missing newline at the
/// end shows up as a last line "\\ no newline at end".
fn splitLines(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(arena, line);
    const last = lines.pop().?;
    if (last.len > 0) {
        try lines.append(arena, last);
        try lines.append(arena, "\\ no newline at end");
    }
    return lines.items;
}
