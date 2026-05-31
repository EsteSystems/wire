const std = @import("std");
const compat = @import("../../compat.zig");
const posix = std.posix;
const linux = std.os.linux;

/// ICMP packet types
const ICMP_ECHO_REPLY: u8 = 0;
const ICMP_ECHO_REQUEST: u8 = 8;

/// ICMP header structure
const IcmpHeader = extern struct {
    type: u8,
    code: u8,
    checksum: u16,
    identifier: u16,
    sequence: u16,
};

/// Single ping result
pub const PingReply = struct {
    sequence: u16,
    ttl: u8,
    rtt_us: u64, // Round-trip time in microseconds
    received: bool,
};

/// Aggregate ping statistics
pub const PingStats = struct {
    target: []const u8,
    target_ip: [4]u8,
    packets_sent: u32,
    packets_received: u32,
    rtt_min_us: ?u64,
    rtt_max_us: ?u64,
    rtt_sum_us: u64,

    pub fn rttMinMs(self: *const PingStats) ?f64 {
        if (self.rtt_min_us) |min| {
            return @as(f64, @floatFromInt(min)) / 1000.0;
        }
        return null;
    }

    pub fn rttMaxMs(self: *const PingStats) ?f64 {
        if (self.rtt_max_us) |max| {
            return @as(f64, @floatFromInt(max)) / 1000.0;
        }
        return null;
    }

    pub fn rttAvgMs(self: *const PingStats) ?f64 {
        if (self.packets_received > 0) {
            return @as(f64, @floatFromInt(self.rtt_sum_us)) / @as(f64, @floatFromInt(self.packets_received)) / 1000.0;
        }
        return null;
    }

    pub fn packetLossPercent(self: *const PingStats) f64 {
        if (self.packets_sent == 0) return 100.0;
        const lost = self.packets_sent - self.packets_received;
        return @as(f64, @floatFromInt(lost)) / @as(f64, @floatFromInt(self.packets_sent)) * 100.0;
    }

    pub fn isReachable(self: *const PingStats) bool {
        return self.packets_received > 0;
    }

    pub fn format(self: *const PingStats, writer: anytype) !void {
        // Format target IP
        try writer.print("PING {s} ({d}.{d}.{d}.{d})\n", .{
            self.target,
            self.target_ip[0],
            self.target_ip[1],
            self.target_ip[2],
            self.target_ip[3],
        });

        if (self.isReachable()) {
            try writer.print("  Status: REACHABLE\n", .{});
        } else {
            try writer.print("  Status: UNREACHABLE\n", .{});
        }

        try writer.print("  Packets: {d} sent, {d} received, {d:.1}% loss\n", .{
            self.packets_sent,
            self.packets_received,
            self.packetLossPercent(),
        });

        if (self.rttAvgMs()) |avg| {
            try writer.print("  RTT: ", .{});
            if (self.rttMinMs()) |min| {
                try writer.print("min={d:.2}ms ", .{min});
            }
            try writer.print("avg={d:.2}ms ", .{avg});
            if (self.rttMaxMs()) |max| {
                try writer.print("max={d:.2}ms", .{max});
            }
            try writer.print("\n", .{});
        }
    }
};

/// Ping options
pub const PingOptions = struct {
    count: u32 = 4,
    timeout_ms: u32 = 1000, // Per-packet timeout
    interval_ms: u32 = 1000,
    ttl: u8 = 64,
    packet_size: u16 = 56, // Payload size (total ICMP = this + 8 byte header)
    interface: ?[]const u8 = null,
};

