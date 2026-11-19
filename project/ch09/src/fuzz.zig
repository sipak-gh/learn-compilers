//! Fuzz tests: feed the compiler programs nobody would write, and check
//! that it never crashes. A wrong program must get error messages; a
//! right one must get QBE IL. A panic, `unreachable` or out-of-bounds
//! index anywhere in pebc is a bug.
//!
//! `zig build test` runs each fuzz test once, on its corpus. `zig build
//! test --fuzz=100K` searches for crashes for 100,000 runs.
const std = @import("std");
const Smith = std.testing.Smith;
const diag = @import("diag.zig");
const lexer = @import("lexer.zig");
const Parser = @import("parser.zig").Parser;
const Checker = @import("check.zig").Checker;
const Folder = @import("fold.zig").Folder;
const CodeGen = @import("codegen.zig").CodeGen;

/// Runs the phases of `pebc ir` on `src`, the way main.zig does, and
/// renders the error messages, but writes everything into the void.
fn compile(src: []const u8) !void {
    // The fuzzer runs this thousands of times a second, so the memory
    // comes from one big buffer instead of the operating system.
    const static = struct {
        var memory: [16 << 20]u8 = undefined;
    };
    var fba: std.heap.FixedBufferAllocator = .init(&static.memory);
    const a = fba.allocator();
    var buffer: [256]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&buffer);

    const source: diag.Source = .{ .path = "fuzz.peb", .text = src };
    var diags: diag.Diagnostics = .init(a, &source);
    defer diags.render(&discard.writer) catch unreachable;
    const tokens = try lexer.tokenize(a, src, &diags);
    if (diags.hasErrors()) return;
    var parser: Parser = .init(a, src, tokens, &diags);
    const program = try parser.parseProgram();
    if (diags.hasErrors()) return;
    var checker: Checker = .init(a, &diags);
    try checker.checkProgram(program);
    if (diags.hasErrors()) return;
    var folder: Folder = .init(&diags);
    try folder.foldProgram(program);
    if (diags.hasErrors()) return;
    var gen: CodeGen = .init(a, &discard.writer);
    try gen.genProgram(program);
}

test "fuzz the compiler" {
    try std.testing.fuzz({}, compileSomething, .{});
}

/// The fuzzer's first choice: random bytes, or random tokens.
fn compileSomething(_: void, smith: *Smith) !void {
    var buffer: [4096]u8 = undefined;
    const src = if (smith.value(bool)) randomBytes(smith, &buffer) else randomTokens(smith, &buffer);
    try compile(src);
}

fn randomBytes(smith: *Smith, buffer: []u8) []const u8 {
    return buffer[0..smith.slice(buffer)];
}

/// Random bytes rarely get past the lexer: most of them are not even
/// valid characters. Random *tokens* reach the parser, and now and then
/// the checker and the code generator.
const spellings = blk: {
    var list: []const []const u8 = &.{
        "main",   "x", "y", "p",   "f",  "Point",               "i64", "i32",   "u8",     "bool",
        "0",      "1", "2", "255", "-1", "9223372036854775807", "'a'", "'\\n'", "\"hi\"", "\"%ld\\n\"",
        "printf",
    };
    for (std.enums.values(lexer.Token.Tag)) |tag| switch (tag) {
        .int, .char, .string, .identifier, .eof, .invalid => {},
        else => list = list ++ .{tag.lexeme()},
    };
    break :blk list;
};

fn randomTokens(smith: *Smith, buffer: []u8) []const u8 {
    var len: usize = 0;
    while (!smith.eosWeightedSimple(15, 1)) {
        const word = spellings[smith.index(spellings.len)];
        if (len + word.len + 1 > buffer.len) break;
        @memcpy(buffer[len..][0..word.len], word);
        buffer[len + word.len] = ' ';
        len += word.len + 1;
    }
    return buffer[0..len];
}
