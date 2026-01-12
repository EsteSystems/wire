const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Service entry from /etc/services
pub const Service = struct {
    name: []const u8,
    port: u16,
    protocol: Protocol,
    aliases: []const []const u8,
};

pub const Protocol = enum {
    tcp,
    udp,

    pub fn toString(self: Protocol) []const u8 {
        return switch (self) {
            .tcp => "tcp",
            .udp => "udp",
        };
    }
};

/// Probe result
pub const ProbeResult = struct {
    target: []const u8,
    port: u16,
    protocol: Protocol,
    status: Status,
    latency_us: ?u64, // Microseconds
    error_msg: ?[]const u8,

    pub const Status = enum {
        open, // Connection succeeded
        closed, // Connection refused
        filtered, // Timeout (possibly filtered)
        host_unreachable, // Host unreachable
        error_occurred, // Other error
    };

    pub fn statusString(self: *const ProbeResult) []const u8 {
        return switch (self.status) {
            .open => "open",
            .closed => "closed",
            .filtered => "filtered",
            .host_unreachable => "unreachable",
            .error_occurred => "error",
        };
    }

    pub fn format(self: *const ProbeResult, writer: anytype) !void {
        try writer.print("{s}:{d}/{s} ", .{ self.target, self.port, self.protocol.toString() });

        switch (self.status) {
            .open => {
                if (self.latency_us) |lat| {
                    if (lat < 1000) {
                        try writer.print("OPEN ({d}us)\n", .{lat});
                    } else if (lat < 1000000) {
                        try writer.print("OPEN ({d:.2}ms)\n", .{@as(f64, @floatFromInt(lat)) / 1000.0});
                    } else {
                        try writer.print("OPEN ({d:.2}s)\n", .{@as(f64, @floatFromInt(lat)) / 1000000.0});
                    }
                } else {
                    try writer.print("OPEN\n", .{});
                }
            },
            .closed => try writer.print("CLOSED (connection refused)\n", .{}),
            .filtered => try writer.print("FILTERED (timeout)\n", .{}),
            .host_unreachable => try writer.print("UNREACHABLE (host unreachable)\n", .{}),
            .error_occurred => {
                if (self.error_msg) |msg| {
                    try writer.print("ERROR: {s}\n", .{msg});
                } else {
                    try writer.print("ERROR\n", .{});
                }
            },
        }
    }
};

