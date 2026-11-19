//! Chapter 1's compiler: one pass, straight from characters to QBE IL.
//!
//! The input is a single integer expression. The output is a QBE program
//! whose `main` computes the expression and prints it with printf.
//!
//!     expr    = term { ("+" | "-") term }
//!     term    = unary { ("*" | "/" | "%") unary }
//!     unary   = "-" unary | primary
//!     primary = NUMBER | "(" expr ")"
const std = @import("std");
const Writer = std.Io.Writer;

pub const Error = error{ SyntaxError, WriteFailed };

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
    pos: usize = 0,
    out: *Writer,
    /// The number of temporaries created so far.
    temps: u32 = 0,
    /// Where the first syntax error happened, and why.
    err_pos: usize = 0,
    err_msg: []const u8 = "",

    pub fn init(src: []const u8, out: *Writer) Compiler {
        return .{ .src = src, .out = out };
    }

    /// Compiles the whole program.
    pub fn compile(c: *Compiler) Error!void {
        try c.out.writeAll(
            \\data $fmt = { b "%ld\n", b 0 }
            \\
            \\export function w $main() {
            \\@start
            \\
        );
        const result = try c.expr();
        c.skipSpace();
        if (c.pos < c.src.len) return c.fail("expected an operator");
        try c.out.print("\tcall $printf(l $fmt, ..., l {f})\n", .{result});
        try c.out.writeAll("\tret 0\n}\n");
    }

    fn expr(c: *Compiler) Error!Value {
        var lhs = try c.term();
        while (true) {
            const op: []const u8 = switch (c.peek()) {
                '+' => "add",
                '-' => "sub",
                else => return lhs,
            };
            c.pos += 1;
            const rhs = try c.term();
            lhs = try c.emit(op, lhs, rhs);
        }
    }

    fn term(c: *Compiler) Error!Value {
        var lhs = try c.unary();
        while (true) {
            const op: []const u8 = switch (c.peek()) {
                '*' => "mul",
                '/' => "div",
                '%' => "rem",
                else => return lhs,
            };
            c.pos += 1;
            const rhs = try c.unary();
            lhs = try c.emit(op, lhs, rhs);
        }
    }

    fn unary(c: *Compiler) Error!Value {
        if (c.peek() == '-') {
            c.pos += 1;
            const operand = try c.unary();
            return c.emit("sub", .{ .int = 0 }, operand);
        }
        return c.primary();
    }

    fn primary(c: *Compiler) Error!Value {
        switch (c.peek()) {
            '0'...'9' => {
                const start = c.pos;
                while (c.pos < c.src.len and std.ascii.isDigit(c.src[c.pos])) c.pos += 1;
                const n = std.fmt.parseInt(i64, c.src[start..c.pos], 10) catch {
                    c.pos = start;
                    return c.fail("number too large");
                };
                return .{ .int = n };
            },
            '(' => {
                c.pos += 1;
                const inner = try c.expr();
                if (c.peek() != ')') return c.fail("expected ')'");
                c.pos += 1;
                return inner;
            },
            else => return c.fail("expected a number or '('"),
        }
    }

    /// Writes `%tN =l op lhs, rhs` and returns the new temporary.
    fn emit(c: *Compiler, op: []const u8, lhs: Value, rhs: Value) Error!Value {
        c.temps += 1;
        const result: Value = .{ .temp = c.temps };
        try c.out.print("\t{f} =l {s} {f}, {f}\n", .{ result, op, lhs, rhs });
        return result;
    }

    /// Skips whitespace, then returns the next character (0 at the end).
    fn peek(c: *Compiler) u8 {
        c.skipSpace();
        return if (c.pos < c.src.len) c.src[c.pos] else 0;
    }

    fn skipSpace(c: *Compiler) void {
        while (c.pos < c.src.len and std.ascii.isWhitespace(c.src[c.pos])) c.pos += 1;
    }

    fn fail(c: *Compiler, msg: []const u8) error{SyntaxError} {
        c.err_pos = c.pos;
        c.err_msg = msg;
        return error.SyntaxError;
    }
};

/// Compiles `src` and returns the IL (test helper).
fn compileToString(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var c: Compiler = .init(src, &out.writer);
    try c.compile();
    return out.toOwnedSlice();
}

test "precedence: * binds tighter than +" {
    const il = try compileToString(std.testing.allocator, "1 + 2 * 3");
    defer std.testing.allocator.free(il);
    try std.testing.expect(std.mem.find(u8, il, "%t1 =l mul 2, 3\n\t%t2 =l add 1, %t1\n") != null);
}

test "parentheses and unary minus" {
    const il = try compileToString(std.testing.allocator, "-(1 - 2)");
    defer std.testing.allocator.free(il);
    try std.testing.expect(std.mem.find(u8, il, "%t1 =l sub 1, 2\n\t%t2 =l sub 0, %t1\n") != null);
}

test "syntax errors report a position" {
    var discard: Writer.Discarding = .init(&.{});
    var c: Compiler = .init("1 + * 2", &discard.writer);
    try std.testing.expectError(error.SyntaxError, c.compile());
    try std.testing.expectEqual(4, c.err_pos);
    try std.testing.expectEqualStrings("expected a number or '('", c.err_msg);
}
