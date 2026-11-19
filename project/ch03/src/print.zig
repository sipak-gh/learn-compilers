//! Prints syntax trees as S-expressions: `1 + 2 * 3` becomes
//! `(+ 1 (* 2 3))`. `pebc ast` and the parser tests use it.
const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("ast.zig");
const Expr = ast.Expr;

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
