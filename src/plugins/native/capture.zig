const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Ethernet header size
const ETH_HLEN: usize = 14;

/// Ethernet protocol types
const ETH_P_ALL: u16 = 0x0003;
const ETH_P_IP: u16 = 0x0800;
const ETH_P_ARP: u16 = 0x0806;
const ETH_P_IPV6: u16 = 0x86DD;
const ETH_P_8021Q: u16 = 0x8100; // VLAN

/// IP protocol numbers
const IPPROTO_ICMP: u8 = 1;
const IPPROTO_TCP: u8 = 6;
const IPPROTO_UDP: u8 = 17;
const IPPROTO_ICMPV6: u8 = 58;

/// Captured packet information
pub const PacketInfo = struct {
    timestamp_us: i64,
    length: usize,
    // Ethernet
    src_mac: [6]u8,
    dst_mac: [6]u8,
    eth_proto: u16,
    vlan_id: ?u16,
    // IP (if applicable)
    src_ip: ?[16]u8,
    dst_ip: ?[16]u8,
    ip_version: ?u8,
    ip_proto: ?u8,
    // Ports (if TCP/UDP)
    src_port: ?u16,
    dst_port: ?u16,

    const Self = @This();

    pub fn formatMac(mac: [6]u8, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
        }) catch "??:??:??:??:??:??";
    }

    pub fn formatIP(ip: ?[16]u8, version: ?u8, buf: []u8) []const u8 {
        if (ip == null or version == null) return "?";

        if (version.? == 4) {
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                ip.?[0], ip.?[1], ip.?[2], ip.?[3],
            }) catch "?.?.?.?";
        } else if (version.? == 6) {
            // Simplified IPv6 format
            return std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:...:{x:0>2}{x:0>2}", .{
                ip.?[0],  ip.?[1],  ip.?[2],  ip.?[3],
                ip.?[14], ip.?[15],
            }) catch "?::?";
        }
        return "?";
    }

    pub fn protoName(self: *const Self) []const u8 {
        if (self.eth_proto == ETH_P_ARP) return "ARP";

        if (self.ip_proto) |proto| {
            return switch (proto) {
                IPPROTO_ICMP => "ICMP",
                IPPROTO_ICMPV6 => "ICMPv6",
                IPPROTO_TCP => "TCP",
                IPPROTO_UDP => "UDP",
                else => "IP",
            };
        }

        return switch (self.eth_proto) {
            ETH_P_IP => "IPv4",
            ETH_P_IPV6 => "IPv6",
            ETH_P_8021Q => "VLAN",
            else => "ETH",
        };
    }

    pub fn format(self: *const Self, writer: anytype) !void {
        // Timestamp (relative seconds.microseconds)
        const secs = @divFloor(self.timestamp_us, 1_000_000);
        const usecs = @mod(self.timestamp_us, 1_000_000);
        try writer.print("{d:>5}.{d:0>6} ", .{ secs, @as(u64, @intCast(if (usecs < 0) -usecs else usecs)) });

        // Protocol
        try writer.print("{s:<6} ", .{self.protoName()});

        // Length
        try writer.print("{d:>4} ", .{self.length});

        // Source
        if (self.src_ip != null) {
            var buf: [48]u8 = undefined;
            const ip_str = formatIP(self.src_ip, self.ip_version, &buf);
            if (self.src_port) |port| {
                try writer.print("{s}:{d:<5} ", .{ ip_str, port });
            } else {
                try writer.print("{s:<21} ", .{ip_str});
            }
        } else {
            var buf: [18]u8 = undefined;
            try writer.print("{s:<21} ", .{formatMac(self.src_mac, &buf)});
        }

        try writer.print("> ", .{});

        // Destination
        if (self.dst_ip != null) {
            var buf: [48]u8 = undefined;
            const ip_str = formatIP(self.dst_ip, self.ip_version, &buf);
            if (self.dst_port) |port| {
                try writer.print("{s}:{d}", .{ ip_str, port });
            } else {
                try writer.print("{s}", .{ip_str});
            }
        } else {
            var buf: [18]u8 = undefined;
            try writer.print("{s}", .{formatMac(self.dst_mac, &buf)});
        }

        // VLAN tag if present
        if (self.vlan_id) |vid| {
            try writer.print(" vlan:{d}", .{vid});
        }

        try writer.print("\n", .{});
    }
};

