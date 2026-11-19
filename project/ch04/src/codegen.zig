//! Code generation: syntax tree in, QBE IL out.
//!
//! Every value is a 64-bit integer (QBE type `l`), the way every value in
//! B was a machine word. Every variable lives in a stack slot made by
//! `alloc8`; QBE promotes the slots to registers for us.
//!
//! Names in the IL:
//!   %.N        a temporary (a dot can't start a Pebble name, so no clashes)
//!   %x         the incoming value of parameter x
//!   %x.N       the stack slot of variable x
//!   @if.N.then, @while.N.cond, ...  labels
//!   $str.N     a string literal
const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const diag = @import("diag.zig");
const Span = diag.Span;
const Diagnostics = diag.Diagnostics;

pub const Error = error{ CodegenError, WriteFailed, OutOfMemory };

/// An operand of a QBE instruction.
const Value = union(enum) {
    int: i64,
    temp: u32,
    string: usize,

    pub fn format(v: Value, w: *Writer) Writer.Error!void {
        switch (v) {
            .int => |n| try w.print("{d}", .{n}),
            .temp => |t| try w.print("%.{d}", .{t}),
            .string => |s| try w.print("$str.{d}", .{s}),
        }
    }
};

/// A variable in scope: its stack slot is %name.id.
const Local = struct {
    name: []const u8,
    span: Span,
    mutable: bool,
    id: u32,

    pub fn format(l: Local, w: *Writer) Writer.Error!void {
        try w.print("%{s}.{d}", .{ l.name, l.id });
    }
};

