//! Code generation: checked syntax tree in, QBE IL out.
//!
//! The checker has already found every error and written a type into
//! every expression, so this file never reports an error: it only picks
//! the QBE instruction that fits each type.
//!
//! Pebble types in QBE:
//!   i64, pointers     l (64 bits)
//!   i32, u8, bool     w (32 bits); a u8 is kept between 0 and 255, a bool
//!                     is 0 or 1
//!   arrays            never in a temporary: only in memory, used through
//!                     their address
//!
//! Names in the IL:
//!   %.N        a temporary (a dot can't start a Pebble name, so no clashes)
//!   %x         the incoming value of parameter x
//!   %x.N       the stack slot of local variable x
//!   $x         global variable x (and function x)
//!   @if.N.then, @while.N.cond, ...  labels
//!   $str.N     a string literal
const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Symbol = ast.Symbol;
const Type = @import("types.zig").Type;

pub const Error = error{ WriteFailed, OutOfMemory };

/// An operand of a QBE instruction.
const Value = union(enum) {
    int: i64,
    temp: u32,
    string: usize,
    /// The address of a variable: its stack slot %name.id, or $name for a
    /// global.
    slot: *const Symbol,

    pub fn format(v: Value, w: *Writer) Writer.Error!void {
        switch (v) {
            .int => |n| try w.print("{d}", .{n}),
            .temp => |t| try w.print("%.{d}", .{t}),
            .string => |s| try w.print("$str.{d}", .{s}),
            .slot => |sym| if (sym.global)
                try w.print("${s}", .{sym.name})
            else
                try w.print("%{s}.{d}", .{ sym.name, sym.id }),
        }
    }
};

