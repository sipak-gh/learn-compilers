//! Chapter 2's compiler: still one pass, but it reads tokens instead of
//! characters and reports errors through `Diagnostics`.
//!
//!     expr    = term { ("+" | "-") term }
//!     term    = unary { ("*" | "/" | "%") unary }
//!     unary   = "-" unary | primary
//!     primary = INT | "(" expr ")"
const std = @import("std");
const Writer = std.Io.Writer;
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const diag = @import("diag.zig");
const Span = diag.Span;
const Diagnostics = diag.Diagnostics;

pub const Error = error{ SyntaxError, WriteFailed, OutOfMemory };

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

pub const Compiler = struct {
    src: []const u8,
    tokens: []const Token,
    /// The index of the next token to look at.
    index: usize = 0,
    out: *Writer,
    diags: *Diagnostics,
    temps: u32 = 0,

    pub fn init(src: []const u8, tokens: []const Token, out: *Writer, diags: *Diagnostics) Compiler {
        return .{ .src = src, .tokens = tokens, .out = out, .diags = diags };
    }

    pub fn compile(c: *Compiler) Error!void {
        try c.out.writeAll(
            \\data $fmt = { b "%ld\n", b 0 }
            \\
            \\export function w $main() {
            \\@start
            \\
        );
        const result = try c.expr();
        if (c.peek().tag != .eof) return c.fail("expected an operator, found {s}", .{c.peek().tag.describe()});
        try c.out.print("\tcall $printf(l $fmt, ..., l {f})\n", .{result});
        try c.out.writeAll("\tret 0\n}\n");
    }

    fn expr(c: *Compiler) Error!Value {
        var lhs = try c.term();
        while (true) {
            const op: []const u8 = switch (c.peek().tag) {
                .plus => "add",
                .minus => "sub",
                else => return lhs,
            };
            c.index += 1;
            const rhs = try c.term();
            lhs = try c.emit(op, lhs, rhs);
        }
    }

    fn term(c: *Compiler) Error!Value {
        var lhs = try c.unary();
        while (true) {
            const op: []const u8 = switch (c.peek().tag) {
                .star => "mul",
                .slash => "div",
                .percent => "rem",
                else => return lhs,
            };
            c.index += 1;
            const rhs = try c.unary();
            lhs = try c.emit(op, lhs, rhs);
        }
    }

    fn unary(c: *Compiler) Error!Value {
        if (c.peek().tag == .minus) {
            c.index += 1;
            const operand = try c.unary();
            return c.emit("sub", .{ .int = 0 }, operand);
        }
        return c.primary();
    }

    fn primary(c: *Compiler) Error!Value {
        const token = c.peek();
        switch (token.tag) {
            .int => {
                c.index += 1;
                const text = c.src[token.span.start..token.span.end];
                const n = lexer.intValue(text) catch |err| switch (err) {
                    error.Overflow => return c.failAt(token.span, "integer literal is too large", .{}),
                    error.InvalidCharacter => return c.failAt(token.span, "invalid integer literal '{s}'", .{text}),
                };
                if (n > std.math.maxInt(i64)) return c.failAt(token.span, "integer literal is too large", .{});
                return .{ .int = @intCast(n) };
            },
            .l_paren => {
                c.index += 1;
                const inner = try c.expr();
                if (c.peek().tag != .r_paren) return c.fail("expected ')', found {s}", .{c.peek().tag.describe()});
                c.index += 1;
                return inner;
            },
            else => return c.fail("expected an expression, found {s}", .{token.tag.describe()}),
        }
    }

    fn emit(c: *Compiler, op: []const u8, lhs: Value, rhs: Value) Error!Value {
        c.temps += 1;
        const result: Value = .{ .temp = c.temps };
        try c.out.print("\t{f} =l {s} {f}, {f}\n", .{ result, op, lhs, rhs });
        return result;
    }

    fn peek(c: *Compiler) Token {
        return c.tokens[c.index];
    }

    /// Reports an error at the next token.
    fn fail(c: *Compiler, comptime fmt: []const u8, args: anytype) Error {
        return c.failAt(c.peek().span, fmt, args);
    }

    fn failAt(c: *Compiler, span: Span, comptime fmt: []const u8, args: anytype) Error {
        try c.diags.err(span, fmt, args);
        return error.SyntaxError;
    }
};

/// Compiles `src` and returns the IL, or the rendered errors (test helper).
fn compileToString(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    const source: diag.Source = .{ .path = "t.peb", .text = src };
    var diags: Diagnostics = .init(arena, &source);
    const tokens = try lexer.tokenize(arena, src, &diags);
    var out: Writer.Allocating = .init(arena);
    var c: Compiler = .init(src, tokens, &out.writer, &diags);
    c.compile() catch |err| switch (err) {
        error.SyntaxError => {
            out.clearRetainingCapacity();
            try diags.render(&out.writer);
        },
        else => |e| return e,
    };
    return out.written();
}

test "precedence: * binds tighter than +" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const il = try compileToString(arena.allocator(), "1 + 2 * 3");
    try std.testing.expect(std.mem.find(u8, il, "%t1 =l mul 2, 3\n\t%t2 =l add 1, %t1\n") != null);
}

test "errors point at the offending token" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        \\t.peb:1:5: error: expected an expression, found '*'
        \\1 + * 2
        \\    ^
        \\
    , try compileToString(arena.allocator(), "1 + * 2"));
    try std.testing.expectEqualStrings(
        \\t.peb:1:1: error: integer literal is too large
        \\99999999999999999999
        \\^~~~~~~~~~~~~~~~~~~~
        \\
    , try compileToString(arena.allocator(), "99999999999999999999"));
}