/// Capture statistics
pub const CaptureStats = struct {
    packets_captured: u64,
    bytes_captured: u64,
    packets_dropped: u64,
    start_time_us: i64,

    pub fn format(self: *const CaptureStats, writer: anytype) !void {
        const elapsed_us = std.time.microTimestamp() - self.start_time_us;
        const elapsed_secs = @as(f64, @floatFromInt(elapsed_us)) / 1_000_000.0;

        try writer.print("\n--- Capture Statistics ---\n", .{});
        try writer.print("Packets captured: {d}\n", .{self.packets_captured});
        try writer.print("Bytes captured: {d}\n", .{self.bytes_captured});
        if (self.packets_dropped > 0) {
            try writer.print("Packets dropped: {d}\n", .{self.packets_dropped});
        }
        try writer.print("Duration: {d:.2}s\n", .{elapsed_secs});
        if (elapsed_secs > 0) {
            const pps = @as(f64, @floatFromInt(self.packets_captured)) / elapsed_secs;
            try writer.print("Rate: {d:.1} packets/sec\n", .{pps});
        }
    }
};

/// Capture options
pub const CaptureOptions = struct {
    interface: ?[]const u8 = null, // null = all interfaces
    count: ?u32 = null, // null = unlimited
    duration_secs: ?u32 = null, // null = unlimited
    snaplen: u32 = 65535, // Max bytes to capture per packet
    promisc: bool = true, // Promiscuous mode
    // Simple filters (no BPF compilation for embedded simplicity)
    filter_proto: ?u8 = null, // IP protocol number
    filter_port: ?u16 = null, // TCP/UDP port
    filter_host: ?[4]u8 = null, // IPv4 address
};

