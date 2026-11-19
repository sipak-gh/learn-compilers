//! The abstract syntax tree. The parser allocates every node in an arena,
//! and the whole tree is freed at once when the arena goes away.
const std = @import("std");
const Span = @import("diag.zig").Span;
const Type = @import("types.zig").Type;

/// A whole source file: a list of declarations.
pub const Program = struct {
    decls: []Decl,
};

pub const Decl = union(enum) {
    func: *Func,
};

/// `fn name(a: i64, b: i64) i64 { ... }` or `extern fn name(a: *u8, ...) i32;`
pub const Func = struct {
    name: []const u8,
    name_span: Span,
    params: []Param,
    /// The parameter list ends with `...` (only allowed on extern functions).
    variadic: bool,
    /// The declared return type; null means the function returns nothing.
    return_type: ?*TypeExpr,
    /// null for an extern function, which is defined somewhere else (in libc).
    body: ?Block,
    /// Set by the checker: the resolved return type.
    ret: Type = .invalid,
};

pub const Param = struct {
    name: []const u8,
    span: Span,
    type: *TypeExpr,
    /// Set by the checker.
    sym: *Symbol = undefined,
};

/// A type as written in the source, such as `i64` or `*u8`. The checker
/// turns it into a `Type`.
pub const TypeExpr = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        name: []const u8,
        pointer: *TypeExpr,
    };
};

/// What a name refers to. The checker makes one for every function,
/// parameter and variable, and points each use of the name at it.
pub const Symbol = struct {
    name: []const u8,
    /// Where it is declared, for error notes.
    span: Span,
    kind: enum { variable, function },
    /// The type of a variable, or the return type of a function.
    type: Type,
    mutable: bool = false,
    /// Makes the stack slot name %name.id unique within a function.
    id: u32 = 0,
    func: ?*Func = null,
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

    /// `let name: type = value;` or `var name: type = value;`; the type
    /// is optional.
    pub const Let = struct {
        mutable: bool,
        name: []const u8,
        name_span: Span,
        type: ?*TypeExpr,
        value: *Expr,
        /// Set by the checker.
        sym: *Symbol = undefined,
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
    /// Set by the checker: the type of the value.
    type: Type = .invalid,
    /// Set by the checker for a `.name`: what the name refers to.
    sym: ?*Symbol = null,

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
        cast: Cast,
    };

    pub const Unary = struct { op: UnaryOp, operand: *Expr };
    pub const Binary = struct { op: BinaryOp, lhs: *Expr, rhs: *Expr };
    pub const Call = struct { callee: *Expr, args: []*Expr };
    pub const Index = struct { base: *Expr, index: *Expr };
    pub const Field = struct { base: *Expr, name: []const u8, name_span: Span };
    /// `operand as type`
    pub const Cast = struct { operand: *Expr, type: *TypeExpr };
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
