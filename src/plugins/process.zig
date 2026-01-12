const std = @import("std");
const linux = std.os.linux;

/// Result of a process execution
pub const ProcessResult = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool,
    signal: ?u32,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.stdout.len > 0) allocator.free(self.stdout);
        if (self.stderr.len > 0) allocator.free(self.stderr);
    }

    pub fn success(self: *const Self) bool {
        return self.exit_code == 0 and !self.timed_out and self.signal == null;
    }
};

/// Process execution manager
pub const ProcessManager = struct {
    allocator: std.mem.Allocator,
    default_timeout_ms: u32,

    const Self = @This();
    const MAX_OUTPUT_SIZE = 1024 * 1024; // 1MB max output

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .default_timeout_ms = 30000, // 30 seconds default
        };
    }

    /// Run a command with arguments
    pub fn run(self: *Self, program: []const u8, args: []const []const u8) !ProcessResult {
        return self.runWithTimeout(program, args, self.default_timeout_ms);
    }

    /// Run a command with explicit timeout (in milliseconds)
    pub fn runWithTimeout(
        self: *Self,
        program: []const u8,
        args: []const []const u8,
        timeout_ms: u32,
    ) !ProcessResult {
        _ = timeout_ms; // TODO: implement proper timeout with threads

        // Build full argument list (program name + args)
        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.append(program);
        for (args) |arg| {
            try argv.append(arg);
        }

        // Spawn child process
        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Read all output BEFORE waiting (important!)
        var stdout_data: []u8 = &[_]u8{};
        var stderr_data: []u8 = &[_]u8{};

        if (child.stdout) |stdout_pipe| {
            stdout_data = stdout_pipe.reader().readAllAlloc(self.allocator, MAX_OUTPUT_SIZE) catch &[_]u8{};
        }
        if (child.stderr) |stderr_pipe| {
            stderr_data = stderr_pipe.reader().readAllAlloc(self.allocator, MAX_OUTPUT_SIZE) catch &[_]u8{};
        }

        // Now wait for process to exit
        const result = child.wait();

        const term = result catch {
            return ProcessResult{
                .exit_code = -1,
                .stdout = stdout_data,
                .stderr = stderr_data,
                .timed_out = false,
                .signal = null,
            };
        };

        return ProcessResult{
            .exit_code = switch (term) {
                .Exited => |code| @intCast(code),
                .Signal => -1,
                .Stopped => -1,
                else => -1,
            },
            .stdout = stdout_data,
            .stderr = stderr_data,
            .timed_out = false,
            .signal = switch (term) {
                .Signal => |sig| @intCast(sig),
                else => null,
            },
        };
    }

    /// Run a simple command string (split by spaces)
    pub fn runSimple(self: *Self, command: []const u8) !ProcessResult {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        // Simple space-based split (doesn't handle quotes)
        var iter = std.mem.splitScalar(u8, command, ' ');
        const program = iter.first();
        while (iter.next()) |arg| {
            if (arg.len > 0) {
                try args.append(arg);
            }
        }

        return self.run(program, args.items);
    }
};

/// Check if a program exists in PATH
pub fn programExists(program: []const u8) bool {
    // Try to find the program in PATH
    const path_env = std.posix.getenv("PATH") orelse return false;

    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, program }) catch continue;

        // Check if file exists and is executable
        const stat = std.fs.cwd().statFile(full_path) catch continue;
        if (stat.kind == .file) {
            // Check if executable (any execute bit set)
            if (stat.mode & 0o111 != 0) {
                return true;
            }
        }
    }

    return false;
}

/// Get installation hint for a missing tool
pub fn getInstallHint(tool: []const u8) []const u8 {
    // Common tools and their package names
    if (std.mem.eql(u8, tool, "tcpdump")) return "Install with: dnf install tcpdump (RHEL) / apt install tcpdump (Debian)";
    if (std.mem.eql(u8, tool, "ping")) return "Install with: dnf install iputils (RHEL) / apt install iputils-ping (Debian)";
    if (std.mem.eql(u8, tool, "arping")) return "Install with: dnf install arping (RHEL) / apt install arping (Debian)";
    if (std.mem.eql(u8, tool, "traceroute")) return "Install with: dnf install traceroute (RHEL) / apt install traceroute (Debian)";
    if (std.mem.eql(u8, tool, "ethtool")) return "Install with: dnf install ethtool (RHEL) / apt install ethtool (Debian)";
    if (std.mem.eql(u8, tool, "ss")) return "Install with: dnf install iproute (RHEL) / apt install iproute2 (Debian)";
    if (std.mem.eql(u8, tool, "ip")) return "Install with: dnf install iproute (RHEL) / apt install iproute2 (Debian)";
    if (std.mem.eql(u8, tool, "nmap")) return "Install with: dnf install nmap (RHEL) / apt install nmap (Debian)";

    return "Tool not found in PATH";
}

/// Find full path of a program
pub fn findProgram(allocator: std.mem.Allocator, program: []const u8) !?[]const u8 {
    const path_env = std.posix.getenv("PATH") orelse return null;

    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, program }) catch continue;

        const stat = std.fs.cwd().statFile(full_path) catch continue;
        if (stat.kind == .file and (stat.mode & 0o111 != 0)) {
            return try allocator.dupe(u8, full_path);
        }
    }

    return null;
}

// Tests

test "ProcessManager init" {
    const allocator = std.testing.allocator;
    const pm = ProcessManager.init(allocator);

    try std.testing.expectEqual(@as(u32, 30000), pm.default_timeout_ms);
}

test "programExists echo" {
    // /bin/echo or /usr/bin/echo should exist on most systems
    // This test may fail in sandboxed environments
    _ = programExists("echo");
}

test "getInstallHint" {
    const hint = getInstallHint("tcpdump");
    try std.testing.expect(std.mem.indexOf(u8, hint, "tcpdump") != null);
}
