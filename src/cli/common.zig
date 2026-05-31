const std = @import("std");
const json_output = @import("../output/json.zig");

/// Context passed to every CLI handler.
pub const CliContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    use_json: bool,
    filtered_args: []const []const u8,

    stdout_buf: [4096]u8 = undefined,
    stderr_buf: [4096]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !CliContext {
        const use_json = json_output.hasJsonFlag(args);
        const filtered_args = try json_output.filterJsonFlag(allocator, args);
        return .{
            .allocator = allocator,
            .io = io,
            .args = args,
            .use_json = use_json,
            .filtered_args = filtered_args,
        };
    }

    pub fn deinit(self: *CliContext) void {
        self.allocator.free(self.filtered_args);
    }

    /// Get a buffered stdout writer. Caller must call stdoutFlush when done.
    pub fn stdout(self: *CliContext) *std.Io.Writer {
        const w = std.Io.File.stdout().writerStreaming(self.io, &self.stdout_buf);
        // Copy to heap to return (we need it to outlive this call)
        // Actually we can't return a writer that borrows a stack variable.
        // Use a different approach: expose a wrapper.
        _ = w;
    }
};

/// Helper to set up stdout/stderr writers and flush on cleanup.
pub fn withStdout(io: std.Io, f: *const fn (*std.Io.Writer, *std.Io.Writer) anyerror!void) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    var stderr_w = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stdout_writer = &stdout_w.interface;
    const stderr_writer = &stderr_w.interface;
    defer stdout_writer.flush() catch {};
    defer stderr_writer.flush() catch {};
    try f(stdout_writer, stderr_writer);
}
