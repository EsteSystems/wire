const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// ICMP packet types
const ICMP_ECHO_REPLY: u8 = 0;
const ICMP_DEST_UNREACHABLE: u8 = 3;
const ICMP_ECHO_REQUEST: u8 = 8;
const ICMP_TIME_EXCEEDED: u8 = 11;

/// Information about a single hop
pub const TraceHop = struct {
    ttl: u8,
    addr: ?[4]u8, // IP address of responding router (null if no response)
    rtt_us: [3]?u64, // Up to 3 RTT measurements per hop
    probes_sent: u8,
    probes_received: u8,
    reached_target: bool,

    pub fn formatAddr(self: *const TraceHop, buf: []u8) []const u8 {
        if (self.addr) |a| {
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }) catch "*";
        }
        return "*";
    }

    pub fn format(self: *const TraceHop, writer: anytype) !void {
        var addr_buf: [16]u8 = undefined;
        const addr_str = self.formatAddr(&addr_buf);

        try writer.print("{d:>2}  {s:<16}", .{ self.ttl, addr_str });

        // Print RTT values
        for (self.rtt_us) |rtt| {
            if (rtt) |r| {
                const ms = @as(f64, @floatFromInt(r)) / 1000.0;
                try writer.print("  {d:>6.2} ms", .{ms});
            } else {
                try writer.print("       *   ", .{});
            }
        }
        try writer.print("\n", .{});
    }
};

/// Complete traceroute result
pub const TraceResult = struct {
    target: []const u8,
    target_ip: [4]u8,
    hops: std.array_list.Managed(TraceHop),
    reached: bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, target: []const u8, target_ip: [4]u8) Self {
        return Self{
            .target = target,
            .target_ip = target_ip,
            .hops = std.array_list.Managed(TraceHop).init(allocator),
            .reached = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.hops.deinit();
    }

    pub fn format(self: *const Self, writer: anytype) !void {
        try writer.print("traceroute to {s} ({d}.{d}.{d}.{d}), {d} hops max\n", .{
            self.target,
            self.target_ip[0],
            self.target_ip[1],
            self.target_ip[2],
            self.target_ip[3],
            self.hops.items.len,
        });

        for (self.hops.items) |*hop| {
            try hop.format(writer);
        }

        if (self.reached) {
            try writer.print("\nDestination reached.\n", .{});
        } else {
            try writer.print("\nDestination not reached within hop limit.\n", .{});
        }
    }
};

/// Traceroute options
pub const TraceOptions = struct {
    max_hops: u8 = 30,
    probes_per_hop: u8 = 3,
    timeout_ms: u32 = 1000, // Per-probe timeout
    initial_ttl: u8 = 1,
    packet_size: u16 = 40, // Payload size
    interface: ?[]const u8 = null,
};

