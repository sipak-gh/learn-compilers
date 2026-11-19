//! Constant folding: working out, while compiling, the value of every
//! expression that doesn't depend on the running program. `60 * 60 * 24`
//! becomes 86400, `-1 as u8` becomes 255, and `false && f()` becomes
//! false without calling f.
//!
//! The folder runs after the checker, so it knows every type. Like the
//! checker, it writes its results into the tree: `Expr.value` is the value
//! of an expression, if it is known. The code generator uses the values
//! (unless `pebc --no-fold`) and skips the branches of an `if` that can
//! never run.
//!
//! Knowing values also shows mistakes the checker couldn't see: a
//! division by a constant 0 and a constant index outside an array are
//! errors now, not crashes or wrong results at run time.
//!
//! A folded value must be exactly what the program would compute: the
//! arithmetic wraps around in 8, 32 or 64 bits the way the machine's does.
const std = @import("std");
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Type = @import("types.zig").Type;
const Diagnostics = @import("diag.zig").Diagnostics;

pub const Error = error{OutOfMemory};

pub const Folder = struct {
    diags: *Diagnostics,

    pub fn init(diags: *Diagnostics) Folder {
        return .{ .diags = diags };
    }

    pub fn foldProgram(f: *Folder, program: ast.Program) Error!void {
        for (program.decls) |decl| switch (decl) {
            .func => |func| if (func.body) |body| try f.foldBlock(body),
            .global => |s| try f.foldStmt(s),
            .@"struct" => {},
        };
    }

    fn foldBlock(f: *Folder, b: ast.Block) Error!void {
        for (b.stmts) |s| try f.foldStmt(s);
    }

    fn foldStmt(f: *Folder, s: *Stmt) Error!void {
        switch (s.kind) {
            .let => |l| if (l.value) |v| try f.foldExpr(v),
            .assign => |a| {
                try f.foldExpr(a.target);
                try f.foldExpr(a.value);
            },
            .expr => |e| try f.foldExpr(e),
            .@"if" => |i| {
                try f.foldExpr(i.cond);
                try f.foldBlock(i.then);
                if (i.@"else") |e| try f.foldStmt(e);
            },
            .@"while" => |w| {
                try f.foldExpr(w.cond);
                try f.foldBlock(w.body);
            },
            .@"break", .@"continue" => {},
            .@"return" => |value| if (value) |e| try f.foldExpr(e),
            .block => |b| try f.foldBlock(b),
        }
    }

    /// Folds the parts of `e`, then `e` itself.
    fn foldExpr(f: *Folder, e: *Expr) Error!void {
        e.value = switch (e.kind) {
            // The checker made sure that a literal fits its type.
            .int => |n| @intCast(n),
            .char => |c| c,
            .bool => |b| @intFromBool(b),
            .null => 0,
            .string, .name, .sizeof => null,
            .unary => |u| blk: {
                try f.foldExpr(u.operand);
                const v = u.operand.value orelse break :blk null;
                break :blk switch (u.op) {
                    .neg => castInt(0 -% v, e.type),
                    .not => @intFromBool(v == 0),
                    .addr, .deref => null,
                };
            },
            .binary => |b| try f.foldBinary(e, b),
            .call => |c| blk: {
                for (c.args) |arg| try f.foldExpr(arg);
                break :blk null;
            },
            .index => |ix| blk: {
                try f.foldExpr(ix.base);
                try f.foldExpr(ix.index);
                if (ix.base.type == .array) if (ix.index.value) |i| {
                    if (i < 0 or i >= ix.base.type.array.len) {
                        try f.diags.err(ix.index.span, "index {d} is out of bounds for '{f}'", .{ i, ix.base.type });
                    }
                };
                break :blk null;
            },
            .field => |field| blk: {
                try f.foldExpr(field.base);
                break :blk null;
            },
            .cast => |c| blk: {
                try f.foldExpr(c.operand);
                const v = c.operand.value orelse break :blk null;
                break :blk castInt(v, e.type);
            },
        };
    }

    fn foldBinary(f: *Folder, e: *const Expr, b: Expr.Binary) Error!?i64 {
        try f.foldExpr(b.lhs);
        try f.foldExpr(b.rhs);
        switch (b.op) {
            // `false && x` is false and `true || x` is true, whatever x is
            // (x is never even evaluated). Otherwise the result is x.
            .@"and" => {
                const lhs = b.lhs.value orelse return null;
                return if (lhs == 0) 0 else b.rhs.value;
            },
            .@"or" => {
                const lhs = b.lhs.value orelse return null;
                return if (lhs == 1) 1 else b.rhs.value;
            },
            // Dividing by 0 is a mistake even if the left side is unknown.
            .div, .rem => if (b.rhs.value == 0) {
                try f.diags.err(b.rhs.span, "division by zero", .{});
                return null;
            },
            else => {},
        }
        const lhs = b.lhs.value orelse return null;
        const rhs = b.rhs.value orelse return null;
        const t = b.lhs.type;
        return switch (b.op) {
            .add => castInt(lhs +% rhs, t),
            .sub => castInt(lhs -% rhs, t),
            .mul => castInt(lhs *% rhs, t),
            .div, .rem => {
                // The smallest value divided by -1 is one more than the
                // largest: the processor's division instruction traps.
                if (rhs == -1 and lhs == minValue(t)) {
                    try f.diags.err(e.span, "{d} {s} -1 overflows '{f}'", .{ lhs, b.op.symbol(), t });
                    return null;
                }
                // Division rounds toward zero, as on the machine.
                return if (b.op == .div) @divTrunc(lhs, rhs) else @rem(lhs, rhs);
            },
            // A u8 is kept between 0 and 255, so comparing the i64 values
            // gives the right answer for every type.
            .eq => @intFromBool(lhs == rhs),
            .ne => @intFromBool(lhs != rhs),
            .lt => @intFromBool(lhs < rhs),
            .le => @intFromBool(lhs <= rhs),
            .gt => @intFromBool(lhs > rhs),
            .ge => @intFromBool(lhs >= rhs),
            .@"and", .@"or" => unreachable,
        };
    }
};