/// Parse /etc/services and find a service by name
pub fn lookupService(allocator: std.mem.Allocator, name: []const u8, protocol: ?Protocol) !?Service {
    const file = std.fs.openFileAbsolute("/etc/services", .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var reader = buf_reader.reader();

    var line_buf: [512]u8 = undefined;

    while (reader.readUntilDelimiterOrEof(&line_buf, '\n') catch null) |line| {
        // Skip empty lines and comments
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Parse: service-name port/protocol [aliases...]
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");

        const service_name = parts.next() orelse continue;
        const port_proto = parts.next() orelse continue;

        // Parse port/protocol
        var port_parts = std.mem.splitScalar(u8, port_proto, '/');
        const port_str = port_parts.next() orelse continue;
        const proto_str = port_parts.next() orelse continue;

        const port = std.fmt.parseInt(u16, port_str, 10) catch continue;
        const proto: Protocol = if (std.mem.eql(u8, proto_str, "tcp"))
            .tcp
        else if (std.mem.eql(u8, proto_str, "udp"))
            .udp
        else
            continue;

        // Check if protocol matches (if specified)
        if (protocol) |p| {
            if (p != proto) continue;
        }

        // Check name match
        if (std.mem.eql(u8, service_name, name)) {
            // Collect aliases
            var aliases = std.ArrayList([]const u8).init(allocator);
            while (parts.next()) |alias| {
                if (alias[0] == '#') break; // Comment starts
                try aliases.append(try allocator.dupe(u8, alias));
            }

            return Service{
                .name = try allocator.dupe(u8, service_name),
                .port = port,
                .protocol = proto,
                .aliases = try aliases.toOwnedSlice(),
            };
        }

        // Check aliases
        while (parts.next()) |alias| {
            if (alias[0] == '#') break;
            if (std.mem.eql(u8, alias, name)) {
                return Service{
                    .name = try allocator.dupe(u8, service_name),
                    .port = port,
                    .protocol = proto,
                    .aliases = &.{},
                };
            }
        }
    }

    return null;
}

/// Resolve port from service name or numeric string
pub fn resolvePort(allocator: std.mem.Allocator, port_or_service: []const u8, protocol: Protocol) !u16 {
    // Try parsing as number first
    if (std.fmt.parseInt(u16, port_or_service, 10)) |port| {
        return port;
    } else |_| {
        // Try looking up as service name
        if (try lookupServicePort(port_or_service, protocol)) |port| {
            return port;
        }
        _ = allocator; // Unused but kept for API compatibility
        return error.UnknownService;
    }
}

/// Lookup just the port number (no allocations)
pub fn lookupServicePort(name: []const u8, protocol: ?Protocol) !?u16 {
    const file = std.fs.openFileAbsolute("/etc/services", .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var reader = buf_reader.reader();

    var line_buf: [512]u8 = undefined;

    while (reader.readUntilDelimiterOrEof(&line_buf, '\n') catch null) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");

        const service_name = parts.next() orelse continue;
        const port_proto = parts.next() orelse continue;

        var port_parts = std.mem.splitScalar(u8, port_proto, '/');
        const port_str = port_parts.next() orelse continue;
        const proto_str = port_parts.next() orelse continue;

        const port = std.fmt.parseInt(u16, port_str, 10) catch continue;
        const proto: Protocol = if (std.mem.eql(u8, proto_str, "tcp"))
            .tcp
        else if (std.mem.eql(u8, proto_str, "udp"))
            .udp
        else
            continue;

        if (protocol) |p| {
            if (p != proto) continue;
        }

        if (std.mem.eql(u8, service_name, name)) {
            return port;
        }

        // Check aliases
        while (parts.next()) |alias| {
            if (alias[0] == '#') break;
            if (std.mem.eql(u8, alias, name)) {
                return port;
            }
        }
    }

    return null;
}

/// Parse IPv4 address string to bytes
fn parseIPv4(ip: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var current_value: u16 = 0;
    var has_digit = false;

    for (ip) |c| {
        if (c >= '0' and c <= '9') {
            current_value = current_value * 10 + (c - '0');
            if (current_value > 255) return null;
            has_digit = true;
        } else if (c == '.') {
            if (!has_digit or octet_idx >= 3) return null;
            result[octet_idx] = @intCast(current_value);
            octet_idx += 1;
            current_value = 0;
            has_digit = false;
        } else {
            return null;
        }
    }

    if (!has_digit or octet_idx != 3) return null;
    result[3] = @intCast(current_value);

    return result;
}

/// Probe a TCP port on a host
pub fn probeTcp(target: []const u8, port: u16, timeout_ms: u32) ProbeResult {
    const start_time = std.time.microTimestamp();

    // Parse IP address
    const ip_bytes = parseIPv4(target) orelse {
        return ProbeResult{
            .target = target,
            .port = port,
            .protocol = .tcp,
            .status = .error_occurred,
            .latency_us = null,
            .error_msg = "Invalid IP address",
        };
    };

    // Create socket
    const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0) catch {
        return ProbeResult{
            .target = target,
            .port = port,
            .protocol = .tcp,
            .status = .error_occurred,
            .latency_us = null,
            .error_msg = "Failed to create socket",
        };
    };
    defer posix.close(sock);

    // Build address
    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.bytesToValue(u32, &ip_bytes),
    };

    // Attempt non-blocking connect
    const connect_result = posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

    if (connect_result) |_| {
        // Immediate success (rare, but possible on localhost)
        const end_time = std.time.microTimestamp();
        return ProbeResult{
            .target = target,
            .port = port,
            .protocol = .tcp,
            .status = .open,
            .latency_us = @intCast(end_time - start_time),
            .error_msg = null,
        };
    } else |err| {
        if (err != error.WouldBlock) {
            // Immediate error
            const status: ProbeResult.Status = switch (err) {
                error.ConnectionRefused => .closed,
                error.NetworkUnreachable => .host_unreachable,
                else => .error_occurred,
            };
            return ProbeResult{
                .target = target,
                .port = port,
                .protocol = .tcp,
                .status = status,
                .latency_us = null,
                .error_msg = null,
            };
        }
    }

    // Wait for connection with poll
    var fds = [_]posix.pollfd{
        .{
            .fd = sock,
            .events = posix.POLL.OUT,
            .revents = 0,
        },
    };

    const timeout_spec: i32 = @intCast(timeout_ms);
    const poll_result = posix.poll(&fds, timeout_spec) catch {
        return ProbeResult{
            .target = target,
            .port = port,
            .protocol = .tcp,
            .status = .error_occurred,
            .latency_us = null,
            .error_msg = "Poll failed",
        };
    };

    const end_time = std.time.microTimestamp();
    const latency: u64 = @intCast(end_time - start_time);

    if (poll_result == 0) {
        // Timeout
        return ProbeResult{
            .target = target,
            .port = port,
            .protocol = .tcp,
            .status = .filtered,
            .latency_us = latency,
            .error_msg = null,
        };
    }

    // Check if connection succeeded or failed
    if (fds[0].revents & posix.POLL.OUT != 0) {
        // Check for socket error using raw syscall
        var so_error: c_int = 0;
        var optlen: linux.socklen_t = @sizeOf(c_int);
        const rc = linux.getsockopt(sock, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_error), &optlen);

        if (rc != 0) {
            return ProbeResult{
                .target = target,
                .port = port,
                .protocol = .tcp,
                .status = .error_occurred,
                .latency_us = latency,
                .error_msg = "getsockopt failed",
            };
        }

        if (so_error == 0) {
            return ProbeResult{
                .target = target,
                .port = port,
                .protocol = .tcp,
                .status = .open,
                .latency_us = latency,
                .error_msg = null,
            };
        } else {
            // Connection failed
            const status: ProbeResult.Status = switch (so_error) {
                111 => .closed, // ECONNREFUSED
                101, 113 => .host_unreachable, // ENETUNREACH, EHOSTUNREACH
                else => .error_occurred,
            };
            return ProbeResult{
                .target = target,
                .port = port,
                .protocol = .tcp,
                .status = status,
                .latency_us = latency,
                .error_msg = null,
            };
        }
    }

    // Error event
    if (fds[0].revents & posix.POLL.ERR != 0 or fds[0].revents & posix.POLL.HUP != 0) {
        return ProbeResult{
            .target = target,
            .port = port,
            .protocol = .tcp,
            .status = .closed,
            .latency_us = latency,
            .error_msg = null,
        };
    }

    return ProbeResult{
        .target = target,
        .port = port,
        .protocol = .tcp,
        .status = .error_occurred,
        .latency_us = latency,
        .error_msg = "Unknown poll result",
    };
}

