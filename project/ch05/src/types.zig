//! Pebble's types.
const std = @import("std");
const Writer = std.Io.Writer;

pub const Type = union(enum) {
    void,
    bool,
    i64,
    i32,
    u8,
    /// `*T`. String literals are `*u8`.
    pointer: *const Type,
    /// The type of an expression that has an error. Every check accepts
    /// it silently, so one mistake produces one message, not a cascade.
    invalid,

    pub fn eql(a: Type, b: Type) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .pointer => |p| p.eql(b.pointer.*),
            else => true,
        };
    }

    pub fn isInteger(t: Type) bool {
        return switch (t) {
            .i64, .i32, .u8 => true,
            else => false,
        };
    }

    pub fn isSigned(t: Type) bool {
        return t == .i64 or t == .i32;
    }

    /// The size in bytes of a value of this type in memory.
    pub fn size(t: Type) u64 {
        return switch (t) {
            .void, .invalid => 0,
            .u8 => 1,
            .bool, .i32 => 4,
            .i64, .pointer => 8,
        };
    }

    /// Does `value` fit in integer type `t`?
    pub fn fits(t: Type, value: u64) bool {
        return switch (t) {
            .i64 => value <= std.math.maxInt(i64),
            .i32 => value <= std.math.maxInt(i32),
            .u8 => value <= std.math.maxInt(u8),
            else => false,
        };
    }

    /// The QBE base type that holds a value of this type in a temporary:
    /// `w` (32 bits) or `l` (64 bits).
    pub fn base(t: Type) u8 {
        return switch (t) {
            .i64, .pointer => 'l',
            else => 'w',
        };
    }

    pub fn format(t: Type, w: *Writer) Writer.Error!void {
        switch (t) {
            .pointer => |p| try w.print("*{f}", .{p.*}),
            .invalid => try w.writeAll("<invalid>"),
            else => try w.writeAll(@tagName(t)),
        }
    }
};

test "pointer types compare by what they point to" {
    const u8_type: Type = .u8;
    const i32_type: Type = .i32;
    const a: Type = .{ .pointer = &u8_type };
    const b: Type = .{ .pointer = &u8_type };
    const c: Type = .{ .pointer = &i32_type };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(.u8));

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("*u8", try std.fmt.bufPrint(&buf, "{f}", .{a}));
}