/// Converts a value to type `to` the way the machine does: an i32 keeps
/// the low 32 bits (sign-extended back to 64), a u8 the low 8 bits.
pub fn castInt(n: i64, to: Type) i64 {
    return switch (to) {
        .u8 => @as(u8, @truncate(@as(u64, @bitCast(n)))),
        .i32 => @as(i32, @truncate(n)),
        else => n,
    };
}

fn minValue(t: Type) i64 {
    return switch (t) {
        .i32 => std.math.minInt(i32),
        .i64 => std.math.minInt(i64),
        else => 0,
    };
}

/// Checks and folds `fn main() { DECLS }` and returns the value of the
/// last `let`.
fn foldValue(arena: std.mem.Allocator, comptime decl: []const u8) !?i64 {
    const diag = @import("diag.zig");
    const lexer = @import("lexer.zig");
    const src = "fn main() { " ++ decl ++ " }";
    const source: diag.Source = .{ .path = "t.peb", .text = src };
    var diags: Diagnostics = .init(arena, &source);
    var parser: @import("parser.zig").Parser = .init(arena, src, try lexer.tokenize(arena, src, &diags), &diags);
    const program = try parser.parseProgram();
    var checker: @import("check.zig").Checker = .init(arena, &diags);
    try checker.checkProgram(program);
    var folder: Folder = .init(&diags);
    try folder.foldProgram(program);
    try std.testing.expect(!diags.hasErrors());
    const stmts = program.decls[0].func.body.?.stmts;
    return stmts[stmts.len - 1].kind.let.value.?.value;
}

test "folding computes what the machine would" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expectValue = struct {
        fn f(want: ?i64, got: ?i64) !void {
            try std.testing.expectEqual(want, got);
        }
    }.f;
    try expectValue(86400, try foldValue(a, "let x = 60 * 60 * 24;"));
    // Wrapping around in the type's number of bits.
    try expectValue(44, try foldValue(a, "let x: u8 = 200 + 100;"));
    try expectValue(-2147483648, try foldValue(a, "let x: i32 = 2147483647 + 1;"));
    try expectValue(255, try foldValue(a, "let x = -1 as u8;"));
    try expectValue(-1, try foldValue(a, "let x = 4294967295 as i32;"));
    // Division rounds toward zero; the remainder has the sign of the left side.
    try expectValue(-3, try foldValue(a, "let x = -7 / 2;"));
    try expectValue(-1, try foldValue(a, "let x = -7 % 2;"));
    try expectValue(1, try foldValue(a, "let x = 200 as u8 > 100;"));
    try expectValue(0, try foldValue(a, "let x = false && 1 / 1 == 1;"));
    // Not everything is known.
    try expectValue(null, try foldValue(a, "var x = 1; let y = x + 1;"));
}