pub const CodeGen = struct {
    arena: std.mem.Allocator,
    out: *Writer,
    diags: *Diagnostics,
    /// Every function in the program, by name.
    funcs: std.StringHashMapUnmanaged(*const ast.Func) = .empty,
    /// String literals, written out as data after the functions.
    strings: std.ArrayList([]const u8) = .empty,

    // The state below belongs to the function being generated.

    /// `alloc8` instructions; they all go in the start block.
    allocs: Writer.Allocating,
    /// The function body.
    code: Writer.Allocating,
    locals: std.ArrayList(Local) = .empty,
    /// The label numbers of the loops we are inside, innermost last.
    loops: std.ArrayList(u32) = .empty,
    temps: u32 = 0,
    /// Numbers labels and stack slots, so every name is unique.
    ids: u32 = 0,
    /// False right after a jump or return: QBE needs a label before the
    /// next instruction.
    block_open: bool = true,

    pub fn init(arena: std.mem.Allocator, out: *Writer, diags: *Diagnostics) CodeGen {
        return .{
            .arena = arena,
            .out = out,
            .diags = diags,
            .allocs = .init(arena),
            .code = .init(arena),
        };
    }

    pub fn genProgram(g: *CodeGen, program: ast.Program) Error!void {
        // Pass 1: collect the functions, so a call can come before the
        // function it calls.
        for (program.decls) |decl| switch (decl) {
            .func => |f| {
                const entry = try g.funcs.getOrPut(g.arena, f.name);
                if (entry.found_existing) {
                    try g.diags.err(f.name_span, "'{s}' is already declared", .{f.name});
                    try g.diags.add(.note, entry.value_ptr.*.name_span, "the first declaration is here", .{});
                } else {
                    entry.value_ptr.* = f;
                }
            },
        };
        if (g.funcs.get("main")) |main| {
            if (main.body == null) {
                try g.diags.err(main.name_span, "'main' must be defined here, not extern", .{});
            } else if (main.params.len > 0) {
                try g.diags.err(main.params[0].span, "'main' takes no parameters", .{});
            }
        } else {
            try g.diags.err(.{ .start = 0, .end = 0 }, "the program has no 'main' function", .{});
        }

        // Pass 2: generate each function. An error ends the function it
        // is in, but we carry on with the next one to find more errors.
        for (program.decls) |decl| switch (decl) {
            .func => |f| if (f.body != null) g.genFunction(f) catch |err| switch (err) {
                error.CodegenError => {},
                else => |e| return e,
            },
        };

        for (g.strings.items, 0..) |s, i| {
            try g.out.print("data $str.{d} = {{ ", .{i});
            try writeStringData(g.out, s);
            try g.out.writeAll(" }\n");
        }
    }

    fn genFunction(g: *CodeGen, f: *const ast.Func) Error!void {
        g.allocs.clearRetainingCapacity();
        g.code.clearRetainingCapacity();
        g.locals.clearRetainingCapacity();
        g.temps = 0;
        g.ids = 0;
        g.block_open = true;

        // Parameters arrive in temporaries; copy each into a stack slot so
        // that it can be assigned like any other variable.
        for (f.params) |param| {
            const slot = try g.declare(param.name, param.span, true);
            try g.emit("storel %{s}, {f}", .{ param.name, slot });
        }
        try g.genStmts(f.body.?.stmts);
        // Falling off the end of a function returns 0.
        if (g.block_open) try g.emit("ret 0", .{});

        if (std.mem.eql(u8, f.name, "main")) {
            try g.out.writeAll("export function w $main(");
        } else {
            try g.out.print("function l ${s}(", .{f.name});
        }
        for (f.params, 0..) |param, i| {
            if (i > 0) try g.out.writeAll(", ");
            try g.out.print("l %{s}", .{param.name});
        }
        try g.out.writeAll(") {\n@start\n");
        try g.out.writeAll(g.allocs.written());
        try g.out.writeAll(g.code.written());
        try g.out.writeAll("}\n\n");
    }

    // ---- Statements ----

    fn genStmt(g: *CodeGen, s: *const Stmt) Error!void {
        switch (s.kind) {
            .let => |l| {
                // The value comes first: in `let x = x + 1;` the x on the
                // right is the outer one.
                const value = g.genExpr(l.value) catch |err| {
                    // Declare the variable anyway, or every later use of
                    // it would be one more "unknown name" error.
                    _ = try g.declare(l.name, l.name_span, l.mutable);
                    return err;
                };
                const slot = try g.declare(l.name, l.name_span, l.mutable);
                try g.emit("storel {f}, {f}", .{ value, slot });
            },
            .assign => |a| {
                const slot = try g.assignable(a.target);
                const value = try g.genExpr(a.value);
                try g.emit("storel {f}, {f}", .{ value, slot });
            },
            .expr => |e| _ = try g.genExpr(e),
            .@"if" => |i| {
                const id = g.nextId();
                const cond = try g.genCond(i.cond);
                const no = if (i.@"else" != null) "else" else "end";
                try g.emit("jnz {f}, @if.{d}.then, @if.{d}.{s}", .{ cond, id, id, no });
                try g.label("@if.{d}.then", .{id});
                try g.genBlock(i.then);
                if (i.@"else") |else_branch| {
                    try g.emit("jmp @if.{d}.end", .{id});
                    try g.label("@if.{d}.else", .{id});
                    try g.genStmt(else_branch);
                }
                try g.label("@if.{d}.end", .{id});
            },
            .@"while" => |w| {
                const id = g.nextId();
                try g.label("@while.{d}.cond", .{id});
                const cond = try g.genCond(w.cond);
                try g.emit("jnz {f}, @while.{d}.body, @while.{d}.end", .{ cond, id, id });
                try g.label("@while.{d}.body", .{id});
                try g.loops.append(g.arena, id);
                try g.genBlock(w.body);
                _ = g.loops.pop();
                try g.emit("jmp @while.{d}.cond", .{id});
                try g.label("@while.{d}.end", .{id});
            },
            .@"break" => {
                const id = g.loops.getLastOrNull() orelse return g.fail(s.span, "'break' outside of a loop", .{});
                try g.emit("jmp @while.{d}.end", .{id});
            },
            .@"continue" => {
                const id = g.loops.getLastOrNull() orelse return g.fail(s.span, "'continue' outside of a loop", .{});
                try g.emit("jmp @while.{d}.cond", .{id});
            },
            .@"return" => |value| {
                const v: Value = if (value) |e| try g.genExpr(e) else .{ .int = 0 };
                try g.emit("ret {f}", .{v});
            },
            .block => |b| try g.genBlock(b),
        }
    }

    fn genBlock(g: *CodeGen, b: ast.Block) Error!void {
        // Variables declared in the block go out of scope at its end.
        const scope_start = g.locals.items.len;
        defer g.locals.shrinkRetainingCapacity(scope_start);
        try g.genStmts(b.stmts);
    }

    /// After an error in one statement, carry on with the next one to find
    /// more errors. The IL is thrown away anyway.
    fn genStmts(g: *CodeGen, stmts: []const *Stmt) Error!void {
        var failed = false;
        for (stmts) |s| g.genStmt(s) catch |err| switch (err) {
            error.CodegenError => failed = true,
            else => |e| return e,
        };
        if (failed) return error.CodegenError;
    }

    /// Makes a stack slot for a new variable.
    fn declare(g: *CodeGen, name: []const u8, span: Span, mutable: bool) Error!Local {
        const local: Local = .{ .name = name, .span = span, .mutable = mutable, .id = g.nextId() };
        try g.locals.append(g.arena, local);
        try g.allocs.writer.print("\t{f} =l alloc8 8\n", .{local});
        return local;
    }

    fn lookup(g: *CodeGen, name: []const u8) ?Local {
        // Search from the innermost scope outwards, so inner variables
        // shadow outer ones.
        var i = g.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, g.locals.items[i].name, name)) return g.locals.items[i];
        }
        return null;
    }

    fn variable(g: *CodeGen, name: []const u8, span: Span) Error!Local {
        if (g.lookup(name)) |local| return local;
        if (g.funcs.contains(name)) return g.fail(span, "'{s}' is a function, not a variable", .{name});
        return g.fail(span, "unknown name '{s}'", .{name});
    }

    /// Finds the variable on the left of `=`, or reports why it can't be
    /// assigned.
    fn assignable(g: *CodeGen, target: *const Expr) Error!Local {
        if (target.kind != .name) return g.fail(target.span, "cannot assign to this expression", .{});
        const name = target.kind.name;
        const local = try g.variable(name, target.span);
        if (!local.mutable) {
            try g.diags.err(target.span, "cannot assign to '{s}', which was declared with 'let'", .{name});
            try g.diags.add(.note, local.span, "use 'var' here to make it a variable", .{});
            return error.CodegenError;
        }
        return local;
    }

    // ---- Expressions ----

    /// Emits the instructions that compute `e` and returns where the
    /// result is.
    fn genExpr(g: *CodeGen, e: *const Expr) Error!Value {
        switch (e.kind) {
            .int => |n| return .{ .int = @intCast(n) },
            .char => |c| return .{ .int = c },
            .bool => |b| return .{ .int = @intFromBool(b) },
            .string => |s| {
                try g.strings.append(g.arena, s);
                return .{ .string = g.strings.items.len - 1 };
            },
            .name => |name| return g.result("loadl {f}", .{try g.variable(name, e.span)}),
            .unary => |u| switch (u.op) {
                .neg => return g.result("neg {f}", .{try g.genExpr(u.operand)}),
                .not => return g.result("ceql {f}, 0", .{try g.genExpr(u.operand)}),
                .addr, .deref => return g.fail(e.span, "pebc cannot compile pointers yet", .{}),
            },
            .binary => |b| {
                const op: []const u8 = switch (b.op) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    .div => "div",
                    .rem => "rem",
                    .eq => "ceql",
                    .ne => "cnel",
                    .lt => "csltl",
                    .le => "cslel",
                    .gt => "csgtl",
                    .ge => "csgel",
                    .@"and", .@"or" => return g.genLogical(b),
                };
                const lhs = try g.genExpr(b.lhs);
                const rhs = try g.genExpr(b.rhs);
                return g.result("{s} {f}, {f}", .{ op, lhs, rhs });
            },
            .call => |c| return g.genCall(e, c),
            .index => return g.fail(e.span, "pebc cannot compile indexing yet", .{}),
            .field => return g.fail(e.span, "pebc cannot compile fields yet", .{}),
        }
    }

    /// `a && b` and `a || b` only evaluate `b` when they need to, so they
    /// are control flow, not arithmetic. The result temporary is assigned
    /// on two paths; QBE turns that into SSA form for us.
    fn genLogical(g: *CodeGen, b: Expr.Binary) Error!Value {
        const id = g.nextId();
        const name = @tagName(b.op);
        const result_temp = g.newTemp();
        const lhs = try g.genCond(b.lhs);
        try g.emit("{f} =l copy {f}", .{ result_temp, lhs });
        if (b.op == .@"and") {
            try g.emit("jnz {f}, @and.{d}.rhs, @and.{d}.end", .{ lhs, id, id });
        } else {
            try g.emit("jnz {f}, @or.{d}.end, @or.{d}.rhs", .{ lhs, id, id });
        }
        try g.label("@{s}.{d}.rhs", .{ name, id });
        const rhs = try g.genCond(b.rhs);
        try g.emit("{f} =l copy {f}", .{ result_temp, rhs });
        try g.label("@{s}.{d}.end", .{ name, id });
        return result_temp;
    }

    /// Computes a condition as 0 or 1. `jnz` only looks at the low 32 bits
    /// of its argument, so a 64-bit value like 1 << 32 must be compared
    /// with 0 first.
    fn genCond(g: *CodeGen, e: *const Expr) Error!Value {
        const v = try g.genExpr(e);
        const is_0_or_1 = switch (e.kind) {
            .bool => true,
            .unary => |u| u.op == .not,
            .binary => |b| b.op.isComparison() or b.op == .@"and" or b.op == .@"or",
            else => false,
        };
        if (is_0_or_1) return v;
        return g.result("cnel {f}, 0", .{v});
    }

    fn genCall(g: *CodeGen, e: *const Expr, c: Expr.Call) Error!Value {
        if (c.callee.kind != .name) return g.fail(c.callee.span, "only named functions can be called", .{});
        const name = c.callee.kind.name;
        if (g.lookup(name) != null) return g.fail(c.callee.span, "'{s}' is a variable, not a function", .{name});
        const f = g.funcs.get(name) orelse return g.fail(c.callee.span, "unknown function '{s}'", .{name});

        const n = f.params.len;
        if (c.args.len < n or (c.args.len > n and !f.variadic)) {
            try g.diags.err(e.span, "'{s}' takes {s}{d} argument{s}, but {d} {s} given", .{
                name,
                if (f.variadic) "at least " else "",
                n,
                if (n == 1) "" else "s",
                c.args.len,
                if (c.args.len == 1) "was" else "were",
            });
            try g.diags.add(.note, f.name_span, "'{s}' is declared here", .{name});
            return error.CodegenError;
        }

        const args = try g.arena.alloc(Value, c.args.len);
        for (c.args, args) |arg, *v| v.* = try g.genExpr(arg);

        const t = g.newTemp();
        try g.ensureBlock();
        const w = &g.code.writer;
        try w.print("\t{f} =l call ${s}(", .{ t, name });
        for (args, 0..) |arg, i| {
            if (i > 0) try w.writeAll(", ");
            // Variadic arguments come after a `...` marker.
            if (i == n) try w.writeAll("..., ");
            try w.print("l {f}", .{arg});
        }
        if (f.variadic and args.len == n) try w.writeAll(if (n > 0) ", ..." else "...");
        try w.writeAll(")\n");
        return t;
    }

    // ---- Emitting IL ----

    fn newTemp(g: *CodeGen) Value {
        g.temps += 1;
        return .{ .temp = g.temps };
    }

    fn nextId(g: *CodeGen) u32 {
        g.ids += 1;
        return g.ids;
    }

    /// Writes `%.N =l INSTRUCTION` and returns `%.N`.
    fn result(g: *CodeGen, comptime fmt: []const u8, args: anytype) Error!Value {
        const t = g.newTemp();
        try g.emit("{f} =l " ++ fmt, .{t} ++ args);
        return t;
    }

    /// Writes one instruction.
    fn emit(g: *CodeGen, comptime fmt: []const u8, args: anytype) Error!void {
        try g.ensureBlock();
        try g.code.writer.print("\t" ++ fmt ++ "\n", args);
        const ends_block = comptime std.mem.startsWith(u8, fmt, "jmp") or
            std.mem.startsWith(u8, fmt, "jnz") or std.mem.startsWith(u8, fmt, "ret");
        if (ends_block) g.block_open = false;
    }

    /// Code after `return`, `break` or `continue` can never run, but QBE
    /// still wants it in a block of its own.
    fn ensureBlock(g: *CodeGen) Error!void {
        if (!g.block_open) try g.label("@dead.{d}", .{g.nextId()});
    }

    fn label(g: *CodeGen, comptime fmt: []const u8, args: anytype) Error!void {
        try g.code.writer.print(fmt ++ "\n", args);
        g.block_open = true;
    }

    fn fail(g: *CodeGen, span: Span, comptime fmt: []const u8, args: anytype) Error {
        try g.diags.err(span, fmt, args);
        return error.CodegenError;
    }
};

/// Writes the bytes of a string as QBE data items, plus the 0 terminator:
/// "hi\n" becomes `b "hi", b 10, b 0`.
fn writeStringData(w: *Writer, s: []const u8) Writer.Error!void {
    var in_quotes = false;
    for (s) |c| {
        const printable = c >= ' ' and c <= '~' and c != '"' and c != '\\';
        if (printable) {
            if (!in_quotes) try w.writeAll("b \"");
            in_quotes = true;
            try w.writeByte(c);
        } else {
            if (in_quotes) try w.writeAll("\", ");
            in_quotes = false;
            try w.print("b {d}, ", .{c});
        }
    }
    if (in_quotes) try w.writeAll("\", ");
    try w.writeAll("b 0");
}

test writeStringData {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeStringData(&out.writer, "say \"hi\"\n");
    try std.testing.expectEqualStrings(
        \\b "say ", b 34, b "hi", b 34, b 10, b 0
    , out.written());
}
