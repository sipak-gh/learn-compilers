//! Code generation: syntax tree in, QBE IL out.
const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Diagnostics = @import("diag.zig").Diagnostics;

pub const Error = error{ CodegenError, WriteFailed, OutOfMemory };

/// An operand of a QBE instruction: a constant or a temporary.
const Value = union(enum) {
    int: i64,
    temp: u32,

    pub fn format(v: Value, w: *Writer) Writer.Error!void {
        switch (v) {
            .int => |n| try w.print("{d}", .{n}),
            .temp => |t| try w.print("%t{d}", .{t}),
        }
    }
};

pub const CodeGen = struct {
    out: *Writer,
    diags: *Diagnostics,
    temps: u32 = 0,

    pub fn init(out: *Writer, diags: *Diagnostics) CodeGen {
        return .{ .out = out, .diags = diags };
    }

    /// A program is one expression; `main` prints its value.
    pub fn genProgram(g: *CodeGen, e: *const Expr) Error!void {
        try g.out.writeAll(
            \\data $fmt = { b "%ld\n", b 0 }
            \\
            \\export function w $main() {
            \\@start
            \\
        );
        const result = try g.genExpr(e);
        try g.out.print("\tcall $printf(l $fmt, ..., l {f})\n", .{result});
        try g.out.writeAll("\tret 0\n}\n");
    }

    /// Emits the instructions that compute `e` and returns where the
    /// result is: a constant, or the temporary that holds it.
    fn genExpr(g: *CodeGen, e: *const Expr) Error!Value {
        switch (e.kind) {
            .int => |n| return .{ .int = @intCast(n) },
            .char => |c| return .{ .int = c },
            .bool => |b| return .{ .int = @intFromBool(b) },
            .unary => |u| {
                const operand = try g.genExpr(u.operand);
                return switch (u.op) {
                    .neg => g.emit("neg", .{operand}),
                    .not => g.emit("ceql", .{ operand, Value{ .int = 0 } }),
                    .addr, .deref => g.unsupported(e, "pointers"),
                };
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
                    .@"and", .@"or" => return g.unsupported(e, "'&&' and '||'"),
                };
                const lhs = try g.genExpr(b.lhs);
                const rhs = try g.genExpr(b.rhs);
                return g.emit(op, .{ lhs, rhs });
            },
            .string => return g.unsupported(e, "strings"),
            .name => return g.unsupported(e, "names"),
            .call => return g.unsupported(e, "calls"),
            .index => return g.unsupported(e, "indexing"),
            .field => return g.unsupported(e, "fields"),
        }
    }

    /// Writes `%tN =l op a, b` and returns `%tN`.
    fn emit(g: *CodeGen, op: []const u8, operands: anytype) Error!Value {
        g.temps += 1;
        const result: Value = .{ .temp = g.temps };
        try g.out.print("\t{f} =l {s} ", .{ result, op });
        inline for (operands, 0..) |operand, i| {
            if (i > 0) try g.out.writeAll(", ");
            try g.out.print("{f}", .{operand});
        }
        try g.out.writeByte('\n');
        return result;
    }

    fn unsupported(g: *CodeGen, e: *const Expr, what: []const u8) Error {
        try g.diags.err(e.span, "pebc cannot compile {s} yet", .{what});
        return error.CodegenError;
    }
};