pub const CodeGen = struct {
    arena: std.mem.Allocator,
    out: *Writer,
    /// String literals, written out as data after the functions.
    strings: std.ArrayList([]const u8) = .empty,

    // The state below belongs to the function being generated.

    func: *const ast.Func = undefined,
    /// `alloc` instructions; they all go in the start block.
    allocs: Writer.Allocating,
    /// The function body.
    code: Writer.Allocating,
    /// The label numbers of the loops we are inside, innermost last.
    loops: std.ArrayList(u32) = .empty,
    temps: u32 = 0,
    /// Numbers labels, so every label is unique.
    ids: u32 = 0,
    /// False right after a jump or return: QBE needs a label before the
    /// next instruction.
    block_open: bool = true,

    pub fn init(arena: std.mem.Allocator, out: *Writer) CodeGen {
        return .{
            .arena = arena,
            .out = out,
            .allocs = .init(arena),
            .code = .init(arena),
        };
    }

    pub fn genProgram(g: *CodeGen, program: ast.Program) Error!void {
        for (program.decls) |decl| switch (decl) {
            .func => |f| if (f.body != null) try g.genFunction(f),
            .global => |s| try g.genGlobal(s.kind.let),
        };
        for (g.strings.items, 0..) |s, i| {
            try g.out.print("data $str.{d} = {{ ", .{i});
            try writeStringData(g.out, s);
            try g.out.writeAll(" }\n");
        }
    }

    fn genFunction(g: *CodeGen, f: *const ast.Func) Error!void {
        g.func = f;
        g.allocs.clearRetainingCapacity();
        g.code.clearRetainingCapacity();
        g.temps = 0;
        g.ids = 0;
        g.block_open = true;
        const is_main = std.mem.eql(u8, f.name, "main");

        // Parameters arrive in temporaries; copy each into a stack slot so
        // that it can be assigned like any other variable.
        for (f.params) |param| {
            const slot = try g.declare(param.sym);
            try g.emit("store{s} %{s}, {f}", .{ storeSuffix(param.sym.type), param.name, slot });
        }
        try g.genStmts(f.body.?.stmts);
        if (g.block_open) {
            if (f.ret != .void) {
                // The checker made sure every path returns, so this point
                // can't be reached (it is the end of a `while true`, say).
                try g.emit("hlt", .{});
            } else if (is_main) {
                try g.emit("ret 0", .{});
            } else {
                try g.emit("ret", .{});
            }
        }

        if (is_main) {
            // A main that returns nothing exits with status 0.
            try g.out.writeAll("export function w $main(");
        } else if (f.ret == .void) {
            try g.out.print("function ${s}(", .{f.name});
        } else {
            try g.out.print("function {c} ${s}(", .{ f.ret.base(), f.name });
        }
        for (f.params, 0..) |param, i| {
            if (i > 0) try g.out.writeAll(", ");
            try g.out.print("{c} %{s}", .{ param.sym.type.base(), param.name });
        }
        try g.out.writeAll(") {\n@start\n");
        try g.out.writeAll(g.allocs.written());
        try g.out.writeAll(g.code.written());
        try g.out.writeAll("}\n\n");
    }

    /// A global variable is data in the executable: `data $x = { l 5 }`.
    /// Without a value, it is that many zero bytes: `{ z 800 }`.
    fn genGlobal(g: *CodeGen, l: Stmt.Let) Error!void {
        const t = l.sym.type;
        try g.out.print("data ${s} = {{ ", .{l.name});
        if (l.value) |v| {
            const item: u8 = switch (t.size()) {
                1 => 'b',
                4 => 'w',
                else => 'l',
            };
            try g.out.print("{c} {f}", .{ item, try g.constant(v) });
        } else {
            try g.out.print("z {d}", .{t.size()});
        }
        try g.out.writeAll(" }\n\n");
    }

    /// The value of a constant expression (see isConstant in check.zig).
    fn constant(g: *CodeGen, e: *const Expr) Error!Value {
        return switch (e.kind) {
            .unary => |u| .{ .int = castInt(-(try g.constant(u.operand)).int, e.type) },
            else => g.genExpr(e),
        };
    }

    // ---- Statements ----

    fn genStmt(g: *CodeGen, s: *const Stmt) Error!void {
        switch (s.kind) {
            .let => |l| {
                const t = l.sym.type;
                if (l.value) |v| {
                    const value = try g.genExpr(v);
                    try g.emit("store{s} {f}, {f}", .{ storeSuffix(t), value, try g.declare(l.sym) });
                } else if (t == .array) {
                    // A variable without a value starts as all zeros.
                    try g.emit("call $memset(l {f}, w 0, l {d})", .{ try g.declare(l.sym), t.size() });
                } else {
                    try g.emit("store{s} 0, {f}", .{ storeSuffix(t), try g.declare(l.sym) });
                }
            },
            .assign => |a| {
                // Where first, then what: in `a[f()] = g()`, f runs first.
                const addr = try g.genAddr(a.target);
                const value = try g.genExpr(a.value);
                try g.emit("store{s} {f}, {f}", .{ storeSuffix(a.target.type), value, addr });
            },
            .expr => |e| _ = try g.genExpr(e),
            .@"if" => |i| {
                const id = g.nextId();
                const cond = try g.genExpr(i.cond);
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
                const cond = try g.genExpr(w.cond);
                try g.emit("jnz {f}, @while.{d}.body, @while.{d}.end", .{ cond, id, id });
                try g.label("@while.{d}.body", .{id});
                try g.loops.append(g.arena, id);
                try g.genBlock(w.body);
                _ = g.loops.pop();
                try g.emit("jmp @while.{d}.cond", .{id});
                try g.label("@while.{d}.end", .{id});
            },
            .@"break" => try g.emit("jmp @while.{d}.end", .{g.loops.getLast()}),
            .@"continue" => try g.emit("jmp @while.{d}.cond", .{g.loops.getLast()}),
            .@"return" => |value| {
                if (value) |e| {
                    try g.emit("ret {f}", .{try g.genExpr(e)});
                } else if (std.mem.eql(u8, g.func.name, "main")) {
                    try g.emit("ret 0", .{});
                } else {
                    try g.emit("ret", .{});
                }
            },
            .block => |b| try g.genBlock(b),
        }
    }

    fn genBlock(g: *CodeGen, b: ast.Block) Error!void {
        try g.genStmts(b.stmts);
    }

    fn genStmts(g: *CodeGen, stmts: []const *Stmt) Error!void {
        for (stmts) |s| try g.genStmt(s);
    }

    /// Makes a stack slot for a variable, as big as its type. QBE has
    /// alloc4, alloc8 and alloc16: the number is the alignment.
    fn declare(g: *CodeGen, sym: *const Symbol) Error!Value {
        const slot: Value = .{ .slot = sym };
        const t = sym.type;
        try g.allocs.writer.print("\t{f} =l alloc{d} {d}\n", .{ slot, @max(t.alignment(), 4), t.size() });
        return slot;
    }

    // ---- Expressions ----

    /// Emits the instructions that compute `e` and returns where the
    /// result is.
    fn genExpr(g: *CodeGen, e: *const Expr) Error!Value {
        const t = e.type;
        switch (e.kind) {
            .int => |n| return .{ .int = @intCast(n) },
            .char => |c| return .{ .int = c },
            .bool => |b| return .{ .int = @intFromBool(b) },
            .string => |s| {
                try g.strings.append(g.arena, s);
                return .{ .string = g.strings.items.len - 1 };
            },
            // A variable, `*p` and `a[i]` are all places in memory: work
            // out the address, then load from it.
            .name, .index => return g.result(t, "{s} {f}", .{ loadOp(t), try g.genAddr(e) }),
            .unary => |u| switch (u.op) {
                .neg => return g.result(t, "neg {f}", .{try g.genExpr(u.operand)}),
                .not => return g.result(t, "ceqw {f}, 0", .{try g.genExpr(u.operand)}),
                .addr => return g.genAddr(u.operand),
                .deref => return g.result(t, "{s} {f}", .{ loadOp(t), try g.genExpr(u.operand) }),
            },
            .binary => |b| return g.genBinary(e, b),
            .call => |c| return g.genCall(e, c),
            .field => unreachable, // the checker rejects these
            .cast => |c| return g.genCast(try g.genExpr(c.operand), c.operand.type, t),
        }
    }

    /// Emits the instructions that compute the address of a place: a
    /// variable, `*p` or `a[i]`.
    fn genAddr(g: *CodeGen, e: *const Expr) Error!Value {
        switch (e.kind) {
            .name => return .{ .slot = e.sym.? },
            // The address in p is the address of *p.
            .unary => |u| return g.genExpr(u.operand),
            .index => |ix| {
                // An array is the elements themselves, so its address is
                // the address of element 0. A pointer holds that address.
                const base = if (ix.base.type == .array) try g.genAddr(ix.base) else try g.genExpr(ix.base);
                const size: i64 = @intCast(e.type.size());
                const index = try g.genExpr(ix.index);
                if (index == .int) {
                    if (index.int == 0) return base;
                    return g.result(.i64, "add {f}, {d}", .{ base, index.int * size });
                }
                // Addresses are 64 bits; widen an i32 or u8 index first.
                var offset = switch (ix.index.type) {
                    .i64 => index,
                    .i32 => try g.result(.i64, "extsw {f}", .{index}),
                    else => try g.result(.i64, "extuw {f}", .{index}),
                };
                if (size != 1) offset = try g.result(.i64, "mul {f}, {d}", .{ offset, size });
                return g.result(.i64, "add {f}, {f}", .{ base, offset });
            },
            else => unreachable, // the checker only allows places
        }
    }

    fn genBinary(g: *CodeGen, e: *const Expr, b: Expr.Binary) Error!Value {
        if (b.op == .@"and" or b.op == .@"or") return g.genLogical(b);
        // The operands have the same type (the checker made sure).
        const t = b.lhs.type;
        const unsigned = t == .u8;
        const lhs = try g.genExpr(b.lhs);
        const rhs = try g.genExpr(b.rhs);
        if (b.op.isComparison()) {
            // Compare instructions name their operand type: csltw, ceql, ...
            const op: []const u8 = switch (b.op) {
                .eq => "ceq",
                .ne => "cne",
                .lt => if (unsigned) "cult" else "cslt",
                .le => if (unsigned) "cule" else "csle",
                .gt => if (unsigned) "cugt" else "csgt",
                .ge => if (unsigned) "cuge" else "csge",
                else => unreachable,
            };
            return g.result(.bool, "{s}{c} {f}, {f}", .{ op, t.base(), lhs, rhs });
        }
        const op: []const u8 = switch (b.op) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => if (unsigned) "udiv" else "div",
            .rem => if (unsigned) "urem" else "rem",
            else => unreachable,
        };
        const v = try g.result(e.type, "{s} {f}, {f}", .{ op, lhs, rhs });
        // A u8 lives in a 32-bit temporary; cut the result back to 8 bits
        // so that 200 + 100 is 44, as it would be in a byte.
        if (unsigned and (b.op == .add or b.op == .sub or b.op == .mul)) {
            return g.result(.u8, "and {f}, 255", .{v});
        }
        return v;
    }

    /// `a && b` and `a || b` only evaluate `b` when they need to, so they
    /// are control flow, not arithmetic. The result temporary is assigned
    /// on two paths; QBE turns that into SSA form for us.
    fn genLogical(g: *CodeGen, b: Expr.Binary) Error!Value {
        const id = g.nextId();
        const name = @tagName(b.op);
        const result_temp = g.newTemp();
        const lhs = try g.genExpr(b.lhs);
        try g.emit("{f} =w copy {f}", .{ result_temp, lhs });
        if (b.op == .@"and") {
            try g.emit("jnz {f}, @and.{d}.rhs, @and.{d}.end", .{ lhs, id, id });
        } else {
            try g.emit("jnz {f}, @or.{d}.end, @or.{d}.rhs", .{ lhs, id, id });
        }
        try g.label("@{s}.{d}.rhs", .{ name, id });
        const rhs = try g.genExpr(b.rhs);
        try g.emit("{f} =w copy {f}", .{ result_temp, rhs });
        try g.label("@{s}.{d}.end", .{ name, id });
        return result_temp;
    }

    /// `x as T`. The checker only allows integer and bool conversions.
    fn genCast(g: *CodeGen, v: Value, from: Type, to: Type) Error!Value {
        if (v == .int) return .{ .int = castInt(v.int, to) };
        if (to == .u8 and from != .u8 and from != .bool) return g.result(.u8, "and {f}, 255", .{v});
        if (to == .i64 and from != .i64) {
            // Widen: i32 copies its sign bit into the new high bits; u8
            // and bool are never negative, so they get zeros.
            return g.result(.i64, "{s} {f}", .{ if (from == .i32) "extsw" else "extuw", v });
        }
        // Narrow i64 to i32 by keeping the low 32 bits. (`=w copy` would
        // also do it, but when QBE 1.2 knows the value is a constant it
        // emits it untruncated, and the assembler warns.)
        if (to == .i32 and from == .i64) return g.result(.i32, "and {f}, 4294967295", .{v});
        // Everything else (u8 or bool to i32, ...) has the same bits.
        return v;
    }

    fn genCall(g: *CodeGen, e: *const Expr, c: Expr.Call) Error!Value {
        const f = c.callee.sym.?.func.?;
        const args = try g.arena.alloc(Value, c.args.len);
        for (c.args, args) |arg, *v| v.* = try g.genExpr(arg);

        try g.ensureBlock();
        const w = &g.code.writer;
        var t: Value = .{ .int = 0 };
        if (e.type == .void) {
            try w.print("\tcall ${s}(", .{f.name});
        } else {
            t = g.newTemp();
            try w.print("\t{f} ={c} call ${s}(", .{ t, e.type.base(), f.name });
        }
        const n = f.params.len;
        for (c.args, args, 0..) |arg, v, i| {
            if (i > 0) try w.writeAll(", ");
            // Variadic arguments come after a `...` marker.
            if (i == n) try w.writeAll("..., ");
            try w.print("{c} {f}", .{ arg.type.base(), v });
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

    /// Writes `%.N =w INSTRUCTION` (or `=l`, to fit type `t`) and returns `%.N`.
    fn result(g: *CodeGen, t: Type, comptime fmt: []const u8, args: anytype) Error!Value {
        const temp = g.newTemp();
        try g.emit("{f} ={c} " ++ fmt, .{ temp, t.base() } ++ args);
        return temp;
    }

    /// Writes one instruction.
    fn emit(g: *CodeGen, comptime fmt: []const u8, args: anytype) Error!void {
        try g.ensureBlock();
        try g.code.writer.print("\t" ++ fmt ++ "\n", args);
        const ends_block = comptime std.mem.startsWith(u8, fmt, "jmp") or
            std.mem.startsWith(u8, fmt, "jnz") or std.mem.startsWith(u8, fmt, "ret") or
            std.mem.startsWith(u8, fmt, "hlt");
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
};

/// The store instruction for a type: storeb, storew or storel.
fn storeSuffix(t: Type) []const u8 {
    return switch (t.size()) {
        1 => "b",
        4 => "w",
        else => "l",
    };
}

/// The load instruction for a type. `loadub` fills the upper 24 bits of
/// the temporary with zeros.
fn loadOp(t: Type) []const u8 {
    return switch (t.size()) {
        1 => "loadub",
        4 => "loadw",
        else => "loadl",
    };
}

/// Converts a constant at compile time, the way genCast would at run time.
fn castInt(n: i64, to: Type) i64 {
    return switch (to) {
        .u8 => @as(u8, @truncate(@as(u64, @bitCast(n)))),
        .i32 => @as(i32, @truncate(n)),
        else => n,
    };
}

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
