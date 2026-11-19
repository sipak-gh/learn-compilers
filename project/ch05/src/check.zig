//! The checker: the phase between parsing and code generation. It
//!
//! - resolves every name to the symbol it refers to,
//! - works out the type of every expression and checks that types match,
//! - checks the rules the grammar can't express ('break' inside a loop,
//!   a 'return' on every path, the shape of 'main', ...).
//!
//! It writes its results into the tree (`Expr.type`, `Expr.sym`, ...), so
//! the code generator can trust the tree and never reports errors itself.
const std = @import("std");
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Symbol = ast.Symbol;
const Type = @import("types.zig").Type;
const diag = @import("diag.zig");
const Span = diag.Span;
const Diagnostics = diag.Diagnostics;

pub const Error = error{OutOfMemory};

pub const Checker = struct {
    arena: std.mem.Allocator,
    diags: *Diagnostics,
    /// Functions, visible everywhere.
    funcs: std.StringHashMapUnmanaged(*Symbol) = .empty,
    /// Variables in scope, innermost last.
    scope: std.ArrayList(*Symbol) = .empty,
    /// The function being checked.
    func: *ast.Func = undefined,
    loop_depth: u32 = 0,
    next_id: u32 = 0,

    pub fn init(arena: std.mem.Allocator, diags: *Diagnostics) Checker {
        return .{ .arena = arena, .diags = diags };
    }

    pub fn checkProgram(c: *Checker, program: ast.Program) Error!void {
        // Pass 1: function signatures, so a call can come before the
        // function it calls.
        for (program.decls) |decl| switch (decl) {
            .func => |f| try c.declareFunction(f),
        };
        // Pass 2: function bodies.
        for (program.decls) |decl| switch (decl) {
            .func => |f| {
                if (std.mem.eql(u8, f.name, "main")) try c.checkMain(f);
                if (f.body) |body| try c.checkFunction(f, body);
            },
        };
        if (!c.funcs.contains("main")) {
            try c.diags.err(.{ .start = 0, .end = 0 }, "the program has no 'main' function", .{});
        }
    }

    fn declareFunction(c: *Checker, f: *ast.Func) Error!void {
        for (f.params) |*param| {
            param.sym = try c.newSymbol(.{
                .name = param.name,
                .span = param.span,
                .kind = .variable,
                .type = try c.resolveType(param.type),
                .mutable = true,
            });
        }
        f.ret = if (f.return_type) |t| try c.resolveType(t) else .void;
        const sym = try c.newSymbol(.{ .name = f.name, .span = f.name_span, .kind = .function, .type = f.ret, .func = f });
        const entry = try c.funcs.getOrPut(c.arena, f.name);
        if (entry.found_existing) {
            try c.diags.err(f.name_span, "'{s}' is already declared", .{f.name});
            try c.diags.add(.note, entry.value_ptr.*.span, "the first declaration is here", .{});
        } else {
            entry.value_ptr.* = sym;
        }
    }

    fn checkMain(c: *Checker, f: *ast.Func) Error!void {
        if (f.body == null) {
            try c.diags.err(f.name_span, "'main' must be defined here, not extern", .{});
        } else if (f.params.len > 0) {
            try c.diags.err(f.params[0].span, "'main' takes no parameters", .{});
        } else if (f.ret != .void and f.ret != .i32 and f.ret != .invalid) {
            try c.diags.err(f.return_type.?.span, "'main' must return 'i32' or nothing, not '{f}'", .{f.ret});
        }
    }

    fn checkFunction(c: *Checker, f: *ast.Func, body: ast.Block) Error!void {
        c.func = f;
        c.scope.clearRetainingCapacity();
        c.next_id = 0;
        for (f.params) |param| {
            param.sym.id = c.nextId();
            try c.scope.append(c.arena, param.sym);
        }
        try c.checkStmts(body.stmts);
        if (f.ret != .void and f.ret != .invalid and !alwaysReturns(body.stmts)) {
            try c.diags.err(body.end, "missing 'return' at the end of '{s}', which returns '{f}'", .{ f.name, f.ret });
        }
    }

    // ---- Types ----

    /// Turns a type written in the source into a Type.
    fn resolveType(c: *Checker, t: *const ast.TypeExpr) Error!Type {
        switch (t.kind) {
            .name => |name| {
                const named = std.meta.stringToEnum(enum { i64, i32, u8, bool }, name) orelse {
                    try c.diags.err(t.span, "unknown type '{s}'", .{name});
                    return .invalid;
                };
                return switch (named) {
                    .i64 => .i64,
                    .i32 => .i32,
                    .u8 => .u8,
                    .bool => .bool,
                };
            },
            .pointer => |pointee| {
                const p = try c.arena.create(Type);
                p.* = try c.resolveType(pointee);
                if (p.* == .invalid) return .invalid;
                return .{ .pointer = p };
            },
        }
    }

    /// Reports an error unless `got` is `want`. Invalid types match
    /// anything: their error has been reported already.
    fn expectType(c: *Checker, e: *const Expr, want: Type, got: Type) Error!void {
        if (want == .invalid or got == .invalid or want.eql(got)) return;
        try c.diags.err(e.span, "expected '{f}', found '{f}'", .{ want, got });
    }

    // ---- Statements ----

    fn checkStmts(c: *Checker, stmts: []const *Stmt) Error!void {
        for (stmts) |s| try c.checkStmt(s);
    }

    fn checkBlock(c: *Checker, b: ast.Block) Error!void {
        const scope_start = c.scope.items.len;
        defer c.scope.shrinkRetainingCapacity(scope_start);
        try c.checkStmts(b.stmts);
    }

    fn checkStmt(c: *Checker, s: *Stmt) Error!void {
        switch (s.kind) {
            .let => |*l| {
                var t: Type = undefined;
                if (l.type) |te| {
                    t = try c.resolveType(te);
                    try c.expectType(l.value, t, try c.checkExpr(l.value, t));
                } else {
                    t = try c.checkValue(l.value, null);
                }
                // Declared after the value is checked: in `let x = x + 1;`
                // the x on the right is the outer one.
                l.sym = try c.newSymbol(.{
                    .name = l.name,
                    .span = l.name_span,
                    .kind = .variable,
                    .type = t,
                    .mutable = l.mutable,
                    .id = c.nextId(),
                });
                try c.scope.append(c.arena, l.sym);
            },
            .assign => |a| {
                const t = try c.checkExpr(a.target, null);
                if (t == .invalid) {
                    _ = try c.checkExpr(a.value, null);
                    return;
                }
                if (try c.checkAssignable(a.target)) {
                    try c.expectType(a.value, t, try c.checkExpr(a.value, t));
                }
            },
            .expr => |e| _ = try c.checkExpr(e, null),
            .@"if" => |i| {
                try c.checkCond(i.cond);
                try c.checkBlock(i.then);
                if (i.@"else") |e| try c.checkStmt(e);
            },
            .@"while" => |w| {
                try c.checkCond(w.cond);
                c.loop_depth += 1;
                defer c.loop_depth -= 1;
                try c.checkBlock(w.body);
            },
            .@"break", .@"continue" => if (c.loop_depth == 0) {
                try c.diags.err(s.span, "'{s}' outside of a loop", .{if (s.kind == .@"break") "break" else "continue"});
            },
            .@"return" => |value| {
                const f = c.func;
                if (value) |v| {
                    if (f.ret == .void) {
                        try c.diags.err(v.span, "'{s}' returns nothing, so 'return' cannot have a value", .{f.name});
                        _ = try c.checkExpr(v, null);
                    } else {
                        try c.expectType(v, f.ret, try c.checkExpr(v, f.ret));
                    }
                } else if (f.ret != .void and f.ret != .invalid) {
                    try c.diags.err(s.span, "'{s}' must return a value of type '{f}'", .{ f.name, f.ret });
                }
            },
            .block => |b| try c.checkBlock(b),
        }
    }

    fn checkCond(c: *Checker, e: *Expr) Error!void {
        const t = try c.checkExpr(e, .bool);
        if (t != .bool and t != .invalid) {
            try c.diags.err(e.span, "a condition must be a 'bool', not '{f}'", .{t});
        }
    }

    /// Only variables declared with `var` can be assigned.
    fn checkAssignable(c: *Checker, target: *const Expr) Error!bool {
        if (target.kind != .name) {
            try c.diags.err(target.span, "cannot assign to this expression", .{});
            return false;
        }
        const sym = target.sym.?;
        if (!sym.mutable) {
            try c.diags.err(target.span, "cannot assign to '{s}', which was declared with 'let'", .{sym.name});
            try c.diags.add(.note, sym.span, "use 'var' here to make it a variable", .{});
            return false;
        }
        return true;
    }

    // ---- Expressions ----

    /// Like checkExpr, but the expression must produce a value.
    fn checkValue(c: *Checker, e: *Expr, want: ?Type) Error!Type {
        const t = try c.checkExpr(e, want);
        if (t == .void) {
            try c.diags.err(e.span, "this call returns nothing, so its result cannot be used", .{});
            e.type = .invalid;
            return .invalid;
        }
        return t;
    }

    /// Works out the type of `e`, stores it in `e.type` and returns it.
    /// `want` is the type the context expects, if it expects one; an
    /// integer literal takes that type, so `let b: u8 = 200;` works.
    fn checkExpr(c: *Checker, e: *Expr, want: ?Type) Error!Type {
        e.type = try c.typeOf(e, want);
        return e.type;
    }

    fn typeOf(c: *Checker, e: *Expr, want: ?Type) Error!Type {
        switch (e.kind) {
            .int => |n| return c.literalType(e, n, .i64, want),
            .char => |ch| return c.literalType(e, ch, .u8, want),
            .bool => return .bool,
            .string => return .{ .pointer = &u8_type },
            .name => |name| {
                const sym = c.lookup(name) orelse {
                    if (c.funcs.contains(name)) return c.fail(e.span, "'{s}' is a function, not a variable", .{name});
                    return c.fail(e.span, "unknown name '{s}'", .{name});
                };
                e.sym = sym;
                return sym.type;
            },
            .unary => |u| switch (u.op) {
                .neg => {
                    const t = try c.checkValue(u.operand, want);
                    if (t == .invalid or t.isSigned()) return t;
                    return c.fail(e.span, "cannot negate a value of type '{f}'", .{t});
                },
                .not => {
                    const t = try c.checkValue(u.operand, .bool);
                    if (t == .invalid or t == .bool) return .bool;
                    return c.fail(u.operand.span, "'!' needs a 'bool', not '{f}'", .{t});
                },
                .addr, .deref => return c.fail(e.span, "pebc cannot compile pointers yet", .{}),
            },
            .binary => |b| return c.checkBinary(e, b, want),
            .call => |call| return c.checkCall(e, call),
            .index => return c.fail(e.span, "pebc cannot compile indexing yet", .{}),
            .field => return c.fail(e.span, "pebc cannot compile fields yet", .{}),
            .cast => |cast| {
                const from = try c.checkValue(cast.operand, null);
                const to = try c.resolveType(cast.type);
                if (from == .invalid or to == .invalid) return .invalid;
                if (from.eql(to) or (to.isInteger() and (from.isInteger() or from == .bool))) return to;
                if (to == .bool and from.isInteger()) {
                    return c.fail(e.span, "cannot convert '{f}' to 'bool' with 'as'; compare it with 0 instead", .{from});
                }
                return c.fail(e.span, "cannot convert '{f}' to '{f}' with 'as'", .{ from, to });
            },
        }
    }

    fn literalType(c: *Checker, e: *Expr, value: u64, default: Type, want: ?Type) Error!Type {
        const t = if (want != null and want.?.isInteger()) want.? else default;
        if (!t.fits(value)) return c.fail(e.span, "{d} does not fit in '{f}'", .{ value, t });
        return t;
    }

    fn checkBinary(c: *Checker, e: *Expr, b: Expr.Binary, want: ?Type) Error!Type {
        const symbol = b.op.symbol();
        switch (b.op) {
            .@"and", .@"or" => {
                for ([_]*Expr{ b.lhs, b.rhs }) |operand| {
                    const t = try c.checkValue(operand, .bool);
                    if (t != .bool and t != .invalid) {
                        try c.diags.err(operand.span, "'{s}' needs 'bool' operands, not '{f}'", .{ symbol, t });
                    }
                }
                return .bool;
            },
            else => {},
        }

        // Check the operands. A literal operand takes the type of the other
        // operand, so check that one first: in `1 + x`, the 1 gets x's type.
        const comparison = b.op.isComparison();
        const operand_want = if (comparison) null else want;
        var lhs: Type = undefined;
        var rhs: Type = undefined;
        if (isLiteral(b.lhs) and !isLiteral(b.rhs)) {
            rhs = try c.checkValue(b.rhs, operand_want);
            lhs = try c.checkValue(b.lhs, rhs);
        } else {
            lhs = try c.checkValue(b.lhs, operand_want);
            rhs = try c.checkValue(b.rhs, lhs);
        }
        if (lhs == .invalid or rhs == .invalid) return if (comparison) .bool else .invalid;

        const ok = switch (b.op) {
            .eq, .ne => lhs.isInteger() or lhs == .bool or lhs == .pointer,
            else => lhs.isInteger(),
        };
        if (!ok) {
            try c.diags.err(b.lhs.span, "'{s}' cannot be used on '{f}'", .{ symbol, lhs });
            return .invalid;
        }
        if (!lhs.eql(rhs)) {
            try c.diags.err(e.span, "'{s}' needs operands of the same type, not '{f}' and '{f}'", .{ symbol, lhs, rhs });
            try c.diags.add(.note, b.rhs.span, "convert one of them with 'as'", .{});
            return .invalid;
        }
        return if (comparison) .bool else lhs;
    }

    fn checkCall(c: *Checker, e: *Expr, call: Expr.Call) Error!Type {
        if (call.callee.kind != .name) return c.fail(call.callee.span, "only named functions can be called", .{});
        const name = call.callee.kind.name;
        if (c.lookup(name) != null) return c.fail(call.callee.span, "'{s}' is a variable, not a function", .{name});
        const sym = c.funcs.get(name) orelse return c.fail(call.callee.span, "unknown function '{s}'", .{name});
        call.callee.sym = sym;
        const f = sym.func.?;

        const n = f.params.len;
        if (call.args.len < n or (call.args.len > n and !f.variadic)) {
            try c.diags.err(e.span, "'{s}' takes {s}{d} argument{s}, but {d} {s} given", .{
                name,
                if (f.variadic) "at least " else "",
                n,
                if (n == 1) "" else "s",
                call.args.len,
                if (call.args.len == 1) "was" else "were",
            });
            try c.diags.add(.note, f.name_span, "'{s}' is declared here", .{name});
            for (call.args) |arg| _ = try c.checkExpr(arg, null);
            return f.ret;
        }
        for (call.args, 0..) |arg, i| {
            if (i < n) {
                const want = f.params[i].sym.type;
                try c.expectType(arg, want, try c.checkValue(arg, want));
            } else {
                _ = try c.checkValue(arg, null);
            }
        }
        return f.ret;
    }

    // ---- Names ----

    fn lookup(c: *Checker, name: []const u8) ?*Symbol {
        // Innermost first, so inner variables shadow outer ones.
        var i = c.scope.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, c.scope.items[i].name, name)) return c.scope.items[i];
        }
        return null;
    }

    fn newSymbol(c: *Checker, sym: Symbol) Error!*Symbol {
        const p = try c.arena.create(Symbol);
        p.* = sym;
        return p;
    }

    fn nextId(c: *Checker) u32 {
        c.next_id += 1;
        return c.next_id;
    }

    fn fail(c: *Checker, span: Span, comptime fmt: []const u8, args: anytype) Error!Type {
        try c.diags.err(span, fmt, args);
        return .invalid;
    }
};

