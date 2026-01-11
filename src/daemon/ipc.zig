const std = @import("std");
const linux = std.os.linux;
const supervisor = @import("supervisor.zig");
const state_types = @import("../state/types.zig");
const state_live = @import("../state/live.zig");
const state_diff = @import("../state/diff.zig");

/// Default socket path
pub const DEFAULT_SOCKET_PATH = "/var/run/wire.sock";

/// IPC Message Types
pub const MessageType = enum(u8) {
    // Requests (client -> daemon)
    status_request = 1,
    diff_request = 2,
    reload_request = 3,
    stop_request = 4,
    state_request = 5,

    // Responses (daemon -> client)
    status_response = 128,
    diff_response = 129,
    reload_response = 130,
    stop_response = 131,
    state_response = 132,
    error_response = 255,
};

/// IPC Message Header
pub const MessageHeader = extern struct {
    magic: u32 = 0x57495245, // "WIRE"
    msg_type: MessageType,
    _reserved: u8 = 0,
    _reserved2: u16 = 0,
    payload_len: u32,
};

/// Status response data
pub const StatusData = struct {
    state: []const u8,
    pid: i32,
    uptime: i64,
    reconcile_count: u64,
    event_count: u64,
    last_reconcile: i64,
    config_path: []const u8,
};

