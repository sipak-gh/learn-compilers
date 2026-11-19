//! Prints syntax trees as S-expressions: `1 + 2 * 3` becomes
//! `(+ 1 (* 2 3))`. `pebc ast` and the parser tests use it. Statements go
//! on their own lines, indented by nesting depth.
const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;

pub fn writeProgram(w: *Writer, program: ast.Program) Writer.Error!void {
    for (program.decls) |decl| switch (decl) {
        .func => |f| try writeFunc(w, f),
    };
}

fn writeFunc(w: *Writer, f: *const ast.Func) Writer.Error!void {
    try w.print("({s}fn {s} (", .{ if (f.body == null) "extern " else "", f.name });
    for (f.params, 0..) |param, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(param.name);
    }
    if (f.variadic) try w.writeAll(if (f.params.len > 0) " ..." else "...");
    try w.writeByte(')');
    if (f.body) |body| for (body.stmts) |s| try writeStmt(w, s, 1);
    try w.writeAll(")\n");
}

fn writeStmt(w: *Writer, s: *const Stmt, depth: usize) Writer.Error!void {
    try w.writeByte('\n');
    try w.splatByteAll(' ', 2 * depth);
    switch (s.kind) {
        .let => |l| {
            try w.print("({s} {s} ", .{ if (l.mutable) "var" else "let", l.name });
            try writeExpr(w, l.value);
        },
        .assign => |a| {
            try w.writeAll("(= ");
            try writeExpr(w, a.target);
            try w.writeByte(' ');
            try writeExpr(w, a.value);
        },
        .expr => |e| return writeExpr(w, e),
        .@"if" => |i| {
            try w.writeAll("(if ");
            try writeExpr(w, i.cond);
            try writeBlock(w, i.then, depth + 1);
            if (i.@"else") |e| try writeStmt(w, e, depth + 1);
        },
        .@"while" => |wh| {
            try w.writeAll("(while ");
            try writeExpr(w, wh.cond);
            try writeBlock(w, wh.body, depth + 1);
        },
        .@"break" => try w.writeAll("(break"),
        .@"continue" => try w.writeAll("(continue"),
        .@"return" => |value| {
            try w.writeAll("(return");
            if (value) |v| {
                try w.writeByte(' ');
                try writeExpr(w, v);
            }
        },
        .block => |b| {
            try w.writeAll("(block");
            for (b.stmts) |child| try writeStmt(w, child, depth + 1);
        },
    }
    try w.writeByte(')');
}

fn writeBlock(w: *Writer, b: ast.Block, depth: usize) Writer.Error!void {
    try w.writeByte('\n');
    try w.splatByteAll(' ', 2 * depth);
    try w.writeAll("(block");
    for (b.stmts) |child| try writeStmt(w, child, depth + 1);
    try w.writeByte(')');
}

pub fn writeExpr(w: *Writer, e: *const Expr) Writer.Error!void {
    switch (e.kind) {
        .int => |n| try w.print("{d}", .{n}),
        .char => |c| {
            try w.writeByte('\'');
            try writeEscaped(w, &.{c});
            try w.writeByte('\'');
        },
        .string => |s| {
            try w.writeByte('"');
            try writeEscaped(w, s);
            try w.writeByte('"');
        },
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .name => |name| try w.writeAll(name),
        .unary => |u| {
            try w.print("({s} ", .{u.op.symbol()});
            try writeExpr(w, u.operand);
            try w.writeByte(')');
        },
        .binary => |b| {
            try w.print("({s} ", .{b.op.symbol()});
            try writeExpr(w, b.lhs);
            try w.writeByte(' ');
            try writeExpr(w, b.rhs);
            try w.writeByte(')');
        },
        .call => |c| {
            try w.writeAll("(call ");
            try writeExpr(w, c.callee);
            for (c.args) |arg| {
                try w.writeByte(' ');
                try writeExpr(w, arg);
            }
            try w.writeByte(')');
        },
        .index => |i| {
            try w.writeAll("(index ");
            try writeExpr(w, i.base);
            try w.writeByte(' ');
            try writeExpr(w, i.index);
            try w.writeByte(')');
        },
        .field => |f| {
            try w.writeAll("(. ");
            try writeExpr(w, f.base);
            try w.print(" {s})", .{f.name});
        },
    }
}

/// Writes bytes the way they would appear inside a Pebble literal.
fn writeEscaped(w: *Writer, bytes: []const u8) Writer.Error!void {
    for (bytes) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0 => try w.writeAll("\\0"),
        '\\', '\'', '"' => try w.print("\\{c}", .{c}),
        else => try w.writeByte(c),
    };
}