const u8_type: Type = .u8;

/// An integer or character literal, possibly negated: its type comes
/// from the context.
fn isLiteral(e: *const Expr) bool {
    return switch (e.kind) {
        .int, .char => true,
        .unary => |u| u.op == .neg and isLiteral(u.operand),
        else => false,
    };
}

/// Does running these statements always end in a `return`?
fn alwaysReturns(stmts: []const *Stmt) bool {
    for (stmts) |s| switch (s.kind) {
        .@"return" => return true,
        .block => |b| if (alwaysReturns(b.stmts)) return true,
        .@"if" => |i| if (i.@"else") |e| {
            if (alwaysReturns(i.then.stmts) and alwaysReturns(&.{e})) return true;
        },
        // `while true { ... }` only ends through a break or a return.
        .@"while" => |w| if (w.cond.kind == .bool and w.cond.kind.bool and !hasBreak(w.body.stmts)) return true,
        else => {},
    };
    return false;
}

/// Is there a `break` for this loop (not for a loop nested in it)?
fn hasBreak(stmts: []const *Stmt) bool {
    for (stmts) |s| switch (s.kind) {
        .@"break" => return true,
        .block => |b| if (hasBreak(b.stmts)) return true,
        .@"if" => |i| {
            if (hasBreak(i.then.stmts)) return true;
            if (i.@"else") |e| if (hasBreak(&.{e})) return true;
        },
        else => {},
    };
    return false;
}

