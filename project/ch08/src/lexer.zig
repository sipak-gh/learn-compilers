//! The lexer: turns source text into tokens.
const std = @import("std");
const diag = @import("diag.zig");
const Span = diag.Span;
const Diagnostics = diag.Diagnostics;

pub const Token = struct {
    tag: Tag,
    span: Span,

    pub const Tag = enum {
        int,
        char,
        string,
        identifier,

        kw_as,
        kw_break,
        kw_continue,
        kw_else,
        kw_extern,
        kw_false,
        kw_fn,
        kw_if,
        kw_let,
        kw_null,
        kw_return,
        kw_sizeof,
        kw_struct,
        kw_true,
        kw_var,
        kw_while,

        l_paren, // (
        r_paren, // )
        l_brace, // {
        r_brace, // }
        l_bracket, // [
        r_bracket, // ]
        comma, // ,
        colon, // :
        semicolon, // ;
        dot, // .
        ellipsis, // ...
        plus, // +
        minus, // -
        star, // *
        slash, // /
        percent, // %
        amp, // &
        amp_amp, // &&
        pipe_pipe, // ||
        bang, // !
        bang_equal, // !=
        equal, // =
        equal_equal, // ==
        less, // <
        less_equal, // <=
        greater, // >
        greater_equal, // >=

        eof,
        /// Something the lexer could not make sense of. It has already
        /// reported an error about it.
        invalid,

        /// How the token is named in error messages.
        pub fn describe(tag: Tag) []const u8 {
            return switch (tag) {
                .int => "an integer",
                .char => "a character",
                .string => "a string",
                .identifier => "a name",
                .eof => "end of file",
                .invalid => "an invalid token",
                inline else => |t| "'" ++ comptime t.lexeme() ++ "'",
            };
        }

        /// The fixed spelling of a keyword or punctuation token.
        pub fn lexeme(comptime tag: Tag) []const u8 {
            const name = @tagName(tag);
            if (std.mem.startsWith(u8, name, "kw_")) return name[3..];
            for (punctuation) |p| if (p.tag == tag) return p.text;
            unreachable;
        }
    };
};

pub const keywords: std.StaticStringMap(Token.Tag) = .initComptime(.{
    .{ "as", .kw_as },         .{ "break", .kw_break },   .{ "continue", .kw_continue },
    .{ "else", .kw_else },     .{ "extern", .kw_extern }, .{ "false", .kw_false },
    .{ "fn", .kw_fn },         .{ "if", .kw_if },         .{ "let", .kw_let },
    .{ "null", .kw_null },     .{ "return", .kw_return }, .{ "sizeof", .kw_sizeof },
    .{ "struct", .kw_struct }, .{ "true", .kw_true },     .{ "var", .kw_var },
    .{ "while", .kw_while },
});

/// Punctuation, longest first, so that "..." wins over "." and "<=" over "<".
const punctuation = [_]struct { text: []const u8, tag: Token.Tag }{
    .{ .text = "...", .tag = .ellipsis },
    .{ .text = "&&", .tag = .amp_amp },
    .{ .text = "||", .tag = .pipe_pipe },
    .{ .text = "!=", .tag = .bang_equal },
    .{ .text = "==", .tag = .equal_equal },
    .{ .text = "<=", .tag = .less_equal },
    .{ .text = ">=", .tag = .greater_equal },
    .{ .text = "(", .tag = .l_paren },
    .{ .text = ")", .tag = .r_paren },
    .{ .text = "{", .tag = .l_brace },
    .{ .text = "}", .tag = .r_brace },
    .{ .text = "[", .tag = .l_bracket },
    .{ .text = "]", .tag = .r_bracket },
    .{ .text = ",", .tag = .comma },
    .{ .text = ":", .tag = .colon },
    .{ .text = ";", .tag = .semicolon },
    .{ .text = ".", .tag = .dot },
    .{ .text = "+", .tag = .plus },
    .{ .text = "-", .tag = .minus },
    .{ .text = "*", .tag = .star },
    .{ .text = "/", .tag = .slash },
    .{ .text = "%", .tag = .percent },
    .{ .text = "&", .tag = .amp },
    .{ .text = "!", .tag = .bang },
    .{ .text = "=", .tag = .equal },
    .{ .text = "<", .tag = .less },
    .{ .text = ">", .tag = .greater },
};