/// Native ICMP ping implementation
pub const Pinger = struct {
    allocator: std.mem.Allocator,
    socket: i32,
    identifier: u16,
    sequence: u16,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Create raw ICMP socket
        const sock_fd = linux.socket(
            linux.AF.INET,
            linux.SOCK.RAW | linux.SOCK.CLOEXEC,
            linux.IPPROTO.ICMP,
        );
        if (@as(isize, @bitCast(sock_fd)) >= 0) {
            const sock: i32 = @intCast(sock_fd);
            return Self{
                .allocator = allocator,
                .socket = sock,
                .identifier = @truncate(@as(u64, @bitCast(compat.timestamp()))),
                .sequence = 0,
            };
        }

        // Try DGRAM ICMP (available to unprivileged users on some systems)
        const dgram_fd = linux.socket(
            linux.AF.INET,
            linux.SOCK.DGRAM | linux.SOCK.CLOEXEC,
            linux.IPPROTO.ICMP,
        );
        if (@as(isize, @bitCast(dgram_fd)) < 0) return error.SocketCreationFailed;
        const dgram_sock: i32 = @intCast(dgram_fd);

        return Self{
            .allocator = allocator,
            .socket = dgram_sock,
            .identifier = @truncate(@as(u64, @bitCast(compat.timestamp()))),
            .sequence = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = linux.close(self.socket);
    }

    /// Set socket options
    pub fn configure(self: *Self, options: PingOptions) !void {
        // Set TTL
        const ttl_val: i32 = options.ttl;
        _ = linux.setsockopt(self.socket, linux.IPPROTO.IP, linux.IP.TTL, std.mem.asBytes(&ttl_val), @sizeOf(u8));

        // Set receive timeout
        const timeout_sec = options.timeout_ms / 1000;
        const timeout_usec = (options.timeout_ms % 1000) * 1000;
        const tv = linux.timeval{
            .sec = @intCast(timeout_sec),
            .usec = @intCast(timeout_usec),
        };
        _ = linux.setsockopt(self.socket, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));

        // Bind to interface if specified
        if (options.interface) |iface| {
            var iface_buf: [16]u8 = undefined;
            const len = @min(iface.len, 15);
            @memcpy(iface_buf[0..len], iface[0..len]);
            iface_buf[len] = 0;
            _ = linux.setsockopt(self.socket, linux.SOL.SOCKET, linux.SO.BINDTODEVICE, iface_buf[0..len].ptr, @intCast(len + 1));
        }
    }

    /// Resolve hostname to IPv4 address
    /// Note: Only supports IP addresses, not DNS hostnames (for embedded portability)
    pub fn resolveHost(self: *Self, host: []const u8) !?[4]u8 {
        _ = self;

        // Parse IP address directly (no DNS for embedded portability)
        return parseIPv4(host);
    }

    /// Send a single ping and wait for reply
    pub fn pingOnce(self: *Self, target_ip: [4]u8, options: PingOptions) !PingReply {
        self.sequence +%= 1;
        const seq = self.sequence;

        // Build ICMP packet using byte-level access (avoids alignment issues)
        var packet: [65535]u8 = undefined;

        // ICMP header: type(1) + code(1) + checksum(2) + id(2) + seq(2) = 8 bytes
        packet[0] = ICMP_ECHO_REQUEST; // type
        packet[1] = 0; // code
        packet[2] = 0; // checksum (placeholder)
        packet[3] = 0; // checksum (placeholder)
        // identifier (network byte order = big endian)
        packet[4] = @truncate(self.identifier >> 8);
        packet[5] = @truncate(self.identifier);
        // sequence (network byte order = big endian)
        packet[6] = @truncate(seq >> 8);
        packet[7] = @truncate(seq);

        // Add timestamp to payload
        const payload_start: usize = 8; // ICMP header size
        const payload_size = @min(options.packet_size, packet.len - payload_start);
        const timestamp = compat.microTimestamp();
        if (payload_size >= 8) {
            const ts_bytes: [8]u8 = @bitCast(timestamp);
            @memcpy(packet[payload_start .. payload_start + 8], &ts_bytes);
        }

        // Fill rest with pattern
        for (payload_start + 8..payload_start + payload_size) |i| {
            packet[i] = @truncate(i);
        }

        const total_size = payload_start + payload_size;

        // Calculate checksum
        const checksum = icmpChecksum(packet[0..total_size]);
        packet[2] = @truncate(checksum);
        packet[3] = @truncate(checksum >> 8);

        // Prepare destination address
        var dest_addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = 0,
            .addr = @bitCast(target_ip),
            .zero = [_]u8{0} ** 8,
        };

        // Send packet
        const send_time = compat.microTimestamp();
        _ = linux.sendto(
            self.socket,
            &packet,
            total_size,
            0,
            @ptrCast(&dest_addr),
            @sizeOf(linux.sockaddr.in),
        );
        // sendto returns usize; negative means error, ignore send errors for ping

        // Wait for reply
        var recv_buf: [65535]u8 = undefined;
        var src_addr: linux.sockaddr.in = undefined;
        var addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);

        while (true) {
            const recv_result = linux.recvfrom(
                self.socket,
                &recv_buf,
                recv_buf.len,
                0,
                @ptrCast(&src_addr),
                &addr_len,
            );

            const bytes_received = @as(isize, @bitCast(recv_result));
            if (bytes_received > 0) {
                const recv_time = compat.microTimestamp();

                if (@as(usize, @intCast(bytes_received)) < 28) continue; // IP header (20) + ICMP header (8)

                // Skip IP header (usually 20 bytes, but check IHL)
                const ip_header_len: usize = (@as(usize, recv_buf[0]) & 0x0F) * 4;
                if (@as(usize, @intCast(bytes_received)) < ip_header_len + 8) continue;

                // Parse ICMP header from bytes (avoids alignment issues)
                const icmp_start = ip_header_len;
                const recv_type = recv_buf[icmp_start];
                const recv_id = (@as(u16, recv_buf[icmp_start + 4]) << 8) | recv_buf[icmp_start + 5];
                const recv_seq = (@as(u16, recv_buf[icmp_start + 6]) << 8) | recv_buf[icmp_start + 7];

                // Check if this is our echo reply
                if (recv_type == ICMP_ECHO_REPLY and
                    recv_id == self.identifier and
                    recv_seq == seq)
                {
                    const ttl = recv_buf[8]; // TTL is at offset 8 in IP header
                    const rtt = @as(u64, @intCast(recv_time - send_time));

                    return PingReply{
                        .sequence = seq,
                        .ttl = ttl,
                        .rtt_us = rtt,
                        .received = true,
                    };
                }
                // Not our packet, keep waiting (until timeout)
            } else {
                // Timeout or error
                break;
            }
        }

        return PingReply{
            .sequence = seq,
            .ttl = 0,
            .rtt_us = 0,
            .received = false,
        };
    }

    /// Run a full ping test with multiple packets
    pub fn ping(self: *Self, target: []const u8, options: PingOptions) !PingStats {
        // Resolve target
        const target_ip = try self.resolveHost(target) orelse {
            return PingStats{
                .target = target,
                .target_ip = [_]u8{ 0, 0, 0, 0 },
                .packets_sent = 0,
                .packets_received = 0,
                .rtt_min_us = null,
                .rtt_max_us = null,
                .rtt_sum_us = 0,
            };
        };

        try self.configure(options);

        var stats = PingStats{
            .target = target,
            .target_ip = target_ip,
            .packets_sent = 0,
            .packets_received = 0,
            .rtt_min_us = null,
            .rtt_max_us = null,
            .rtt_sum_us = 0,
        };

        var i: u32 = 0;
        while (i < options.count) : (i += 1) {
            if (i > 0) {
                // Wait interval between pings
                    var ts: linux.timespec = .{
        .sec = @intCast((options.interval_ms * std.time.ns_per_ms) / std.time.ns_per_s),
        .nsec = @intCast((options.interval_ms * std.time.ns_per_ms) % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&ts, null);
            }

            const reply = try self.pingOnce(target_ip, options);
            stats.packets_sent += 1;

            if (reply.received) {
                stats.packets_received += 1;
                stats.rtt_sum_us += reply.rtt_us;

                if (stats.rtt_min_us == null or reply.rtt_us < stats.rtt_min_us.?) {
                    stats.rtt_min_us = reply.rtt_us;
                }
                if (stats.rtt_max_us == null or reply.rtt_us > stats.rtt_max_us.?) {
                    stats.rtt_max_us = reply.rtt_us;
                }
            }
        }

        return stats;
    }
};

