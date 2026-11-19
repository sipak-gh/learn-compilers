//! Differential testing: `difftest PEBC OUT_DIR [--seed N] [--count N] [--keep]`.
//!
//! For each seed it generates a random program twice from the same random
//! choices: once in Pebble and once in C. It compiles the Pebble one with
//! pebc and the C one with cc, runs both, and compares what they print.
//! If they differ, one of the two compilers is wrong, and cc is a much
//! safer bet. Nobody has to write the expected output by hand.
//!
//! The generated programs use i64, i32 and u8 variables, arithmetic,
//! comparisons, casts, if/else, bounded while loops with break and
//! continue, and functions with parameters. They avoid everything whose
//! result C leaves undefined: signed overflow is made to wrap with
//! `cc -fwrapv`, division goes through helpers that never divide by zero
//! or compute MIN / -1, and since C evaluates operands in an unspecified
//! order, functions never change globals or print.
//!
//! The two programs match line for line: line 20 of case.peb is line 20
//! of case.c in the other language.
//!
//! Every case gets a directory OUT_DIR/SEED. It is deleted when the two
//! programs agree (unless --keep), so what remains are the failures.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: difftest PEBC OUT_DIR [--seed N] [--count N] [--keep]\n", .{});
        return 2;
    }
    var first_seed: u64 = 1;
    var count: u64 = 100;
    var keep = false;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--keep")) {
            keep = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--seed")) {
            i += 1;
            first_seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--count")) {
            i += 1;
            count = try std.fmt.parseInt(u64, args[i], 10);
        } else {
            std.debug.print("difftest: unexpected argument '{s}'\n", .{args[i]});
            return 2;
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const cwd = try std.process.currentPathAlloc(io, arena);
    const pebc = try std.fs.path.resolve(arena, &.{ cwd, args[1] });
    const out_path = try std.fs.path.resolve(arena, &.{ cwd, args[2] });

    var failures: usize = 0;
    var case_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer case_arena.deinit();
    for (0..count) |k| {
        _ = case_arena.reset(.retain_capacity);
        const seed = first_seed + k;
        const ok = try runCase(case_arena.allocator(), io, out, pebc, out_path, seed, keep);
        if (!ok) failures += 1;
        try out.flush();
    }
    try out.print("difftest: {d} program{s} (seeds {d}..{d}), {d} failed\n", .{
        count, if (count == 1) "" else "s", first_seed, first_seed + count -| 1, failures,
    });
    try out.flush();
    return if (failures == 0) 0 else 1;
}

/// Generates, compiles, runs and compares the case for one seed.
fn runCase(arena: Allocator, io: Io, out: *Io.Writer, pebc: []const u8, out_path: []const u8, seed: u64, keep: bool) !bool {
    var prng: std.Random.DefaultPrng = .init(seed);
    var peb: Io.Writer.Allocating = .init(arena);
    var c: Io.Writer.Allocating = .init(arena);
    var gen: Gen = .{ .arena = arena, .rand = prng.random(), .peb = &peb.writer, .c = &c.writer };
    try gen.program();

    const dir = try std.fmt.allocPrint(arena, "{s}/{d}", .{ out_path, seed });
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "case.peb" }), .data = peb.written() });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "case.c" }), .data = c.written() });

    const ok = try compareCase(arena, io, out, pebc, dir, seed);
    if (ok and !keep) try Io.Dir.cwd().deleteTree(io, dir);
    if (!ok) try out.print("  the files are in {s}\n", .{dir});
    return ok;
}

fn compareCase(arena: Allocator, io: Io, out: *Io.Writer, pebc: []const u8, dir: []const u8, seed: u64) !bool {
    const build_peb = try exec(arena, io, dir, &.{ pebc, "build", "case.peb", "-o", "case-peb" });
    if (!build_peb.term.success()) {
        try out.print("FAIL seed {d}: pebc rejected the program:\n{s}", .{ seed, build_peb.stderr });
        return false;
    }
    const build_c = try exec(arena, io, dir, &.{ "cc", "-fwrapv", "-w", "-o", "case-c", "case.c" });
    if (!build_c.term.success()) {
        try out.print("FAIL seed {d}: cc rejected the program:\n{s}", .{ seed, build_c.stderr });
        return false;
    }
    const run_peb = try execProgram(arena, io, out, dir, "./case-peb", seed) orelse return false;
    const run_c = try execProgram(arena, io, out, dir, "./case-c", seed) orelse return false;
    if (!std.meta.eql(run_peb.term, run_c.term) or !std.mem.eql(u8, run_peb.stdout, run_c.stdout)) {
        try out.print("FAIL seed {d}: the programs disagree\n", .{seed});
        try out.print("  pebc: {any}, {d} bytes of output\n  cc:   {any}, {d} bytes of output\n", .{
            run_peb.term, run_peb.stdout.len, run_c.term, run_c.stdout.len,
        });
        try printFirstDifference(out, run_peb.stdout, run_c.stdout);
        return false;
    }
    return true;
}

