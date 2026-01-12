const std = @import("std");
const process = @import("process.zig");

/// Result status for adapter operations
pub const ResultStatus = enum {
    success,
    failure,
    timeout,
    tool_not_found,
    parse_error,
};

/// Generic adapter result
pub const AdapterResult = struct {
    status: ResultStatus,
    exit_code: i32,
    message: []const u8,
    raw_stdout: []const u8,
    raw_stderr: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.message.len > 0) allocator.free(self.message);
        if (self.raw_stdout.len > 0) allocator.free(self.raw_stdout);
        if (self.raw_stderr.len > 0) allocator.free(self.raw_stderr);
    }

    pub fn isSuccess(self: *const Self) bool {
        return self.status == .success;
    }
};

/// Base adapter configuration
pub const AdapterConfig = struct {
    timeout_ms: u32 = 30000,
    verbose: bool = false,
};

/// Check if a tool is available and return installation hint if not
pub fn checkTool(tool: []const u8, writer: anytype) bool {
    if (process.programExists(tool)) {
        return true;
    }

    writer.print("Error: {s} not found\n", .{tool}) catch {};
    writer.print("{s}\n", .{process.getInstallHint(tool)}) catch {};
    return false;
}

/// Format duration in human-readable form
pub fn formatDuration(ms: f64) [32]u8 {
    var buf: [32]u8 = undefined;
    if (ms < 1.0) {
        _ = std.fmt.bufPrint(&buf, "{d:.3} ms", .{ms}) catch {};
    } else if (ms < 1000.0) {
        _ = std.fmt.bufPrint(&buf, "{d:.2} ms", .{ms}) catch {};
    } else {
        _ = std.fmt.bufPrint(&buf, "{d:.2} s", .{ms / 1000.0}) catch {};
    }
    return buf;
}

// Tests

test "ResultStatus values" {
    try std.testing.expect(@intFromEnum(ResultStatus.success) != @intFromEnum(ResultStatus.failure));
}

test "formatDuration" {
    const result = formatDuration(1.5);
    try std.testing.expect(result[0] == '1');
}
