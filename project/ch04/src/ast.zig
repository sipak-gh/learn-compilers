//! The abstract syntax tree. The parser allocates every node in an arena,
//! and the whole tree is freed at once when the arena goes away.
const std = @import("std");
const Span = @import("diag.zig").Span;

/// A whole source file: a list of declarations.
pub const Program = struct {
    decls: []Decl,
};

pub const Decl = union(enum) {
    func: *Func,
};

/// `fn name(a, b) { ... }` or `extern fn name(a, ...);`
pub const Func = struct {
    name: []const u8,
    name_span: Span,
    params: []Param,
    /// The parameter list ends with `...` (only allowed on extern functions).
    variadic: bool,
    /// null for an extern function, which is defined somewhere else (in libc).
    body: ?Block,
};

pub const Param = struct {
    name: []const u8,
    span: Span,
};

pub const Block = struct {
    stmts: []*Stmt,
    /// The closing brace, where a missing `return` would go.
    end: Span,
};

pub const Stmt = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        let: Let,
        assign: Assign,
        expr: *Expr,
        @"if": If,
        @"while": While,
        @"break",
        @"continue",
        @"return": ?*Expr,
        block: Block,
    };

    /// `let name = value;` or `var name = value;`
    pub const Let = struct {
        mutable: bool,
        name: []const u8,
        name_span: Span,
        value: *Expr,
    };
    /// `target = value;`
    pub const Assign = struct { target: *Expr, value: *Expr };
    /// `if cond { ... } else ...`, where the else branch is a block or
    /// another if statement.
    pub const If = struct { cond: *Expr, then: Block, @"else": ?*Stmt };
    pub const While = struct { cond: *Expr, body: Block };
};

pub const Expr = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        int: u64,
        char: u8,
        string: []const u8, // the bytes, escapes already decoded
        bool: bool,
        name: []const u8,
        unary: Unary,
        binary: Binary,
        call: Call,
        index: Index,
        field: Field,
    };

    pub const Unary = struct { op: UnaryOp, operand: *Expr };
    pub const Binary = struct { op: BinaryOp, lhs: *Expr, rhs: *Expr };
    pub const Call = struct { callee: *Expr, args: []*Expr };
    pub const Index = struct { base: *Expr, index: *Expr };
    pub const Field = struct { base: *Expr, name: []const u8, name_span: Span };
};

pub const UnaryOp = enum {
    neg, // -x
    not, // !x
    addr, // &x
    deref, // *x

    pub fn symbol(op: UnaryOp) []const u8 {
        return switch (op) {
            .neg => "-",
            .not => "!",
            .addr => "&",
            .deref => "*",
        };
    }
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    @"and",
    @"or",

    pub fn symbol(op: BinaryOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .rem => "%",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .@"and" => "&&",
            .@"or" => "||",
        };
    }

    pub fn isComparison(op: BinaryOp) bool {
        return switch (op) {
            .eq, .ne, .lt, .le, .gt, .ge => true,
            else => false,
        };
    }
};