fn exec(arena: Allocator, io: Io, dir: []const u8, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(arena, io, .{ .argv = argv, .cwd = .{ .path = dir } });
}

/// Runs a compiled program for at most 10 seconds and 1 MiB of output;
/// null if it went over.
fn execProgram(arena: Allocator, io: Io, out: *Io.Writer, dir: []const u8, exe: []const u8, seed: u64) !?std.process.RunResult {
    return std.process.run(arena, io, .{
        .argv = &.{exe},
        .cwd = .{ .path = dir },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        .stdout_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.Timeout => {
            try out.print("FAIL seed {d}: {s} ran for more than 10 seconds\n", .{ seed, exe });
            return null;
        },
        error.StreamTooLong => {
            try out.print("FAIL seed {d}: {s} printed more than 1 MiB\n", .{ seed, exe });
            return null;
        },
        else => |e| return e,
    };
}

fn printFirstDifference(out: *Io.Writer, a: []const u8, b: []const u8) !void {
    var a_lines = std.mem.splitScalar(u8, a, '\n');
    var b_lines = std.mem.splitScalar(u8, b, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const x = a_lines.next();
        const y = b_lines.next();
        if (x == null and y == null) return;
        if (x == null or y == null or !std.mem.eql(u8, x.?, y.?)) {
            try out.print("  first difference, line {d}:\n  pebc: {s}\n  cc:   {s}\n", .{
                line, x orelse "(no more output)", y orelse "(no more output)",
            });
            return;
        }
    }
}

// ---- The program generator ----

const Type = enum {
    i64,
    i32,
    u8,

    const all = [_]Type{ .i64, .i32, .u8 };

    fn cName(t: Type) []const u8 {
        return switch (t) {
            .i64 => "int64_t",
            .i32 => "int32_t",
            .u8 => "uint8_t",
        };
    }

    fn signed(t: Type) bool {
        return t != .u8;
    }

    fn min(t: Type) i64 {
        return switch (t) {
            .i64 => std.math.minInt(i64),
            .i32 => std.math.minInt(i32),
            .u8 => 0,
        };
    }

    fn max(t: Type) i64 {
        return switch (t) {
            .i64 => std.math.maxInt(i64),
            .i32 => std.math.maxInt(i32),
            .u8 => 255,
        };
    }
};

/// One expression, written in both languages.
const Expr = struct {
    peb: []const u8,
    c: []const u8,
    /// An integer literal, possibly negated: in Pebble, it takes its type
    /// from the context.
    literal: bool = false,
    /// Pebble knows the type without any context, e.g. a variable. In
    /// `1 + 2` it doesn't: as an operand of `==` or `as`, which give no
    /// context, it would be an i64.
    typed: bool = true,
};

const Var = struct {
    name: []const u8,
    type: Type,
    assignable: bool,
};

const Func = struct {
    name: []const u8,
    params: []const Type,
    ret: Type,
};

const Gen = struct {
    arena: Allocator,
    rand: std.Random,
    peb: *Io.Writer,
    c: *Io.Writer,
    /// The variables in scope: globals first, then parameters and locals.
    vars: std.ArrayList(Var) = .empty,
    funcs: std.ArrayList(Func) = .empty,
    names: usize = 0,
    indent: usize = 0,
    /// The return type of the function being generated; null in main.
    ret: ?Type = null,
    loops: usize = 0,
    /// Statements left to generate, so programs stay small.
    budget: usize = 0,

    const max_depth = 3;

    fn program(g: *Gen) !void {
        try g.peb.writeAll(
            \\// A random program from tests/difftest.zig.
            \\extern fn printf(format: *u8, ...) i32;
            \\
            \\
        );
        try g.c.writeAll(
            \\#include <stdint.h>
            \\#include <stdio.h>
            \\
            \\
        );
        try g.helpers();

        // A global of each type, so that there is always a variable to use.
        for (Type.all) |t| try g.global(t);
        for (0..g.rand.uintLessThan(usize, 4)) |_| try g.global(g.randomType());
        try g.raw("\n", "\n");

        for (0..g.rand.uintLessThan(usize, 4)) |_| try g.function();

        try g.lines("fn main() {", "int main(void) {");
        g.ret = null;
        g.budget = 12 + g.rand.uintLessThan(usize, 20);
        g.indent = 1;
        const scope = g.vars.items.len;
        try g.block();
        // Print every variable that is still in scope.
        for (g.vars.items) |v| try g.print(v);
        g.vars.shrinkRetainingCapacity(scope);
        // C's main returns 0 without a `return 0;`, which keeps the
        // programs the same length.
        g.indent = 0;
        try g.lines("}", "}");
    }

    /// div_T and mod_T return `a` instead of dividing by 0 or computing
    /// MIN / -1, which overflows (and kills the program on x86-64).
    fn helpers(g: *Gen) !void {
        for (Type.all) |t| {
            const p = @tagName(t);
            const c = t.cName();
            const minus_one = if (t.signed()) " || b == -1" else "";
            for ([_][]const u8{ "div", "mod" }, [_][]const u8{ "/", "%" }) |name, op| {
                try g.peb.print(
                    \\fn {s}_{s}(a: {s}, b: {s}) {s} {{
                    \\    if b == 0{s} {{
                    \\        return a;
                    \\    }}
                    \\    return a {s} b;
                    \\}}
                    \\
                    \\
                , .{ name, p, p, p, p, minus_one, op });
                try g.c.print(
                    \\{s} {s}_{s}({s} a, {s} b) {{
                    \\    if (b == 0{s}) {{
                    \\        return a;
                    \\    }}
                    \\    return a {s} b;
                    \\}}
                    \\
                    \\
                , .{ c, name, p, c, c, minus_one, op });
            }
        }
    }

    fn global(g: *Gen, t: Type) !void {
        const name = try g.newName("g");
        const value = try g.literal(t);
        try g.peb.print("var {s}: {t} = {s};\n", .{ name, t, value.peb });
        try g.c.print("{s} {s} = {s};\n", .{ t.cName(), name, value.c });
        try g.vars.append(g.arena, .{ .name = name, .type = t, .assignable = true });
    }

    /// A function with parameters that computes a value from them and the
    /// globals. It may call the functions before it, but it never changes a
    /// global or prints, so the order in which C evaluates operands can't
    /// matter.
    fn function(g: *Gen) !void {
        const name = try g.newName("f");
        const params = try g.arena.alloc(Type, 1 + g.rand.uintLessThan(usize, 3));
        for (params) |*p| p.* = g.randomType();
        const ret = g.randomType();

        // Globals are read-only inside functions.
        const scope = g.vars.items.len;
        for (g.vars.items) |*v| v.assignable = false;
        try g.peb.print("fn {s}(", .{name});
        try g.c.print("{s} {s}(", .{ ret.cName(), name });
        for (params, 0..) |p, i| {
            const param = try g.newName("p");
            if (i > 0) try g.raw(", ", ", ");
            try g.peb.print("{s}: {t}", .{ param, p });
            try g.c.print("{s} {s}", .{ p.cName(), param });
            try g.vars.append(g.arena, .{ .name = param, .type = p, .assignable = false });
        }
        try g.peb.print(") {t} {{\n", .{ret});
        try g.c.writeAll(") {\n");

        g.ret = ret;
        g.budget = 3 + g.rand.uintLessThan(usize, 8);
        g.indent = 1;
        try g.block();
        const result = try g.expr(ret, max_depth);
        try g.line("return {s};", "return {s};", result);
        g.indent = 0;
        try g.lines("}\n", "}\n");

        g.vars.shrinkRetainingCapacity(scope);
        for (g.vars.items) |*v| v.assignable = true;
        try g.funcs.append(g.arena, .{ .name = name, .params = params, .ret = ret });
    }

    /// Statements until the budget runs out or the block randomly ends.
    fn block(g: *Gen) Error!void {
        while (g.budget > 0) {
            g.budget -= 1;
            try g.statement();
            if (g.rand.uintLessThan(u8, 5) == 0) break;
        }
    }

    const Error = Allocator.Error || Io.Writer.Error;

    fn statement(g: *Gen) Error!void {
        switch (g.rand.uintLessThan(u8, 10)) {
            0, 1 => {
                const t = g.randomType();
                const name = try g.newName("v");
                const value = try g.expr(t, max_depth);
                try g.indentBoth();
                try g.peb.print("var {s}: {t} = {s};\n", .{ name, t, value.peb });
                try g.c.print("{s} {s} = {s};\n", .{ t.cName(), name, value.c });
                try g.vars.append(g.arena, .{ .name = name, .type = t, .assignable = true });
            },
            2, 3, 4 => {
                const v = g.pickVar(null, true) orelse return;
                const value = try g.expr(v.type, max_depth);
                try g.indentBoth();
                try g.peb.print("{s} = {s};\n", .{ v.name, value.peb });
                try g.c.print("{s} = {s};\n", .{ v.name, value.c });
            },
            5 => {
                const cond = try g.condition(max_depth);
                try g.line("if {s} {{", "if ({s}) {{", cond);
                try g.nested();
                if (g.rand.boolean()) {
                    try g.lines("} else {", "} else {");
                    try g.nested();
                }
                try g.lines("}", "}");
            },
            6 => {
                // The counter goes up first, so `continue` can't loop forever.
                const counter = try g.newName("i");
                const limit = 1 + g.rand.uintLessThan(u8, 5);
                try g.indentBoth();
                try g.peb.print("var {s}: i64 = 0;\n", .{counter});
                try g.c.print("int64_t {s} = 0;\n", .{counter});
                try g.indentBoth();
                try g.peb.print("while {s} < {d} {{\n", .{ counter, limit });
                try g.c.print("while ({s} < {d}) {{\n", .{ counter, limit });
                g.indent += 1;
                try g.indentBoth();
                try g.peb.print("{s} = {s} + 1;\n", .{ counter, counter });
                try g.c.print("{s} = {s} + 1;\n", .{ counter, counter });
                g.indent -= 1;
                try g.vars.append(g.arena, .{ .name = counter, .type = .i64, .assignable = false });
                g.loops += 1;
                try g.nested();
                g.loops -= 1;
                try g.lines("}", "}");
            },
            7 => {
                if (g.loops == 0) return;
                const cond = try g.condition(1);
                const jump = if (g.rand.boolean()) "break;" else "continue;";
                try g.line("if {s} {{", "if ({s}) {{", cond);
                g.indent += 1;
                try g.lines(jump, jump);
                g.indent -= 1;
                try g.lines("}", "}");
            },
            8, 9 => if (g.ret) |ret| {
                // An early return.
                const cond = try g.condition(1);
                try g.line("if {s} {{", "if ({s}) {{", cond);
                g.indent += 1;
                try g.line("return {s};", "return {s};", try g.expr(ret, 2));
                g.indent -= 1;
                try g.lines("}", "}");
            } else {
                try g.print(g.pickVar(null, false).?);
            },
            else => unreachable,
        }
    }

    /// A block inside braces, with its own scope. In main, it ends by
    /// printing its variables: a wrong value that is never printed can't
    /// make a test fail.
    fn nested(g: *Gen) Error!void {
        const scope = g.vars.items.len;
        g.indent += 1;
        try g.block();
        if (g.ret == null) for (g.vars.items[scope..]) |v| try g.print(v);
        g.indent -= 1;
        g.vars.shrinkRetainingCapacity(scope);
    }

    fn print(g: *Gen, v: Var) !void {
        try g.indentBoth();
        switch (v.type) {
            .i64 => {
                try g.peb.print("printf(\"{s} = %ld\\n\", {s});\n", .{ v.name, v.name });
                try g.c.print("printf(\"{s} = %ld\\n\", (long){s});\n", .{ v.name, v.name });
            },
            .i32 => {
                try g.peb.print("printf(\"{s} = %d\\n\", {s});\n", .{ v.name, v.name });
                try g.c.print("printf(\"{s} = %d\\n\", (int){s});\n", .{ v.name, v.name });
            },
            .u8 => {
                try g.peb.print("printf(\"{s} = %d\\n\", {s} as i32);\n", .{ v.name, v.name });
                try g.c.print("printf(\"{s} = %d\\n\", (int){s});\n", .{ v.name, v.name });
            },
        }
    }

    // ---- Expressions ----

    /// An expression of type `t`. In C, every operation is cast back to
    /// its type, because C does arithmetic on `uint8_t` in `int`.
    fn expr(g: *Gen, t: Type, depth: u32) Error!Expr {
        if (depth == 0) return if (g.rand.boolean()) g.literal(t) else g.variable(t);
        const c = t.cName();
        switch (g.rand.uintLessThan(u8, 14)) {
            0 => return g.literal(t),
            1, 2 => return g.variable(t),
            3, 4, 5 => {
                const op = ([_][]const u8{ "+", "-", "*" })[g.rand.uintLessThan(usize, 3)];
                return g.binary(t, op, try g.expr(t, depth - 1), try g.expr(t, depth - 1));
            },
            6 => {
                // Dividing by a literal other than 0 and -1 is always safe.
                const op = if (g.rand.boolean()) "/" else "%";
                const divisor: i64 = if (t.signed() and g.rand.boolean())
                    -g.rand.intRangeAtMost(i64, 2, 9)
                else
                    g.rand.intRangeAtMost(i64, 1, 9);
                return g.binary(t, op, try g.expr(t, depth - 1), try g.literalValue(t, divisor));
            },
            7 => {
                const name = if (g.rand.boolean()) "div" else "mod";
                const a = try g.expr(t, depth - 1);
                const b = try g.expr(t, depth - 1);
                return .{
                    .peb = try g.fmt("{s}_{t}({s}, {s})", .{ name, t, a.peb, b.peb }),
                    .c = try g.fmt("{s}_{t}({s}, {s})", .{ name, t, a.c, b.c }),
                };
            },
            8 => {
                if (!t.signed()) return g.variable(t);
                var operand = try g.expr(t, depth - 1);
                if (operand.literal) operand = try g.variable(t);
                return .{
                    .peb = try g.fmt("-{s}", .{operand.peb}),
                    .c = try g.fmt("(({s})-{s})", .{ c, operand.c }),
                    .typed = operand.typed,
                };
            },
            9, 10 => {
                // Conversions between types get extra weight: they are
                // where compilers often go wrong.
                const from = g.randomType();
                var operand = try g.expr(from, depth - 1);
                if (!operand.typed) operand = try g.variable(from);
                return .{
                    .peb = try g.fmt("({s} as {t})", .{ operand.peb, t }),
                    .c = try g.fmt("(({s}){s})", .{ c, operand.c }),
                };
            },
            11 => {
                const cond = try g.condition(depth - 1);
                return .{
                    .peb = try g.fmt("({s} as {t})", .{ cond.peb, t }),
                    .c = try g.fmt("(({s})({s}))", .{ c, cond.c }),
                };
            },
            12, 13 => return g.call(t, depth),
            else => unreachable,
        }
    }

    fn binary(g: *Gen, t: Type, op: []const u8, lhs: Expr, rhs: Expr) !Expr {
        return .{
            .peb = try g.fmt("({s} {s} {s})", .{ lhs.peb, op, rhs.peb }),
            .c = try g.fmt("(({s})({s} {s} {s}))", .{ t.cName(), lhs.c, op, rhs.c }),
            .typed = binaryTyped(lhs, rhs),
        };
    }

    /// Pebble's checker types the operands of `lhs OP rhs` like this: if
    /// only lhs is a literal, rhs goes first and the literal takes its
    /// type; otherwise lhs goes first and rhs takes lhs's type.
    fn binaryTyped(lhs: Expr, rhs: Expr) bool {
        return if (lhs.literal and !rhs.literal) rhs.typed else lhs.typed;
    }

    /// A call to an earlier function that returns `t`, if there is one.
    fn call(g: *Gen, t: Type, depth: u32) !Expr {
        var candidates: std.ArrayList(Func) = .empty;
        for (g.funcs.items) |f| if (f.ret == t) try candidates.append(g.arena, f);
        if (candidates.items.len == 0) return g.variable(t);
        const f = candidates.items[g.rand.uintLessThan(usize, candidates.items.len)];
        var peb: Io.Writer.Allocating = .init(g.arena);
        var c: Io.Writer.Allocating = .init(g.arena);
        try peb.writer.print("{s}(", .{f.name});
        try c.writer.print("{s}(", .{f.name});
        for (f.params, 0..) |p, i| {
            const arg = try g.expr(p, depth - 1);
            if (i > 0) {
                try peb.writer.writeAll(", ");
                try c.writer.writeAll(", ");
            }
            try peb.writer.writeAll(arg.peb);
            try c.writer.writeAll(arg.c);
        }
        try peb.writer.writeByte(')');
        try c.writer.writeByte(')');
        return .{ .peb = peb.written(), .c = c.written() };
    }

    /// A bool expression: a comparison, possibly combined with && || !.
    fn condition(g: *Gen, depth: u32) Error!Expr {
        if (depth > 0) switch (g.rand.uintLessThan(u8, 6)) {
            0 => {
                const op = if (g.rand.boolean()) "&&" else "||";
                const a = try g.condition(depth - 1);
                const b = try g.condition(depth - 1);
                return .{
                    .peb = try g.fmt("({s} {s} {s})", .{ a.peb, op, b.peb }),
                    .c = try g.fmt("({s} {s} {s})", .{ a.c, op, b.c }),
                };
            },
            1 => {
                const a = try g.condition(depth - 1);
                return .{ .peb = try g.fmt("!{s}", .{a.peb}), .c = try g.fmt("!{s}", .{a.c}) };
            },
            else => {},
        };
        const ops = [_][]const u8{ "==", "!=", "<", "<=", ">", ">=" };
        const op = ops[g.rand.uintLessThan(usize, ops.len)];
        const t = g.randomType();
        var lhs = try g.expr(t, depth -| 1);
        const rhs = try g.expr(t, depth -| 1);
        // `==` gives its operands no context, so they must be typed.
        if (!binaryTyped(lhs, rhs)) lhs = try g.variable(t);
        return .{
            .peb = try g.fmt("({s} {s} {s})", .{ lhs.peb, op, rhs.peb }),
            .c = try g.fmt("({s} {s} {s})", .{ lhs.c, op, rhs.c }),
        };
    }

    /// A literal: often an edge case like 0, -1 or the largest value.
    fn literal(g: *Gen, t: Type) !Expr {
        const value: i64 = switch (g.rand.uintLessThan(u8, 8)) {
            0 => 0,
            1 => 1,
            2 => if (t.signed()) -1 else 2,
            3 => t.max(),
            // The minimum can't be written as a literal: -128 is 128 negated,
            // and 128 doesn't fit in i8. Here min + 1 is close enough.
            4 => if (t.signed()) t.min() + 1 else 0,
            5 => g.rand.intRangeAtMost(i64, -100, 100),
            else => g.rand.intRangeAtMost(i64, t.min() + 1, t.max()),
        };
        return g.literalValue(t, if (t.signed()) value else @intCast(@abs(value)));
    }

    fn literalValue(g: *Gen, t: Type, value: i64) !Expr {
        const suffix = if (t == .i64) "L" else "";
        return .{
            .peb = try g.fmt("{d}", .{value}),
            .c = try g.fmt("(({s}){d}{s})", .{ t.cName(), value, suffix }),
            .literal = true,
            .typed = false,
        };
    }

    fn variable(g: *Gen, t: Type) !Expr {
        const v = g.pickVar(t, false).?;
        return .{ .peb = v.name, .c = v.name };
    }

    /// A random variable in scope, of type `t` if not null.
    fn pickVar(g: *Gen, t: ?Type, assignable: bool) ?Var {
        var n: usize = 0;
        for (g.vars.items) |v| {
            if ((t == null or v.type == t.?) and (!assignable or v.assignable)) n += 1;
        }
        if (n == 0) return null;
        var pick = g.rand.uintLessThan(usize, n);
        for (g.vars.items) |v| {
            if ((t == null or v.type == t.?) and (!assignable or v.assignable)) {
                if (pick == 0) return v;
                pick -= 1;
            }
        }
        unreachable;
    }

    fn randomType(g: *Gen) Type {
        return Type.all[g.rand.uintLessThan(usize, Type.all.len)];
    }

    fn newName(g: *Gen, prefix: []const u8) ![]const u8 {
        g.names += 1;
        return g.fmt("{s}{d}", .{ prefix, g.names });
    }

    fn fmt(g: *Gen, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(g.arena, format, args);
    }

    fn indentBoth(g: *Gen) !void {
        for (0..g.indent) |_| try g.raw("    ", "    ");
    }

    fn raw(g: *Gen, peb: []const u8, c: []const u8) !void {
        try g.peb.writeAll(peb);
        try g.c.writeAll(c);
    }

    /// One line in each language.
    fn lines(g: *Gen, peb: []const u8, c: []const u8) !void {
        try g.indentBoth();
        try g.peb.print("{s}\n", .{peb});
        try g.c.print("{s}\n", .{c});
    }

    /// One line in each language, with `e` in place of the {s}.
    fn line(g: *Gen, comptime peb: []const u8, comptime c: []const u8, e: Expr) !void {
        try g.indentBoth();
        try g.peb.print(peb ++ "\n", .{e.peb});
        try g.c.print(c ++ "\n", .{e.c});
    }
};