/// Calculate ICMP checksum (RFC 1071)
fn icmpChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    // Sum 16-bit words
    while (i + 1 < data.len) : (i += 2) {
        const word = @as(u16, data[i]) | (@as(u16, data[i + 1]) << 8);
        sum += word;
    }

    // Add odd byte if present
    if (i < data.len) {
        sum += data[i];
    }

    // Fold 32-bit sum to 16 bits
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~@as(u16, @truncate(sum));
}

/// Parse IPv4 address string
fn parseIPv4(s: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var part: usize = 0;
    var value: u16 = 0;
    var has_digit = false;

    for (s) |c| {
        if (c >= '0' and c <= '9') {
            value = value * 10 + (c - '0');
            if (value > 255) return null;
            has_digit = true;
        } else if (c == '.') {
            if (!has_digit or part >= 3) return null;
            result[part] = @truncate(value);
            part += 1;
            value = 0;
            has_digit = false;
        } else {
            return null;
        }
    }

    if (!has_digit or part != 3) return null;
    result[3] = @truncate(value);
    return result;
}

/// Convenience function for simple ping
pub fn ping(allocator: std.mem.Allocator, target: []const u8, options: PingOptions) !PingStats {
    var pinger = try Pinger.init(allocator);
    defer pinger.deinit();
    return pinger.ping(target, options);
}

/// Quick reachability check
pub fn isReachable(allocator: std.mem.Allocator, target: []const u8) !bool {
    const stats = try ping(allocator, target, .{ .count = 1, .timeout_ms = 3000 });
    return stats.isReachable();
}

// Tests

test "parseIPv4" {
    const ip = parseIPv4("192.168.1.1");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual(@as(u8, 192), ip.?[0]);
    try std.testing.expectEqual(@as(u8, 168), ip.?[1]);
    try std.testing.expectEqual(@as(u8, 1), ip.?[2]);
    try std.testing.expectEqual(@as(u8, 1), ip.?[3]);
}

test "parseIPv4 invalid" {
    try std.testing.expect(parseIPv4("256.1.1.1") == null);
    try std.testing.expect(parseIPv4("1.2.3") == null);
    try std.testing.expect(parseIPv4("not.an.ip.addr") == null);
}

test "icmpChecksum" {
    // Simple test - checksum of zeros should be 0xFFFF
    var data = [_]u8{ 0, 0, 0, 0 };
    const cs = icmpChecksum(&data);
    try std.testing.expectEqual(@as(u16, 0xFFFF), cs);
}