/// Native packet capture implementation
pub const Capturer = struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    options: CaptureOptions,
    stats: CaptureStats,
    start_time_us: i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, options: CaptureOptions) !Self {
        // Create raw packet socket
        // AF_PACKET = 17, SOCK_RAW = 3, ETH_P_ALL = 0x0003
        const sock = try posix.socket(
            linux.AF.PACKET,
            posix.SOCK.RAW,
            std.mem.nativeToBig(u16, ETH_P_ALL),
        );
        errdefer posix.close(sock);

        var self = Self{
            .allocator = allocator,
            .socket = sock,
            .options = options,
            .stats = CaptureStats{
                .packets_captured = 0,
                .bytes_captured = 0,
                .packets_dropped = 0,
                .start_time_us = std.time.microTimestamp(),
            },
            .start_time_us = std.time.microTimestamp(),
        };

        try self.configure();
        return self;
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.socket);
    }

    fn configure(self: *Self) !void {
        // Bind to specific interface if requested
        if (self.options.interface) |iface| {
            var ifr: linux.ifreq = std.mem.zeroes(linux.ifreq);
            const name_len = @min(iface.len, ifr.ifrn.name.len - 1);
            @memcpy(ifr.ifrn.name[0..name_len], iface[0..name_len]);

            // Get interface index
            const SIOCGIFINDEX = 0x8933;
            const result = linux.ioctl(self.socket, SIOCGIFINDEX, @intFromPtr(&ifr));
            if (result < 0) {
                return error.InterfaceNotFound;
            }

            // Bind to interface
            var sll: linux.sockaddr.ll = std.mem.zeroes(linux.sockaddr.ll);
            sll.family = linux.AF.PACKET;
            sll.protocol = std.mem.nativeToBig(u16, ETH_P_ALL);
            sll.ifindex = ifr.ifru.ivalue;

            try posix.bind(self.socket, @ptrCast(&sll), @sizeOf(linux.sockaddr.ll));

            // Set promiscuous mode if requested
            if (self.options.promisc) {
                var mreq: PacketMreq = std.mem.zeroes(PacketMreq);
                mreq.mr_ifindex = ifr.ifru.ivalue;
                mreq.mr_type = PACKET_MR_PROMISC;

                posix.setsockopt(
                    self.socket,
                    SOL_PACKET,
                    PACKET_ADD_MEMBERSHIP,
                    std.mem.asBytes(&mreq),
                ) catch {}; // Ignore if promisc fails
            }
        }

        // Set receive timeout for interruptible capture
        const tv = posix.timeval{
            .sec = 1,
            .usec = 0,
        };
        try posix.setsockopt(self.socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
    }

    /// Capture a single packet
    pub fn captureOne(self: *Self) !?PacketInfo {
        var buf: [65536]u8 = undefined;
        var src_addr: linux.sockaddr.ll = undefined;
        var addr_len: posix.socklen_t = @sizeOf(linux.sockaddr.ll);

        const recv_result = posix.recvfrom(
            self.socket,
            &buf,
            0,
            @ptrCast(&src_addr),
            &addr_len,
        );

        if (recv_result) |len| {
            if (len < ETH_HLEN) return null;

            const pkt = self.parsePacket(buf[0..len]);

            // Apply filters
            if (!self.matchesFilter(&pkt)) return null;

            self.stats.packets_captured += 1;
            self.stats.bytes_captured += len;

            return pkt;
        } else |err| {
            if (err == error.WouldBlock) return null;
            return err;
        }
    }

    /// Parse packet headers
    fn parsePacket(self: *Self, data: []const u8) PacketInfo {
        var pkt = PacketInfo{
            .timestamp_us = std.time.microTimestamp() - self.start_time_us,
            .length = data.len,
            .dst_mac = data[0..6].*,
            .src_mac = data[6..12].*,
            .eth_proto = (@as(u16, data[12]) << 8) | data[13],
            .vlan_id = null,
            .src_ip = null,
            .dst_ip = null,
            .ip_version = null,
            .ip_proto = null,
            .src_port = null,
            .dst_port = null,
        };

        var offset: usize = ETH_HLEN;

        // Handle VLAN tag
        if (pkt.eth_proto == ETH_P_8021Q and data.len >= offset + 4) {
            pkt.vlan_id = (@as(u16, data[offset]) << 8 | data[offset + 1]) & 0x0FFF;
            pkt.eth_proto = (@as(u16, data[offset + 2]) << 8) | data[offset + 3];
            offset += 4;
        }

        // Parse IP header
        if (pkt.eth_proto == ETH_P_IP and data.len >= offset + 20) {
            pkt.ip_version = 4;
            const ihl = (data[offset] & 0x0F) * 4;
            pkt.ip_proto = data[offset + 9];

            // Source and destination IP
            var src: [16]u8 = [_]u8{0} ** 16;
            var dst: [16]u8 = [_]u8{0} ** 16;
            @memcpy(src[0..4], data[offset + 12 .. offset + 16]);
            @memcpy(dst[0..4], data[offset + 16 .. offset + 20]);
            pkt.src_ip = src;
            pkt.dst_ip = dst;

            // Parse TCP/UDP ports
            if ((pkt.ip_proto == IPPROTO_TCP or pkt.ip_proto == IPPROTO_UDP) and
                data.len >= offset + ihl + 4)
            {
                const port_offset = offset + ihl;
                pkt.src_port = (@as(u16, data[port_offset]) << 8) | data[port_offset + 1];
                pkt.dst_port = (@as(u16, data[port_offset + 2]) << 8) | data[port_offset + 3];
            }
        } else if (pkt.eth_proto == ETH_P_IPV6 and data.len >= offset + 40) {
            pkt.ip_version = 6;
            pkt.ip_proto = data[offset + 6]; // Next header

            // Source and destination IP
            var src: [16]u8 = undefined;
            var dst: [16]u8 = undefined;
            @memcpy(&src, data[offset + 8 .. offset + 24]);
            @memcpy(&dst, data[offset + 24 .. offset + 40]);
            pkt.src_ip = src;
            pkt.dst_ip = dst;

            // Parse TCP/UDP ports (simplified - doesn't handle extension headers)
            if ((pkt.ip_proto == IPPROTO_TCP or pkt.ip_proto == IPPROTO_UDP) and
                data.len >= offset + 44)
            {
                const port_offset = offset + 40;
                pkt.src_port = (@as(u16, data[port_offset]) << 8) | data[port_offset + 1];
                pkt.dst_port = (@as(u16, data[port_offset + 2]) << 8) | data[port_offset + 3];
            }
        }

        return pkt;
    }

    /// Check if packet matches filters
    fn matchesFilter(self: *Self, pkt: *const PacketInfo) bool {
        // Protocol filter
        if (self.options.filter_proto) |proto| {
            if (pkt.ip_proto == null or pkt.ip_proto.? != proto) return false;
        }

        // Port filter
        if (self.options.filter_port) |port| {
            const matches_src = pkt.src_port != null and pkt.src_port.? == port;
            const matches_dst = pkt.dst_port != null and pkt.dst_port.? == port;
            if (!matches_src and !matches_dst) return false;
        }

        // Host filter (IPv4 only)
        if (self.options.filter_host) |host| {
            if (pkt.ip_version != 4) return false;
            const src_match = pkt.src_ip != null and std.mem.eql(u8, pkt.src_ip.?[0..4], &host);
            const dst_match = pkt.dst_ip != null and std.mem.eql(u8, pkt.dst_ip.?[0..4], &host);
            if (!src_match and !dst_match) return false;
        }

        return true;
    }

    /// Run capture loop
    pub fn capture(self: *Self, writer: anytype) !void {
        const deadline: ?i64 = if (self.options.duration_secs) |secs|
            std.time.microTimestamp() + @as(i64, secs) * 1_000_000
        else
            null;

        while (true) {
            // Check duration limit
            if (deadline) |d| {
                if (std.time.microTimestamp() >= d) break;
            }

            // Check count limit
            if (self.options.count) |max| {
                if (self.stats.packets_captured >= max) break;
            }

            // Capture packet
            if (try self.captureOne()) |pkt| {
                try pkt.format(writer);
            }
        }
    }

    pub fn getStats(self: *const Self) CaptureStats {
        return self.stats;
    }
};