pub const Lexer = struct {
    src: []const u8,
    pos: u32 = 0,
    diags: *Diagnostics,

    pub fn init(src: []const u8, diags: *Diagnostics) Lexer {
        return .{ .src = src, .diags = diags };
    }

    /// Returns the next token. At the end it returns `.eof` forever.
    pub fn next(l: *Lexer) error{OutOfMemory}!Token {
        l.skipSpaceAndComments();
        const start = l.pos;
        if (l.pos >= l.src.len) return l.make(.eof, start);

        const c = l.src[l.pos];
        if (isIdentStart(c)) {
            while (l.pos < l.src.len and isIdentChar(l.src[l.pos])) l.pos += 1;
            const tag = keywords.get(l.src[start..l.pos]) orelse .identifier;
            return l.make(tag, start);
        }
        if (std.ascii.isDigit(c)) {
            // Take letters too, so that "12ab" is one bad number rather than
            // "12" followed by the name "ab". The parser checks the digits.
            while (l.pos < l.src.len and isIdentChar(l.src[l.pos])) l.pos += 1;
            return l.make(.int, start);
        }
        if (c == '"') return l.quoted('"', .string);
        if (c == '\'') return l.quoted('\'', .char);

        for (punctuation) |p| {
            if (std.mem.startsWith(u8, l.src[l.pos..], p.text)) {
                l.pos += @intCast(p.text.len);
                return l.make(p.tag, start);
            }
        }

        l.pos += 1;
        const span: Span = .{ .start = start, .end = l.pos };
        if (std.ascii.isPrint(c)) {
            try l.diags.err(span, "unexpected character '{c}'", .{c});
        } else {
            try l.diags.err(span, "unexpected byte 0x{x:0>2}", .{c});
        }
        return .{ .tag = .invalid, .span = span };
    }

    /// Lexes a string or character literal, checking its escapes.
    fn quoted(l: *Lexer, quote: u8, tag: Token.Tag) error{OutOfMemory}!Token {
        const start = l.pos;
        l.pos += 1; // the opening quote
        var count: usize = 0; // characters between the quotes
        while (true) {
            if (l.pos >= l.src.len or l.src[l.pos] == '\n') {
                const what = if (tag == .string) "string" else "character";
                try l.diags.err(.{ .start = start, .end = l.pos }, "unterminated {s} literal", .{what});
                return .{ .tag = .invalid, .span = .{ .start = start, .end = l.pos } };
            }
            const c = l.src[l.pos];
            if (c == quote) break;
            if (c == '\\') {
                if (l.pos + 1 < l.src.len and escapeValue(l.src[l.pos + 1]) != null) {
                    l.pos += 2;
                } else {
                    const end = @min(l.pos + 2, l.src.len);
                    try l.diags.err(.{ .start = l.pos, .end = @intCast(end) }, "unknown escape sequence '{s}'", .{l.src[l.pos..end]});
                    l.pos = @intCast(end);
                }
            } else {
                l.pos += 1;
            }
            count += 1;
        }
        l.pos += 1; // the closing quote
        const token = l.make(tag, start);
        if (tag == .char and count != 1) {
            try l.diags.err(token.span, "a character literal holds exactly one character", .{});
            return .{ .tag = .invalid, .span = token.span };
        }
        return token;
    }

    fn skipSpaceAndComments(l: *Lexer) void {
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                l.pos += 1;
            } else if (std.mem.startsWith(u8, l.src[l.pos..], "//")) {
                while (l.pos < l.src.len and l.src[l.pos] != '\n') l.pos += 1;
            } else {
                return;
            }
        }
    }

    fn make(l: *Lexer, tag: Token.Tag, start: u32) Token {
        return .{ .tag = tag, .span = .{ .start = start, .end = l.pos } };
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The byte an escape sequence stands for: 'n' for "\n" gives 10.
fn escapeValue(c: u8) ?u8 {
    return switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        '\\', '\'', '"' => c,
        else => null,
    };
}

/// Lexes all of `src`. The last token is always `.eof`.
pub fn tokenize(arena: std.mem.Allocator, src: []const u8, diags: *Diagnostics) error{OutOfMemory}![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    var lexer: Lexer = .init(src, diags);
    while (true) {
        const token = try lexer.next();
        try tokens.append(arena, token);
        if (token.tag == .eof) return tokens.items;
    }
}

/// The bytes a string or character literal stands for, quotes removed and
/// escapes decoded. The lexer has already checked the escapes.
pub fn unescape(arena: std.mem.Allocator, literal: []const u8) error{OutOfMemory}![]u8 {
    const inner = literal[1 .. literal.len - 1];
    var out: std.ArrayList(u8) = try .initCapacity(arena, inner.len);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\') {
            i += 1;
            out.appendAssumeCapacity(escapeValue(inner[i]).?);
        } else {
            out.appendAssumeCapacity(inner[i]);
        }
    }
    return out.items;
}

/// The value of an integer literal: decimal, or hexadecimal with "0x".
pub fn intValue(text: []const u8) error{ Overflow, InvalidCharacter }!u64 {
    if (std.mem.startsWith(u8, text, "0x")) return std.fmt.parseUnsigned(u64, text[2..], 16);
    return std.fmt.parseUnsigned(u64, text, 10);
}

fn expectTags(src: []const u8, expected: []const Token.Tag) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source: diag.Source = .{ .path = "t.peb", .text = src };
    var diags: Diagnostics = .init(arena.allocator(), &source);
    const tokens = try tokenize(arena.allocator(), src, &diags);
    var tags: std.ArrayList(Token.Tag) = .empty;
    for (tokens) |t| try tags.append(arena.allocator(), t.tag);
    try std.testing.expectEqualSlices(Token.Tag, expected, tags.items);
}

test "keywords, names and numbers" {
    try expectTags("fn main iffy if 42 0x1F", &.{ .kw_fn, .identifier, .identifier, .kw_if, .int, .int, .eof });
}

test "longest punctuation wins" {
    try expectTags("<= < ... . == = &&&", &.{ .less_equal, .less, .ellipsis, .dot, .equal_equal, .equal, .amp_amp, .amp, .eof });
}

test "comments and literals" {
    try expectTags("'a' '\\n' \"hi\\t\" // the end\n", &.{ .char, .char, .string, .eof });
}

test "bad input becomes .invalid with an error" {
    try expectTags("1 $ 2 \"open", &.{ .int, .invalid, .int, .invalid, .eof });
}

test "a backslash at the very end of the file" {
    // The escape check must not read the byte after the backslash when
    // there is none. Chapter 8's fuzzer finds that bug in seconds.
    try expectTags("\"\\", &.{ .invalid, .eof });
}

test "unescape and intValue" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\nb\"", try unescape(arena.allocator(), "\"a\\nb\\\"\""));
    try std.testing.expectEqual(31, try intValue("0x1F"));
    try std.testing.expectError(error.Overflow, intValue("18446744073709551616"));
    try std.testing.expectError(error.InvalidCharacter, intValue("12ab"));
}
