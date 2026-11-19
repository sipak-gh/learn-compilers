//! Source files, spans, and error messages that point at the code.
const std = @import("std");
const Writer = std.Io.Writer;

/// A range of bytes in the source: `text[start..end]`.
pub const Span = struct {
    start: u32,
    end: u32,

    /// The span that covers both `a` and `b`.
    pub fn to(a: Span, b: Span) Span {
        return .{ .start = a.start, .end = b.end };
    }
};

pub const Source = struct {
    path: []const u8,
    text: []const u8,

    pub const Location = struct {
        line: u32, // 1-based
        col: u32, // 1-based, counted in bytes
        line_start: u32, // offset of the first byte of the line
    };

    /// Converts a byte offset into a line and a column.
    pub fn locate(s: Source, offset: u32) Location {
        var loc: Location = .{ .line = 1, .col = 1, .line_start = 0 };
        for (s.text[0..offset], 0..) |c, i| {
            if (c == '\n') {
                loc.line += 1;
                loc.line_start = @intCast(i + 1);
            }
        }
        loc.col = offset - loc.line_start + 1;
        return loc;
    }

    /// The text of the line that starts at `line_start`, without the newline.
    pub fn lineText(s: Source, line_start: u32) []const u8 {
        const end = std.mem.findScalarPos(u8, s.text, line_start, '\n') orelse s.text.len;
        return s.text[line_start..end];
    }
};

pub const Severity = enum { @"error", note };

pub const Diagnostic = struct {
    severity: Severity,
    span: Span,
    message: []const u8,
};

/// Collects the diagnostics for one source file.
pub const Diagnostics = struct {
    /// After this many errors, the rest are counted but not kept: the
    /// first ones are the useful ones. (Clang's default limit is also 20.)
    pub const max_errors = 20;

    /// Messages are allocated here and live as long as the arena.
    arena: std.mem.Allocator,
    source: *const Source,
    list: std.ArrayList(Diagnostic) = .empty,
    error_count: usize = 0,

    pub fn init(arena: std.mem.Allocator, source: *const Source) Diagnostics {
        return .{ .arena = arena, .source = source };
    }

    pub fn add(d: *Diagnostics, severity: Severity, span: Span, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        if (severity == .@"error") d.error_count += 1;
        // A note belongs to the error before it, so it goes too.
        if (d.error_count > max_errors) return;
        const message = try std.fmt.allocPrint(d.arena, fmt, args);
        try d.list.append(d.arena, .{ .severity = severity, .span = span, .message = message });
    }

    pub fn err(d: *Diagnostics, span: Span, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        return d.add(.@"error", span, fmt, args);
    }

    pub fn hasErrors(d: Diagnostics) bool {
        return d.error_count > 0;
    }

    /// Prints every diagnostic like this:
    ///
    ///     answer.peb:1:5: error: expected an expression, found '*'
    ///     1 + * 2
    ///         ^
    pub fn render(d: Diagnostics, w: *Writer) Writer.Error!void {
        for (d.list.items) |diag| try renderOne(d.source.*, diag, w);
        if (d.error_count > max_errors) {
            try w.print("{s}: {d} more errors not shown\n", .{ d.source.path, d.error_count - max_errors });
        }
    }
};

fn renderOne(source: Source, diag: Diagnostic, w: *Writer) Writer.Error!void {
    var start = diag.span.start;
    // An error at the very end of a file that ends with a newline is shown
    // at the end of the last line, not on an empty line after it.
    if (start == source.text.len and start > 0 and source.text[start - 1] == '\n') start -= 1;
    const loc = source.locate(start);
    try w.print("{s}:{d}:{d}: {t}: {s}\n", .{ source.path, loc.line, loc.col, diag.severity, diag.message });

    const line = source.lineText(loc.line_start);
    try w.print("{s}\n", .{line});
    // Copy tabs so that the caret lines up with the text above it.
    for (line[0 .. loc.col - 1]) |c| try w.writeByte(if (c == '\t') '\t' else ' ');
    try w.writeByte('^');
    // Underline the rest of the span, but not past the end of the line.
    const line_end = loc.line_start + line.len;
    const end = @min(diag.span.end, line_end);
    if (end > start + 1) try w.splatByteAll('~', end - start - 1);
    try w.writeByte('\n');
}

test "locate turns offsets into lines and columns" {
    const src: Source = .{ .path = "t.peb", .text = "ab\ncd\n" };
    try std.testing.expectEqual(Source.Location{ .line = 1, .col = 1, .line_start = 0 }, src.locate(0));
    try std.testing.expectEqual(Source.Location{ .line = 2, .col = 2, .line_start = 3 }, src.locate(4));
}

test "render points at the span" {
    const src: Source = .{ .path = "t.peb", .text = "let x = 1 +\n  foo(2);\n" };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .init(arena.allocator(), &src);
    try diags.err(.{ .start = 14, .end = 17 }, "unknown function '{s}'", .{"foo"});

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try diags.render(&out.writer);
    try std.testing.expectEqualStrings(
        \\t.peb:2:3: error: unknown function 'foo'
        \\  foo(2);
        \\  ^~~
        \\
    , out.written());
}

test "after max_errors errors, the rest are only counted" {
    const src: Source = .{ .path = "t.peb", .text = "x\n" };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .init(arena.allocator(), &src);
    for (0..Diagnostics.max_errors + 5) |i| {
        try diags.err(.{ .start = 0, .end = 1 }, "error {d}", .{i});
        try diags.add(.note, .{ .start = 0, .end = 1 }, "note {d}", .{i});
    }
    try std.testing.expectEqual(2 * Diagnostics.max_errors, diags.list.items.len);

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try diags.render(&out.writer);
    try std.testing.expect(std.mem.endsWith(u8, out.written(),
        \\t.peb:1:1: note: note 19
        \\x
        \\^
        \\t.peb: 5 more errors not shown
        \\
    ));
}
