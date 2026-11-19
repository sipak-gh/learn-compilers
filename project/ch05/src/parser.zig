//! The parser: tokens in, syntax tree out.
//!
//!     program   = { decl } EOF
//!     decl      = "fn" NAME params [ type ] block
//!               | "extern" "fn" NAME params [ type ] ";"
//!     params    = "(" [ param { "," param } [ "," "..." ] ] ")"
//!     param     = NAME ":" type
//!     type      = NAME | "*" type
//!     block     = "{" { stmt } "}"
//!     stmt      = ("let" | "var") NAME [ ":" type ] "=" expr ";"
//!               | "if" expr block [ "else" ( block | if-stmt ) ]
//!               | "while" expr block
//!               | "break" ";" | "continue" ";"
//!               | "return" [ expr ] ";"
//!               | block
//!               | expr [ "=" expr ] ";"
//!
//! Expressions use precedence climbing (a Pratt parser). From loosest to
//! tightest:
//!
//!     ||
//!     &&
//!     ==  !=  <  <=  >  >=     (no chaining: a < b < c is an error)
//!     +  -
//!     *  /  %
//!     as                       (x as T)
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
const Prec = enum(u8) { lowest, @"or", @"and", compare, add, mul, cast };

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

    /// Parses the whole file. After a syntax error the parser skips ahead
    /// to a place where it can start again, so one run reports as many
    /// errors as possible. The caller checks `diags` before using the tree.
    pub fn parseProgram(p: *Parser) error{OutOfMemory}!ast.Program {
        var decls: std.ArrayList(ast.Decl) = .empty;
        while (p.peek().tag != .eof) {
            const start = p.index;
            const decl = p.declaration() catch |err| switch (err) {
                error.ParseError => {
                    p.skipToDeclaration(start);
                    continue;
                },
                error.OutOfMemory => |e| return e,
            };
            try decls.append(p.arena, decl);
        }
        return .{ .decls = decls.items };
    }

    fn declaration(p: *Parser) Error!ast.Decl {
        switch (p.peek().tag) {
            .kw_fn, .kw_extern => return .{ .func = try p.function() },
            else => return p.failAt(p.peek().span, "expected a declaration, found {s}", .{p.peek().tag.describe()}),
        }
    }

    fn function(p: *Parser) Error!*ast.Func {
        const is_extern = p.peek().tag == .kw_extern;
        if (is_extern) _ = p.advance();
        _ = try p.expect(.kw_fn, "'fn'");
        const name = try p.expect(.identifier, "a function name");
        _ = try p.expect(.l_paren, "'('");
        var params: std.ArrayList(ast.Param) = .empty;
        var variadic = false;
        while (p.peek().tag != .r_paren) {
            if (p.peek().tag == .ellipsis) {
                const dots = p.advance();
                if (!is_extern) return p.failAt(dots.span, "only extern functions can be variadic", .{});
                variadic = true;
                break;
            }
            const param = try p.expect(.identifier, "a parameter name");
            _ = try p.expect(.colon, "':'");
            const ty = try p.parseType();
            try params.append(p.arena, .{ .name = p.text(param), .span = param.span, .type = ty });
            if (p.peek().tag != .comma) break;
            _ = p.advance();
        }
        _ = try p.expect(.r_paren, "')'");
        const return_type = switch (p.peek().tag) {
            .l_brace, .semicolon => null,
            else => try p.parseType(),
        };
        const f = try p.arena.create(ast.Func);
        f.* = .{
            .name = p.text(name),
            .name_span = name.span,
            .params = params.items,
            .variadic = variadic,
            .return_type = return_type,
            .body = null,
        };
        if (is_extern) {
            _ = try p.expect(.semicolon, "';'");
        } else {
            f.body = try p.block();
        }
        return f;
    }

    fn block(p: *Parser) Error!ast.Block {
        _ = try p.expect(.l_brace, "'{'");
        var stmts: std.ArrayList(*ast.Stmt) = .empty;
        while (p.peek().tag != .r_brace and p.peek().tag != .eof) {
            const start = p.index;
            const stmt = p.statement() catch |err| switch (err) {
                error.ParseError => {
                    p.skipToStatement(start);
                    continue;
                },
                error.OutOfMemory => |e| return e,
            };
            try stmts.append(p.arena, stmt);
        }
        const close = try p.expect(.r_brace, "'}'");
        return .{ .stmts = stmts.items, .end = close.span };
    }

    fn statement(p: *Parser) Error!*ast.Stmt {
        const first = p.peek();
        switch (first.tag) {
            .kw_let, .kw_var => {
                _ = p.advance();
                const name = try p.expect(.identifier, "a variable name");
                var ty: ?*ast.TypeExpr = null;
                if (p.peek().tag == .colon) {
                    _ = p.advance();
                    ty = try p.parseType();
                }
                _ = try p.expect(.equal, "'='");
                const value = try p.parseExpr();
                const semi = try p.expect(.semicolon, "';'");
                return p.newStmt(first.span.to(semi.span), .{ .let = .{
                    .mutable = first.tag == .kw_var,
                    .name = p.text(name),
                    .name_span = name.span,
                    .type = ty,
                    .value = value,
                } });
            },
            .kw_if => return p.ifStatement(),
            .kw_while => {
                _ = p.advance();
                const cond = try p.parseExpr();
                const body = try p.block();
                return p.newStmt(first.span.to(body.end), .{ .@"while" = .{ .cond = cond, .body = body } });
            },
            .kw_break, .kw_continue => {
                _ = p.advance();
                const semi = try p.expect(.semicolon, "';'");
                const kind: ast.Stmt.Kind = if (first.tag == .kw_break) .@"break" else .@"continue";
                return p.newStmt(first.span.to(semi.span), kind);
            },
            .kw_return => {
                _ = p.advance();
                const value = if (p.peek().tag == .semicolon) null else try p.parseExpr();
                const semi = try p.expect(.semicolon, "';'");
                return p.newStmt(first.span.to(semi.span), .{ .@"return" = value });
            },
            .l_brace => {
                const b = try p.block();
                return p.newStmt(first.span.to(b.end), .{ .block = b });
            },
            else => {
                const e = try p.parseExpr();
                if (p.peek().tag == .equal) {
                    _ = p.advance();
                    const value = try p.parseExpr();
                    const semi = try p.expect(.semicolon, "';'");
                    return p.newStmt(e.span.to(semi.span), .{ .assign = .{ .target = e, .value = value } });
                }
                const semi = try p.expect(.semicolon, "';'");
                return p.newStmt(e.span.to(semi.span), .{ .expr = e });
            },
        }
    }

    fn parseType(p: *Parser) Error!*ast.TypeExpr {
        const token = p.peek();
        const kind: ast.TypeExpr.Kind = switch (token.tag) {
            .identifier => .{ .name = p.text(token) },
            .star => {
                _ = p.advance();
                const pointee = try p.parseType();
                return p.typeNode(token.span.to(pointee.span), .{ .pointer = pointee });
            },
            else => return p.failAt(token.span, "expected a type, found {s}", .{token.tag.describe()}),
        };
        _ = p.advance();
        return p.typeNode(token.span, kind);
    }

    fn typeNode(p: *Parser, span: Span, kind: ast.TypeExpr.Kind) Error!*ast.TypeExpr {
        const t = try p.arena.create(ast.TypeExpr);
        t.* = .{ .span = span, .kind = kind };
        return t;
    }

    fn ifStatement(p: *Parser) Error!*ast.Stmt {
        const if_token = try p.expect(.kw_if, "'if'");
        const cond = try p.parseExpr();
        const then = try p.block();
        var end = then.end;
        var else_branch: ?*ast.Stmt = null;
        if (p.peek().tag == .kw_else) {
            _ = p.advance();
            if (p.peek().tag == .kw_if) {
                else_branch = try p.ifStatement();
            } else {
                const open = p.peek();
                const b = try p.block();
                else_branch = try p.newStmt(open.span.to(b.end), .{ .block = b });
            }
            end = else_branch.?.span;
        }
        return p.newStmt(if_token.span.to(end), .{ .@"if" = .{ .cond = cond, .then = then, .@"else" = else_branch } });
    }

    /// Error recovery inside a block: skip past the next `;` or `{...}`
    /// group, or up to a `}` or a keyword that starts a statement. `start`
    /// is where the broken statement began; we always skip at least one
    /// token so that we can't get stuck on the same error forever.
    fn skipToStatement(p: *Parser, start: usize) void {
        if (p.index == start) p.skipTokenOrGroup();
        while (true) switch (p.peek().tag) {
            .semicolon => {
                _ = p.advance();
                return;
            },
            // A block ends the broken statement, as in `if x > { ... }`.
            .l_brace => {
                p.skipTokenOrGroup();
                return;
            },
            .r_brace, .eof, .kw_let, .kw_var, .kw_if, .kw_while, .kw_return, .kw_break, .kw_continue => return,
            else => _ = p.advance(),
        };
    }

    /// Skips one token, or a whole `{ ... }` group with everything nested in it.
    fn skipTokenOrGroup(p: *Parser) void {
        var depth: usize = 0;
        while (true) {
            switch (p.advance().tag) {
                .l_brace => depth += 1,
                .r_brace => depth -|= 1,
                .eof => return,
                else => {},
            }
            if (depth == 0) return;
        }
    }

    /// Error recovery at the top level: skip to the next declaration.
    fn skipToDeclaration(p: *Parser, start: usize) void {
        if (p.index == start) _ = p.advance();
        while (true) switch (p.peek().tag) {
            .eof, .kw_fn, .kw_extern => return,
            else => _ = p.advance(),
        };
    }

    fn newStmt(p: *Parser, span: Span, kind: ast.Stmt.Kind) Error!*ast.Stmt {
        const s = try p.arena.create(ast.Stmt);
        s.* = .{ .span = span, .kind = kind };
        return s;
    }

    pub fn parseExpr(p: *Parser) Error!*Expr {
        return p.expression(.lowest);
    }

    /// Parses operators that bind tighter than `min`, left to right.
    fn expression(p: *Parser, min: Prec) Error!*Expr {
        var lhs = try p.prefix();
        while (true) {
            if (p.peek().tag == .kw_as) {
                if (@backingInt(Prec.cast) <= @backingInt(min)) break;
                _ = p.advance();
                const ty = try p.parseType();
                lhs = try p.node(lhs.span.to(ty.span), .{ .cast = .{ .operand = lhs, .type = ty } });
                continue;
            }
            const op = binaryOp(p.peek().tag) orelse break;
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
        const token = p.peek();
        const kind: Expr.Kind = switch (token.tag) {
            .int => kind: {
                const value = lexer.intValue(p.text(token)) catch |err| switch (err) {
                    error.Overflow => return p.failAt(token.span, "integer literal is too large", .{}),
                    error.InvalidCharacter => return p.failAt(token.span, "invalid integer literal '{s}'", .{p.text(token)}),
                };
                if (value > std.math.maxInt(i64)) return p.failAt(token.span, "integer literal is too large", .{});
                break :kind .{ .int = value };
            },
            .char => .{ .char = (try lexer.unescape(p.arena, p.text(token)))[0] },
            .string => .{ .string = try lexer.unescape(p.arena, p.text(token)) },
            .kw_true => .{ .bool = true },
            .kw_false => .{ .bool = false },
            .identifier => .{ .name = p.text(token) },
            .l_paren => {
                _ = p.advance();
                const inner = try p.parseExpr();
                _ = try p.expect(.r_paren, "')'");
                return inner;
            },
            // The lexer has already reported this one.
            .invalid => return error.ParseError,
            // Leave the token where it is: error recovery decides what to skip.
            else => return p.failAt(token.span, "expected an expression, found {s}", .{token.tag.describe()}),
        };
        _ = p.advance();
        return p.node(token.span, kind);
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
    if (parser.parseExpr()) |tree| {
        try @import("print.zig").writeExpr(&out.writer, tree);
        if (parser.peek().tag != .eof) try out.writer.writeAll(" <more>");
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

test "casts bind tighter than binary operators" {
    try expectTree("a + b as i64 * c", "(+ a (* (as b i64) c))");
    try expectTree("-x as u8 as i32", "(as (as (- x) u8) i32)");
    try expectTree("p as *u8", "(as p *u8)");
}

test "statements recover after an error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\fn main() {
        \\    let x = ;
        \\    let y = 2
        \\    return x +;
        \\}
        \\fn ok() i64 { return 1; }
        \\
    ;
    const source: diag.Source = .{ .path = "t.peb", .text = src };
    var diags: Diagnostics = .init(arena.allocator(), &source);
    const tokens = try lexer.tokenize(arena.allocator(), src, &diags);
    var parser: Parser = .init(arena.allocator(), src, tokens, &diags);
    const program = try parser.parseProgram();
    // Three errors, one per broken statement, and both functions parsed.
    try std.testing.expectEqual(3, diags.error_count);
    try std.testing.expectEqual(2, program.decls.len);
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
