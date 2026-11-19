//! The abstract syntax tree. The parser allocates every node in an arena,
//! and the whole tree is freed at once when the arena goes away.
const std = @import("std");
const Span = @import("diag.zig").Span;

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
