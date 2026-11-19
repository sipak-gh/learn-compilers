const std = @import("std");
const Io = std.Io;
const diag = @import("diag.zig");
const lexer = @import("lexer.zig");
const Parser = @import("parser.zig").Parser;
const print = @import("print.zig");
const CodeGen = @import("codegen.zig").CodeGen;
const driver = @import("driver.zig");

const usage =
    \\usage: pebc COMMAND FILE [-o OUTPUT]
    \\
    \\commands:
    \\  tokens  print the tokens of FILE
    \\  ast     print the syntax tree of FILE
    \\  ir      print the QBE IL for FILE
    \\  build   compile FILE to an executable (default name: FILE without .peb)
    \\
;

const Command = enum { tokens, ast, ir, build };

pub fn main(init: std.process.Init) !u8 {
    // A compiler runs once and exits, so one arena holds everything.
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const status = try run(arena, init.io, args[1..], stdout, stderr);
    try stdout.flush();
    try stderr.flush();
    return status;
}

/// Runs pebc with the arguments after the program name and returns the
/// exit status: 0 success, 1 the program has errors, 2 bad usage.
fn run(arena: std.mem.Allocator, io: Io, args: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    if (args.len < 2) {
        try stderr.writeAll(usage);
        return 2;
    }
    const command = std.meta.stringToEnum(Command, args[0]) orelse {
        try stderr.print("pebc: unknown command '{s}'\n{s}", .{ args[0], usage });
        return 2;
    };
    const path = args[1];
    var out_path: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else {
            try stderr.print("pebc: unexpected argument '{s}'\n{s}", .{ args[i], usage });
            return 2;
        }
    }

    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch |err| {
        try stderr.print("pebc: cannot read '{s}': {t}\n", .{ path, err });
        return 1;
    };

    const source: diag.Source = .{ .path = path, .text = src };
    var diags: diag.Diagnostics = .init(arena, &source);
    const tokens = try lexer.tokenize(arena, src, &diags);
    if (command == .tokens) {
        try printTokens(stdout, source, tokens);
        try diags.render(stderr);
        return if (diags.hasErrors()) 1 else 0;
    }

    // Each phase runs only if the ones before it found no errors.
    if (diags.hasErrors()) return fail(diags, stderr);
    var parser: Parser = .init(arena, src, tokens, &diags);
    const program = try parser.parseProgram();
    if (diags.hasErrors()) return fail(diags, stderr);
    if (command == .ast) {
        try print.writeProgram(stdout, program);
        return 0;
    }
    var il: Io.Writer.Allocating = .init(arena);
    var gen: CodeGen = .init(arena, &il.writer, &diags);
    gen.genProgram(program) catch |err| switch (err) {
        error.CodegenError => {},
        // Writing to an Allocating writer only fails when memory runs out.
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    if (diags.hasErrors()) return fail(diags, stderr);

    switch (command) {
        .tokens, .ast => unreachable,
        .ir => try stdout.writeAll(il.written()),
        .build => {
            const exe_path = out_path orelse std.fs.path.stem(path);
            driver.build(arena, io, il.written(), exe_path, stderr) catch |err| switch (err) {
                error.ToolFailed => return 1,
                else => |e| return e,
            };
        },
    }
    return 0;
}

fn fail(diags: diag.Diagnostics, stderr: *Io.Writer) !u8 {
    try diags.render(stderr);
    return 1;
}

/// Prints one token per line: position, kind, and text.
fn printTokens(w: *Io.Writer, source: diag.Source, tokens: []const lexer.Token) !void {
    for (tokens) |token| {
        const loc = source.locate(token.span.start);
        var buf: [24]u8 = undefined;
        const pos = try std.fmt.bufPrint(&buf, "{d}:{d}", .{ loc.line, loc.col });
        const text = source.text[token.span.start..token.span.end];
        if (text.len == 0) {
            try w.print("{s:<8}{t}\n", .{ pos, token.tag });
        } else {
            try w.print("{s:<8}{s:<14}{s}\n", .{ pos, @tagName(token.tag), text });
        }
    }
}

test {
    _ = @import("codegen.zig");
    _ = @import("diag.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("print.zig");
}
