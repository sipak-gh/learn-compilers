//! The parser: tokens in, syntax tree out.
//!
//! Expressions use precedence climbing (a Pratt parser). From loosest to
//! tightest:
//!
//!     ||
//!     &&
//!     ==  !=  <  <=  >  >=     (no chaining: a < b < c is an error)
//!     +  -
//!     *  /  %
//!     -x  !x  &x  *x           (prefix)
//!     f(x)  a[i]  p.x          (postfix)
const std = @import("std");
const ast = @import("ast.zig");
const Expr = ast.Expr;
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const diag = @import("diag.zig");
const Span = diag.Span;
const Diagnostics = diag.Diagnostics;

pub const Error = error{ ParseError, OutOfMemory };

/// How tightly a binary operator binds. Higher binds tighter.
const Prec = enum(u8) { lowest, @"or", @"and", compare, add, mul };

fn binaryOp(tag: Token.Tag) ?ast.BinaryOp {
    return switch (tag) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .rem,
        .equal_equal => .eq,
        .bang_equal => .ne,
        .less => .lt,
        .less_equal => .le,
        .greater => .gt,
        .greater_equal => .ge,
        .amp_amp => .@"and",
        .pipe_pipe => .@"or",
        else => null,
    };
}

fn precedence(op: ast.BinaryOp) Prec {
    return switch (op) {
        .@"or" => .@"or",
        .@"and" => .@"and",
        .eq, .ne, .lt, .le, .gt, .ge => .compare,
        .add, .sub => .add,
        .mul, .div, .rem => .mul,
    };
}

pub const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    tokens: []const Token,
    index: usize = 0,
    diags: *Diagnostics,

    pub fn init(arena: std.mem.Allocator, src: []const u8, tokens: []const Token, diags: *Diagnostics) Parser {
        return .{ .arena = arena, .src = src, .tokens = tokens, .diags = diags };
    }

    /// A whole program, which for now is one expression.
    pub fn parseProgram(p: *Parser) Error!*Expr {
        const e = try p.parseExpr();
        _ = try p.expect(.eof, "end of file");
        return e;
    }

    pub fn parseExpr(p: *Parser) Error!*Expr {
        return p.expression(.lowest);
    }

    /// Parses operators that bind tighter than `min`, left to right.
    fn expression(p: *Parser, min: Prec) Error!*Expr {
        var lhs = try p.prefix();
        while (binaryOp(p.peek().tag)) |op| {
            const prec = precedence(op);
            if (@backingInt(prec) <= @backingInt(min)) break;
            const op_token = p.advance();
            // The right side only takes operators that bind tighter than
            // this one, which makes `1 - 2 - 3` group as `(1 - 2) - 3`.
            const rhs = try p.expression(prec);
            lhs = try p.node(lhs.span.to(rhs.span), .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } });
            if (op.isComparison()) {
                if (binaryOp(p.peek().tag)) |next| if (next.isComparison()) {
                    try p.diags.err(p.peek().span, "comparison operators cannot be chained", .{});
                    try p.diags.add(.note, op_token.span, "use && to combine two comparisons", .{});
                    return error.ParseError;
                };
            }
        }
        return lhs;
    }

    /// Prefix operators, then a primary expression and its postfix operators.
    fn prefix(p: *Parser) Error!*Expr {
        const op: ast.UnaryOp = switch (p.peek().tag) {
            .minus => .neg,
            .bang => .not,
            .amp => .addr,
            .star => .deref,
            else => return p.postfix(try p.primary()),
        };
        const op_token = p.advance();
        const operand = try p.prefix();
        return p.node(op_token.span.to(operand.span), .{ .unary = .{ .op = op, .operand = operand } });
    }

    fn postfix(p: *Parser, start: *Expr) Error!*Expr {
        var e = start;
        while (true) {
            switch (p.peek().tag) {
                .l_paren => {
                    _ = p.advance();
                    var args: std.ArrayList(*Expr) = .empty;
                    while (p.peek().tag != .r_paren) {
                        try args.append(p.arena, try p.parseExpr());
                        if (p.peek().tag != .comma) break;
                        _ = p.advance();
                    }
                    const close = try p.expect(.r_paren, "')'");
                    e = try p.node(e.span.to(close.span), .{ .call = .{ .callee = e, .args = args.items } });
                },
                .l_bracket => {
                    _ = p.advance();
                    const index = try p.parseExpr();
                    const close = try p.expect(.r_bracket, "']'");
                    e = try p.node(e.span.to(close.span), .{ .index = .{ .base = e, .index = index } });
                },
                .dot => {
                    _ = p.advance();
                    const name = try p.expect(.identifier, "a field name");
                    e = try p.node(e.span.to(name.span), .{ .field = .{ .base = e, .name = p.text(name), .name_span = name.span } });
                },
                else => return e,
            }
        }
    }

    fn primary(p: *Parser) Error!*Expr {
        const token = p.advance();
        switch (token.tag) {
            .int => {
                const value = lexer.intValue(p.text(token)) catch |err| switch (err) {
                    error.Overflow => return p.failAt(token.span, "integer literal is too large", .{}),
                    error.InvalidCharacter => return p.failAt(token.span, "invalid integer literal '{s}'", .{p.text(token)}),
                };
                if (value > std.math.maxInt(i64)) return p.failAt(token.span, "integer literal is too large", .{});
                return p.node(token.span, .{ .int = value });
            },
            .char => {
                const bytes = try lexer.unescape(p.arena, p.text(token));
                return p.node(token.span, .{ .char = bytes[0] });
            },
            .string => return p.node(token.span, .{ .string = try lexer.unescape(p.arena, p.text(token)) }),
            .kw_true => return p.node(token.span, .{ .bool = true }),
            .kw_false => return p.node(token.span, .{ .bool = false }),
            .identifier => return p.node(token.span, .{ .name = p.text(token) }),
            .l_paren => {
                const inner = try p.parseExpr();
                _ = try p.expect(.r_paren, "')'");
                return inner;
            },
            // The lexer has already reported this one.
            .invalid => return error.ParseError,
            else => return p.failAt(token.span, "expected an expression, found {s}", .{token.tag.describe()}),
        }
    }

    fn node(p: *Parser, span: Span, kind: Expr.Kind) Error!*Expr {
        const e = try p.arena.create(Expr);
        e.* = .{ .span = span, .kind = kind };
        return e;
    }

    fn peek(p: *Parser) Token {
        return p.tokens[p.index];
    }

    fn advance(p: *Parser) Token {
        const token = p.tokens[p.index];
        if (token.tag != .eof) p.index += 1;
        return token;
    }

    /// Consumes a token of kind `tag`, or reports "expected WHAT".
    fn expect(p: *Parser, tag: Token.Tag, what: []const u8) Error!Token {
        const token = p.peek();
        if (token.tag == tag) return p.advance();
        if (token.tag == .invalid) return error.ParseError;
        return p.failAt(token.span, "expected {s}, found {s}", .{ what, token.tag.describe() });
    }

    fn text(p: *Parser, token: Token) []const u8 {
        return p.src[token.span.start..token.span.end];
    }

    fn failAt(p: *Parser, span: Span, comptime fmt: []const u8, args: anytype) Error {
        try p.diags.err(span, fmt, args);
        return error.ParseError;
    }
};

