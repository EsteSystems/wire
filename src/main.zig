const std = @import("std");
const cli = @import("cli/root.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect command-line args
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    var args_list = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (args_list.items) |arg| allocator.free(arg);
        args_list.deinit();
    }
    while (args_iter.next()) |arg| {
        try args_list.append(try allocator.dupe(u8, arg));
    }
    const args = args_list.items;

    if (args.len < 2) {
        try cli.printUsage(init.io);
        return;
    }

    const first_arg = args[1];

    if (std.mem.eql(u8, first_arg, "--version") or std.mem.eql(u8, first_arg, "-v")) {
        try cli.printVersion(init.io);
        return;
    }

    if (std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h")) {
        try cli.printUsage(init.io);
        return;
    }

    // Check if --json flag is first, find the actual command
    const has_json = args.len > 1 and (std.mem.eql(u8, args[1], "--json") or std.mem.eql(u8, args[1], "-j"));
    const cmd_idx: usize = if (has_json) 2 else 1;

    if (cmd_idx >= args.len) {
        try cli.printUsage(init.io);
        return;
    }

    const subject = args[cmd_idx];
    const post_cmd_args = args[cmd_idx + 1 ..];

    // Build handler args: if --json was global flag, prepend it so handlers can detect it
    var handler_args_list = std.array_list.Managed([]const u8).init(allocator);
    defer handler_args_list.deinit();
    if (has_json) {
        try handler_args_list.append("--json");
    }
    for (post_cmd_args) |arg| {
        try handler_args_list.append(arg);
    }
    const handler_args = handler_args_list.items;

    dispatchCommand(allocator, init.io, subject, handler_args) catch |err| {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_w = std.Io.File.stderr().writerStreaming(init.io, &stderr_buf);
        const stderr = &stderr_w.interface;
        defer stderr.flush() catch {};
        try stderr.print("Error: {}\n", .{err});
        std.process.exit(1);
    };
}

fn dispatchCommand(allocator: std.mem.Allocator, io: std.Io, subject: []const u8, handler_args: []const []const u8) !void {
    if (try cli.dispatch(allocator, io, subject, handler_args)) return;
    // Unknown command
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr = &stderr_w.interface;
    defer stderr.flush() catch {};
    try stderr.print("Unknown command: {s}\n", .{subject});
    try stderr.print("Run 'wire --help' for usage.\n", .{});
}