/// IPC Server - runs in the daemon
pub const IpcServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    socket_fd: ?i32,
    running: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) Self {
        return Self{
            .allocator = allocator,
            .socket_path = socket_path,
            .socket_fd = null,
            .running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start the IPC server
    pub fn start(self: *Self) !void {
        // Remove existing socket file
        std.fs.cwd().deleteFile(self.socket_path) catch {};

        // Create Unix domain socket
        const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (@as(isize, @bitCast(fd)) < 0) {
            return error.SocketCreationFailed;
        }
        self.socket_fd = @intCast(fd);

        // Bind to socket path
        var addr: linux.sockaddr.un = std.mem.zeroes(linux.sockaddr.un);
        addr.family = linux.AF.UNIX;

        const path_bytes = self.socket_path;
        if (path_bytes.len >= addr.path.len) {
            return error.PathTooLong;
        }
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        const bind_result = linux.bind(@intCast(fd), @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
        if (@as(isize, @bitCast(bind_result)) < 0) {
            return error.BindFailed;
        }

        // Listen for connections
        const listen_result = linux.listen(@intCast(fd), 5);
        if (@as(isize, @bitCast(listen_result)) < 0) {
            return error.ListenFailed;
        }

        self.running = true;
    }

    /// Stop the IPC server
    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.socket_fd) |fd| {
            _ = linux.close(@intCast(fd));
            self.socket_fd = null;
        }
        std.fs.cwd().deleteFile(self.socket_path) catch {};
    }

    /// Poll for incoming connections (non-blocking)
    /// Returns true if a message was processed
    pub fn poll(self: *Self, sup: *supervisor.Supervisor) bool {
        if (!self.running or self.socket_fd == null) return false;

        const fd: i32 = self.socket_fd.?;

        // Try to accept a connection
        var client_addr: linux.sockaddr.un = undefined;
        var addr_len: u32 = @sizeOf(linux.sockaddr.un);
        const accept_result = linux.accept4(fd, @ptrCast(&client_addr), &addr_len, linux.SOCK.CLOEXEC);

        if (@as(isize, @bitCast(accept_result)) < 0) {
            const errno = linux.E.init(accept_result);
            if (errno == .AGAIN) {
                return false; // No pending connections
            }
            return false;
        }

        const client_fd: i32 = @intCast(accept_result);
        defer _ = linux.close(@intCast(client_fd));

        // Handle the client request
        self.handleClient(client_fd, sup) catch {};

        return true;
    }

    fn handleClient(self: *Self, client_fd: i32, sup: *supervisor.Supervisor) !void {
        // Read message header
        var header_buf: [@sizeOf(MessageHeader)]u8 = undefined;
        const header_read = linux.read(@intCast(client_fd), &header_buf, header_buf.len);
        if (@as(isize, @bitCast(header_read)) <= 0) {
            return error.ReadFailed;
        }

        const header: *const MessageHeader = @ptrCast(@alignCast(&header_buf));

        // Validate magic
        if (header.magic != 0x57495245) {
            try self.sendError(client_fd, "Invalid protocol magic");
            return;
        }

        // Handle message based on type
        switch (header.msg_type) {
            .status_request => try self.handleStatusRequest(client_fd, sup),
            .diff_request => try self.handleDiffRequest(client_fd, sup),
            .reload_request => try self.handleReloadRequest(client_fd, sup),
            .stop_request => try self.handleStopRequest(client_fd, sup),
            .state_request => try self.handleStateRequest(client_fd),
            else => try self.sendError(client_fd, "Unknown message type"),
        }
    }

    fn handleStatusRequest(self: *Self, client_fd: i32, sup: *supervisor.Supervisor) !void {
        _ = self;
        const status = sup.getStatus();

        // Build response
        var buf: [1024]u8 = undefined;
        const state_name = @tagName(status.state);
        const response = std.fmt.bufPrint(&buf, "state={s}\npid={d}\nuptime={d}\nreconcile_count={d}\nevent_count={d}\nlast_reconcile={d}\nconfig_path={s}\n", .{
            state_name,
            status.pid,
            status.uptime,
            status.reconcile_count,
            status.event_count,
            status.last_reconcile,
            status.config_path,
        }) catch return error.FormatFailed;

        try sendMessage(client_fd, .status_response, response);
    }

    fn handleDiffRequest(self: *Self, client_fd: i32, sup: *supervisor.Supervisor) !void {
        if (sup.desired_state == null) {
            try sendMessage(client_fd, .diff_response, "No desired state configured\n");
            return;
        }

        // Query live state
        var live = state_live.queryLiveState(self.allocator) catch {
            try self.sendError(client_fd, "Failed to query live state");
            return;
        };
        defer live.deinit();

        // Compute diff
        var diff = state_diff.compare(&sup.desired_state.?, &live, self.allocator) catch {
            try self.sendError(client_fd, "Failed to compute diff");
            return;
        };
        defer diff.deinit();

        // Format response
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        if (diff.isEmpty()) {
            writer.print("No drift detected - state is synchronized\n", .{}) catch {};
        } else {
            writer.print("Drift detected: {d} changes needed\n", .{diff.changes.items.len}) catch {};
            for (diff.changes.items) |change| {
                const change_name = @tagName(change);
                writer.print("  - {s}\n", .{change_name}) catch {};
            }
        }

        try sendMessage(client_fd, .diff_response, stream.getWritten());
    }

    fn handleReloadRequest(self: *Self, client_fd: i32, sup: *supervisor.Supervisor) !void {
        _ = self;
        sup.requestReload();
        try sendMessage(client_fd, .reload_response, "Reload requested\n");
    }

    fn handleStopRequest(self: *Self, client_fd: i32, sup: *supervisor.Supervisor) !void {
        _ = self;
        sup.requestStop();
        try sendMessage(client_fd, .stop_response, "Stop requested\n");
    }

    fn handleStateRequest(self: *Self, client_fd: i32) !void {
        // Query and return live state
        var live = state_live.queryLiveState(self.allocator) catch {
            try self.sendError(client_fd, "Failed to query live state");
            return;
        };
        defer live.deinit();

        // Format state response
        var buf: [8192]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        writer.print("Interfaces: {d}\n", .{live.interfaces.items.len}) catch {};
        for (live.interfaces.items) |iface| {
            const state_str = if (iface.isUp()) "UP" else "DOWN";
            writer.print("  {s}: {s} mtu {d}\n", .{ iface.getName(), state_str, iface.mtu }) catch {};
        }

        writer.print("Addresses: {d}\n", .{live.addresses.items.len}) catch {};
        writer.print("Routes: {d}\n", .{live.routes.items.len}) catch {};

        try sendMessage(client_fd, .state_response, stream.getWritten());
    }

    fn sendError(self: *Self, client_fd: i32, message: []const u8) !void {
        _ = self;
        try sendMessage(client_fd, .error_response, message);
    }
};

/// Send a message with header
fn sendMessage(fd: i32, msg_type: MessageType, payload: []const u8) !void {
    const header = MessageHeader{
        .msg_type = msg_type,
        .payload_len = @intCast(payload.len),
    };

    // Send header
    const header_bytes: *const [@sizeOf(MessageHeader)]u8 = @ptrCast(&header);
    var total_sent: usize = 0;
    while (total_sent < header_bytes.len) {
        const sent = linux.write(@intCast(fd), @as([*]const u8, header_bytes) + total_sent, header_bytes.len - total_sent);
        if (@as(isize, @bitCast(sent)) <= 0) {
            return error.WriteFailed;
        }
        total_sent += sent;
    }

    // Send payload
    if (payload.len > 0) {
        total_sent = 0;
        while (total_sent < payload.len) {
            const sent = linux.write(@intCast(fd), payload.ptr + total_sent, payload.len - total_sent);
            if (@as(isize, @bitCast(sent)) <= 0) {
                return error.WriteFailed;
            }
            total_sent += sent;
        }
    }
}