fn checkSource(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    const lexer = @import("lexer.zig");
    const source: diag.Source = .{ .path = "t.peb", .text = src };
    var diags: Diagnostics = .init(arena, &source);
    const tokens = try lexer.tokenize(arena, src, &diags);
    var parser: @import("parser.zig").Parser = .init(arena, src, tokens, &diags);
    const program = try parser.parseProgram();
    var checker: Checker = .init(arena, &diags);
    try checker.checkProgram(program);
    var out: std.Io.Writer.Allocating = .init(arena);
    try diags.render(&out.writer);
    return out.written();
}

test "literals take their type from the context" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("", try checkSource(a,
        \\fn main() { let b: u8 = 200; let c = b + 55; let d: i32 = -1 * 7; }
    ));
    try std.testing.expectEqualStrings(
        \\t.peb:1:25: error: 256 does not fit in 'u8'
        \\fn main() { let b: u8 = 256; }
        \\                        ^~~
        \\
    , try checkSource(a,
        \\fn main() { let b: u8 = 256; }
    ));
}

test "one mistake, one message" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // `nope` is unknown; the expressions around it must not add errors.
    try std.testing.expectEqualStrings(
        \\t.peb:1:30: error: unknown name 'nope'
        \\fn main() { let x: i64 = 1 + nope * 2; if x > 0 && x < 9 {} }
        \\                             ^~~~
        \\
    , try checkSource(arena.allocator(),
        \\fn main() { let x: i64 = 1 + nope * 2; if x > 0 && x < 9 {} }
    ));
}
