//! The back half of the pipeline: QBE IL → assembly (qbe) → executable (cc).
const std = @import("std");
const Io = std.Io;

pub const Error = error{ToolFailed} || std.mem.Allocator.Error || Io.Writer.Error;

/// Writes `il` to EXE.ssa, runs `qbe -o EXE.s EXE.ssa`, then `cc -o EXE EXE.s`.
/// The .ssa and .s files stay next to the executable so you can read them.
pub fn build(gpa: std.mem.Allocator, io: Io, il: []const u8, exe_path: []const u8, stderr: *Io.Writer) Error!void {
    const ssa_path = try std.fmt.allocPrint(gpa, "{s}.ssa", .{exe_path});
    defer gpa.free(ssa_path);
    const asm_path = try std.fmt.allocPrint(gpa, "{s}.s", .{exe_path});
    defer gpa.free(asm_path);

    Io.Dir.cwd().writeFile(io, .{ .sub_path = ssa_path, .data = il }) catch |err| {
        try stderr.print("pebc: cannot write '{s}': {t}\n", .{ ssa_path, err });
        return error.ToolFailed;
    };
    try runTool(gpa, io, &.{ "qbe", "-o", asm_path, ssa_path }, stderr);
    try runTool(gpa, io, &.{ "cc", "-o", exe_path, asm_path }, stderr);
}

/// Runs a program, passes on whatever it printed to stderr, and fails if
/// the program could not start or exited with a nonzero status.
fn runTool(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, stderr: *Io.Writer) Error!void {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch |err| {
        try stderr.print("pebc: cannot run '{s}': {t}\n", .{ argv[0], err });
        return error.ToolFailed;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try stderr.writeAll(result.stderr);
    if (!result.term.success()) {
        try stderr.print("pebc: '{s}' failed\n", .{argv[0]});
        return error.ToolFailed;
    }
}