// Socket constants not in std
const SOL_PACKET = 263;
const PACKET_ADD_MEMBERSHIP = 1;
const PACKET_MR_PROMISC = 1;

const PacketMreq = extern struct {
    mr_ifindex: i32,
    mr_type: u16,
    mr_alen: u16,
    mr_address: [8]u8,
};

/// Convenience function for simple capture
pub fn capture(
    allocator: std.mem.Allocator,
    options: CaptureOptions,
    writer: anytype,
) !CaptureStats {
    var capturer = try Capturer.init(allocator, options);
    defer capturer.deinit();

    try capturer.capture(writer);
    return capturer.getStats();
}

/// Parse simple filter expression
pub fn parseFilter(filter: []const u8) CaptureOptions {
    var opts = CaptureOptions{};

    // Very simple filter parsing: "tcp", "udp", "icmp", "port N", "host X.X.X.X"
    var iter = std.mem.tokenizeScalar(u8, filter, ' ');
    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "tcp")) {
            opts.filter_proto = IPPROTO_TCP;
        } else if (std.mem.eql(u8, token, "udp")) {
            opts.filter_proto = IPPROTO_UDP;
        } else if (std.mem.eql(u8, token, "icmp")) {
            opts.filter_proto = IPPROTO_ICMP;
        } else if (std.mem.eql(u8, token, "port")) {
            if (iter.next()) |port_str| {
                opts.filter_port = std.fmt.parseInt(u16, port_str, 10) catch null;
            }
        } else if (std.mem.eql(u8, token, "host")) {
            if (iter.next()) |host_str| {
                opts.filter_host = parseIPv4(host_str);
            }
        }
    }

    return opts;
}

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

// Tests

test "parseFilter tcp" {
    const opts = parseFilter("tcp");
    try std.testing.expectEqual(@as(?u8, IPPROTO_TCP), opts.filter_proto);
}

test "parseFilter port" {
    const opts = parseFilter("port 80");
    try std.testing.expectEqual(@as(?u16, 80), opts.filter_port);
}

test "parseIPv4" {
    const ip = parseIPv4("192.168.1.1");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual(@as(u8, 192), ip.?[0]);
}