/// IPC Client - used by CLI to communicate with daemon
pub const IpcClient = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) Self {
        return Self{
            .allocator = allocator,
            .socket_path = socket_path,
        };
    }

    /// Connect to daemon and send a request
    pub fn sendRequest(self: *Self, msg_type: MessageType) ![]u8 {
        // Create socket
        const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (@as(isize, @bitCast(fd)) < 0) {
            return error.SocketCreationFailed;
        }
        defer _ = linux.close(@intCast(fd));

        // Connect to server
        var addr: linux.sockaddr.un = std.mem.zeroes(linux.sockaddr.un);
        addr.family = linux.AF.UNIX;
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);

        const connect_result = linux.connect(@intCast(fd), @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
        if (@as(isize, @bitCast(connect_result)) < 0) {
            return error.ConnectionFailed;
        }

        // Send request header (no payload for simple requests)
        const header = MessageHeader{
            .msg_type = msg_type,
            .payload_len = 0,
        };
        const header_bytes: *const [@sizeOf(MessageHeader)]u8 = @ptrCast(&header);
        const write_result = linux.write(@intCast(fd), header_bytes, header_bytes.len);
        if (@as(isize, @bitCast(write_result)) <= 0) {
            return error.WriteFailed;
        }

        // Read response header
        var resp_header_buf: [@sizeOf(MessageHeader)]u8 = undefined;
        const header_read = linux.read(@intCast(fd), &resp_header_buf, resp_header_buf.len);
        if (@as(isize, @bitCast(header_read)) <= 0) {
            return error.ReadFailed;
        }

        const resp_header: *const MessageHeader = @ptrCast(@alignCast(&resp_header_buf));

        // Validate magic
        if (resp_header.magic != 0x57495245) {
            return error.InvalidProtocol;
        }

        // Read payload
        if (resp_header.payload_len == 0) {
            return try self.allocator.alloc(u8, 0);
        }

        const payload = try self.allocator.alloc(u8, resp_header.payload_len);
        errdefer self.allocator.free(payload);

        var total_read: usize = 0;
        while (total_read < payload.len) {
            const read_result = linux.read(@intCast(fd), payload.ptr + total_read, payload.len - total_read);
            if (@as(isize, @bitCast(read_result)) <= 0) {
                return error.ReadFailed;
            }
            total_read += read_result;
        }

        return payload;
    }

    /// Get daemon status
    pub fn getStatus(self: *Self) ![]u8 {
        return self.sendRequest(.status_request);
    }

    /// Get diff between desired and live state
    pub fn getDiff(self: *Self) ![]u8 {
        return self.sendRequest(.diff_request);
    }

    /// Request daemon reload
    pub fn requestReload(self: *Self) ![]u8 {
        return self.sendRequest(.reload_request);
    }

    /// Request daemon stop
    pub fn requestStop(self: *Self) ![]u8 {
        return self.sendRequest(.stop_request);
    }

    /// Get live state
    pub fn getState(self: *Self) ![]u8 {
        return self.sendRequest(.state_request);
    }
};

/// Check if daemon is running by trying to connect to socket
pub fn isDaemonRunning(socket_path: []const u8) bool {
    const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (@as(isize, @bitCast(fd)) < 0) {
        return false;
    }
    defer _ = linux.close(@intCast(fd));

    var addr: linux.sockaddr.un = std.mem.zeroes(linux.sockaddr.un);
    addr.family = linux.AF.UNIX;
    if (socket_path.len >= addr.path.len) {
        return false;
    }
    @memcpy(addr.path[0..socket_path.len], socket_path);

    const result = linux.connect(@intCast(fd), @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
    return @as(isize, @bitCast(result)) >= 0;
}

// Tests

test "MessageHeader size" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(MessageHeader));
}

test "IpcClient init" {
    const allocator = std.testing.allocator;
    const client = IpcClient.init(allocator, "/tmp/test.sock");
    _ = client;
}