/// Native ICMP traceroute implementation
pub const Tracer = struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    identifier: u16,
    sequence: u16,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Create raw ICMP socket
        const sock = posix.socket(
            posix.AF.INET,
            posix.SOCK.RAW | posix.SOCK.CLOEXEC,
            posix.IPPROTO.ICMP,
        ) catch |err| {
            if (err == error.PermissionDenied) {
                // Try DGRAM ICMP (available to unprivileged users on some systems)
                return Self{
                    .allocator = allocator,
                    .socket = try posix.socket(
                        posix.AF.INET,
                        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
                        posix.IPPROTO.ICMP,
                    ),
                    .identifier = @truncate(@as(u64, @bitCast(std.time.timestamp())) ^ 0xABCD),
                    .sequence = 0,
                };
            }
            return err;
        };

        return Self{
            .allocator = allocator,
            .socket = sock,
            .identifier = @truncate(@as(u64, @bitCast(std.time.timestamp())) ^ 0xABCD),
            .sequence = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.socket);
    }

    /// Set socket options for a specific TTL
    fn setTTL(self: *Self, ttl: u8) !void {
        const ttl_val: i32 = ttl;
        try posix.setsockopt(self.socket, posix.IPPROTO.IP, linux.IP.TTL, std.mem.asBytes(&ttl_val));
    }

    /// Set receive timeout
    fn setTimeout(self: *Self, timeout_ms: u32) !void {
        const timeout_sec = timeout_ms / 1000;
        const timeout_usec = (timeout_ms % 1000) * 1000;
        const tv = posix.timeval{
            .sec = @intCast(timeout_sec),
            .usec = @intCast(timeout_usec),
        };
        try posix.setsockopt(self.socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
    }

    /// Bind to interface if specified
    fn bindInterface(self: *Self, interface: ?[]const u8) void {
        if (interface) |iface| {
            var iface_buf: [16]u8 = undefined;
            const len = @min(iface.len, 15);
            @memcpy(iface_buf[0..len], iface[0..len]);
            iface_buf[len] = 0;
            posix.setsockopt(self.socket, posix.SOL.SOCKET, posix.SO.BINDTODEVICE, iface_buf[0 .. len + 1]) catch {};
        }
    }

    /// Send a single probe and wait for response
    fn sendProbe(self: *Self, target_ip: [4]u8, ttl: u8, timeout_ms: u32) !struct { addr: ?[4]u8, rtt_us: ?u64, reached: bool } {
        self.sequence +%= 1;
        const seq = self.sequence;

        // Set TTL for this probe
        try self.setTTL(ttl);
        try self.setTimeout(timeout_ms);

        // Build ICMP Echo Request packet
        var packet: [128]u8 = undefined;
        packet[0] = ICMP_ECHO_REQUEST; // type
        packet[1] = 0; // code
        packet[2] = 0; // checksum (placeholder)
        packet[3] = 0;
        // identifier (network byte order)
        packet[4] = @truncate(self.identifier >> 8);
        packet[5] = @truncate(self.identifier);
        // sequence (network byte order)
        packet[6] = @truncate(seq >> 8);
        packet[7] = @truncate(seq);

        // Payload with timestamp
        const timestamp = std.time.microTimestamp();
        const ts_bytes: [8]u8 = @bitCast(timestamp);
        @memcpy(packet[8..16], &ts_bytes);

        // Fill rest with pattern
        for (16..64) |i| {
            packet[i] = @truncate(i);
        }

        const total_size: usize = 64;

        // Calculate checksum
        const checksum = icmpChecksum(packet[0..total_size]);
        packet[2] = @truncate(checksum);
        packet[3] = @truncate(checksum >> 8);

        // Destination address
        var dest_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = 0,
            .addr = @bitCast(target_ip),
            .zero = [_]u8{0} ** 8,
        };

        // Send
        const send_time = std.time.microTimestamp();
        _ = posix.sendto(
            self.socket,
            packet[0..total_size],
            0,
            @ptrCast(&dest_addr),
            @sizeOf(posix.sockaddr.in),
        ) catch {
            return .{ .addr = null, .rtt_us = null, .reached = false };
        };

        // Wait for response
        var recv_buf: [512]u8 = undefined;
        var src_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        // Try to receive (may get ICMP Time Exceeded or Echo Reply)
        const recv_result = posix.recvfrom(
            self.socket,
            &recv_buf,
            0,
            @ptrCast(&src_addr),
            &addr_len,
        );

        if (recv_result) |bytes_received| {
            const recv_time = std.time.microTimestamp();
            const rtt = @as(u64, @intCast(recv_time - send_time));

            if (bytes_received < 28) {
                return .{ .addr = null, .rtt_us = null, .reached = false };
            }

            // Parse IP header to get source address and find ICMP
            const ip_header_len: usize = (@as(usize, recv_buf[0]) & 0x0F) * 4;
            if (bytes_received < ip_header_len + 8) {
                return .{ .addr = null, .rtt_us = null, .reached = false };
            }

            // Source IP is at offset 12 in IP header
            const src_ip: [4]u8 = recv_buf[12..16].*;

            // Parse ICMP header
            const icmp_start = ip_header_len;
            const icmp_type = recv_buf[icmp_start];

            if (icmp_type == ICMP_TIME_EXCEEDED) {
                // Time Exceeded - intermediate hop responded
                // The original packet is embedded after the ICMP header (8 bytes)
                // We should verify it's our packet by checking the embedded ICMP id/seq
                if (bytes_received >= icmp_start + 8 + 20 + 8) {
                    const embedded_ip_start = icmp_start + 8;
                    const embedded_ip_hdr_len: usize = (@as(usize, recv_buf[embedded_ip_start]) & 0x0F) * 4;
                    const embedded_icmp_start = embedded_ip_start + embedded_ip_hdr_len;

                    if (bytes_received >= embedded_icmp_start + 8) {
                        const embedded_id = (@as(u16, recv_buf[embedded_icmp_start + 4]) << 8) | recv_buf[embedded_icmp_start + 5];
                        const embedded_seq = (@as(u16, recv_buf[embedded_icmp_start + 6]) << 8) | recv_buf[embedded_icmp_start + 7];

                        if (embedded_id == self.identifier and embedded_seq == seq) {
                            return .{ .addr = src_ip, .rtt_us = rtt, .reached = false };
                        }
                    }
                }
                // Even if we can't verify, assume it's ours (best effort)
                return .{ .addr = src_ip, .rtt_us = rtt, .reached = false };
            } else if (icmp_type == ICMP_ECHO_REPLY) {
                // Echo Reply - reached destination
                const recv_id = (@as(u16, recv_buf[icmp_start + 4]) << 8) | recv_buf[icmp_start + 5];
                const recv_seq = (@as(u16, recv_buf[icmp_start + 6]) << 8) | recv_buf[icmp_start + 7];

                if (recv_id == self.identifier and recv_seq == seq) {
                    return .{ .addr = src_ip, .rtt_us = rtt, .reached = true };
                }
            } else if (icmp_type == ICMP_DEST_UNREACHABLE) {
                // Destination unreachable - also means we reached final network
                return .{ .addr = src_ip, .rtt_us = rtt, .reached = true };
            }

            // Unknown response, treat as no response
            return .{ .addr = null, .rtt_us = null, .reached = false };
        } else |_| {
            // Timeout
            return .{ .addr = null, .rtt_us = null, .reached = false };
        }
    }

    /// Run full traceroute
    pub fn trace(self: *Self, target: []const u8, options: TraceOptions) !TraceResult {
        // Parse target IP
        const target_ip = parseIPv4(target) orelse {
            return TraceResult.init(self.allocator, target, [_]u8{ 0, 0, 0, 0 });
        };

        self.bindInterface(options.interface);

        var result = TraceResult.init(self.allocator, target, target_ip);

        var ttl: u8 = options.initial_ttl;
        while (ttl <= options.max_hops) : (ttl += 1) {
            var hop = TraceHop{
                .ttl = ttl,
                .addr = null,
                .rtt_us = [_]?u64{ null, null, null },
                .probes_sent = 0,
                .probes_received = 0,
                .reached_target = false,
            };

            // Send probes for this TTL
            var probe: u8 = 0;
            while (probe < options.probes_per_hop) : (probe += 1) {
                hop.probes_sent += 1;

                const probe_result = try self.sendProbe(target_ip, ttl, options.timeout_ms);

                if (probe_result.addr) |addr| {
                    hop.addr = addr;
                    hop.probes_received += 1;
                }
                if (probe_result.rtt_us) |rtt| {
                    if (probe < 3) {
                        hop.rtt_us[probe] = rtt;
                    }
                }
                if (probe_result.reached) {
                    hop.reached_target = true;
                }
            }

            try result.hops.append(hop);

            // Stop if we reached the destination
            if (hop.reached_target) {
                result.reached = true;
                break;
            }

            // Also stop if we got a response from the target IP itself
            if (hop.addr) |addr| {
                if (std.mem.eql(u8, &addr, &target_ip)) {
                    result.reached = true;
                    break;
                }
            }
        }

        return result;
    }
};

/// Calculate ICMP checksum (RFC 1071)
fn icmpChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) {
        const word = @as(u16, data[i]) | (@as(u16, data[i + 1]) << 8);
        sum += word;
    }

    if (i < data.len) {
        sum += data[i];
    }

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

/// Convenience function for simple traceroute
pub fn trace(allocator: std.mem.Allocator, target: []const u8, options: TraceOptions) !TraceResult {
    var tracer = try Tracer.init(allocator);
    defer tracer.deinit();
    return tracer.trace(target, options);
}

// Tests

test "parseIPv4" {
    const ip = parseIPv4("8.8.8.8");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual(@as(u8, 8), ip.?[0]);
}

test "icmpChecksum" {
    var data = [_]u8{ 0, 0, 0, 0 };
    const cs = icmpChecksum(&data);
    try std.testing.expectEqual(@as(u16, 0xFFFF), cs);
}