/// Parses `src` and prints the tree, or the error messages (test helper).
fn parseToString(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    const source: diag.Source = .{ .path = "t.peb", .text = src };
    var diags: Diagnostics = .init(arena, &source);
    const tokens = try lexer.tokenize(arena, src, &diags);
    var out: std.Io.Writer.Allocating = .init(arena);
    var parser: Parser = .init(arena, src, tokens, &diags);
    if (parser.parseProgram()) |tree| {
        try @import("print.zig").writeExpr(&out.writer, tree);
    } else |_| {
        try diags.render(&out.writer);
    }
    return out.written();
}

fn expectTree(src: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(expected, try parseToString(arena.allocator(), src));
}

test "precedence and associativity" {
    try expectTree("1 + 2 * 3", "(+ 1 (* 2 3))");
    try expectTree("1 - 2 - 3", "(- (- 1 2) 3)");
    try expectTree("a || b && c == d + e * f", "(|| a (&& b (== c (+ d (* e f)))))");
    try expectTree("(1 + 2) * 3", "(* (+ 1 2) 3)");
}

test "prefix and postfix operators" {
    try expectTree("-x.y", "(- (. x y))");
    try expectTree("*p[2]", "(* (index p 2))");
    try expectTree("!f(1, g(2))", "(! (call f 1 (call g 2)))");
    try expectTree("&a[i].b", "(& (. (index a i) b))");
}

test "comparisons do not chain" {
    try expectTree("a < b < c",
        \\t.peb:1:7: error: comparison operators cannot be chained
        \\a < b < c
        \\      ^
        \\t.peb:1:3: note: use && to combine two comparisons
        \\a < b < c
        \\  ^
        \\
    );
}