/// Probe multiple ports on a host
pub fn probeMultiplePorts(allocator: std.mem.Allocator, target: []const u8, ports: []const u16, timeout_ms: u32) ![]ProbeResult {
    var results = std.ArrayList(ProbeResult).init(allocator);
    errdefer results.deinit();

    for (ports) |port| {
        const result = probeTcp(target, port, timeout_ms);
        try results.append(result);
    }

    return results.toOwnedSlice();
}

/// Common service ports for quick scanning
pub const CommonPorts = struct {
    pub const ssh: u16 = 22;
    pub const telnet: u16 = 23;
    pub const smtp: u16 = 25;
    pub const dns: u16 = 53;
    pub const http: u16 = 80;
    pub const https: u16 = 443;
    pub const mysql: u16 = 3306;
    pub const postgresql: u16 = 5432;
    pub const redis: u16 = 6379;

    pub const quick_scan = [_]u16{ 22, 80, 443, 3306, 5432, 6379 };
    pub const full_scan = [_]u16{ 21, 22, 23, 25, 53, 80, 110, 143, 443, 465, 587, 993, 995, 3306, 3389, 5432, 5900, 6379, 8080, 8443 };
};

// Tests

test "parseIPv4 valid" {
    const result = parseIPv4("192.168.1.1");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 192), result.?[0]);
    try std.testing.expectEqual(@as(u8, 168), result.?[1]);
    try std.testing.expectEqual(@as(u8, 1), result.?[2]);
    try std.testing.expectEqual(@as(u8, 1), result.?[3]);
}

test "parseIPv4 invalid" {
    try std.testing.expect(parseIPv4("256.1.1.1") == null);
    try std.testing.expect(parseIPv4("1.1.1") == null);
    try std.testing.expect(parseIPv4("abc") == null);
}

test "ProbeResult format" {
    var result = ProbeResult{
        .target = "10.0.0.1",
        .port = 22,
        .protocol = .tcp,
        .status = .open,
        .latency_us = 1500,
        .error_msg = null,
    };

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try result.format(stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "OPEN") != null);
}
