const std = @import("std");
const socket = @import("socket.zig");
const linux = std.os.linux;

/// Helper to read unaligned u64 from byte slice
fn readU64(data: []const u8, offset: usize) u64 {
    if (offset + 8 > data.len) return 0;
    return std.mem.readInt(u64, data[offset..][0..8], .little);
}

/// Helper to read unaligned u32 from byte slice
fn readU32(data: []const u8, offset: usize) u64 {
    if (offset + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

/// Interface statistics from IFLA_STATS
/// This matches struct rtnl_link_stats from linux/if_link.h
pub const InterfaceStats = extern struct {
    rx_packets: u32,
    tx_packets: u32,
    rx_bytes: u32,
    tx_bytes: u32,
    rx_errors: u32,
    tx_errors: u32,
    rx_dropped: u32,
    tx_dropped: u32,
    multicast: u32,
    collisions: u32,
    // Detailed rx errors
    rx_length_errors: u32,
    rx_over_errors: u32,
    rx_crc_errors: u32,
    rx_frame_errors: u32,
    rx_fifo_errors: u32,
    rx_missed_errors: u32,
    // Detailed tx errors
    tx_aborted_errors: u32,
    tx_carrier_errors: u32,
    tx_fifo_errors: u32,
    tx_heartbeat_errors: u32,
    tx_window_errors: u32,
    // Compression
    rx_compressed: u32,
    tx_compressed: u32,
    // Additional
    rx_nohandler: u32,
};

/// Interface statistics with 64-bit counters (IFLA_STATS64)
/// This matches struct rtnl_link_stats64 from linux/if_link.h
pub const InterfaceStats64 = extern struct {
    rx_packets: u64,
    tx_packets: u64,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_errors: u64,
    tx_errors: u64,
    rx_dropped: u64,
    tx_dropped: u64,
    multicast: u64,
    collisions: u64,
    // Detailed rx errors
    rx_length_errors: u64,
    rx_over_errors: u64,
    rx_crc_errors: u64,
    rx_frame_errors: u64,
    rx_fifo_errors: u64,
    rx_missed_errors: u64,
    // Detailed tx errors
    tx_aborted_errors: u64,
    tx_carrier_errors: u64,
    tx_fifo_errors: u64,
    tx_heartbeat_errors: u64,
    tx_window_errors: u64,
    // Compression
    rx_compressed: u64,
    tx_compressed: u64,
    // Additional
    rx_nohandler: u64,
};

/// IFLA_STATS64 attribute type
pub const IFLA_STATS64: u16 = 23;

/// Simplified stats for display
pub const Stats = struct {
    rx_packets: u64,
    tx_packets: u64,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_errors: u64,
    tx_errors: u64,
    rx_dropped: u64,
    tx_dropped: u64,
    multicast: u64,
    collisions: u64,

    const Self = @This();

    pub fn fromStats32(stats: *const InterfaceStats) Self {
        return Self{
            .rx_packets = stats.rx_packets,
            .tx_packets = stats.tx_packets,
            .rx_bytes = stats.rx_bytes,
            .tx_bytes = stats.tx_bytes,
            .rx_errors = stats.rx_errors,
            .tx_errors = stats.tx_errors,
            .rx_dropped = stats.rx_dropped,
            .tx_dropped = stats.tx_dropped,
            .multicast = stats.multicast,
            .collisions = stats.collisions,
        };
    }

    pub fn fromStats64(stats: *const InterfaceStats64) Self {
        return Self{
            .rx_packets = stats.rx_packets,
            .tx_packets = stats.tx_packets,
            .rx_bytes = stats.rx_bytes,
            .tx_bytes = stats.tx_bytes,
            .rx_errors = stats.rx_errors,
            .tx_errors = stats.tx_errors,
            .rx_dropped = stats.rx_dropped,
            .tx_dropped = stats.tx_dropped,
            .multicast = stats.multicast,
            .collisions = stats.collisions,
        };
    }

    /// Read stats from unaligned 64-bit stat bytes
    pub fn fromBytes64(data: []const u8) Self {
        return Self{
            .rx_packets = readU64(data, 0),
            .tx_packets = readU64(data, 8),
            .rx_bytes = readU64(data, 16),
            .tx_bytes = readU64(data, 24),
            .rx_errors = readU64(data, 32),
            .tx_errors = readU64(data, 40),
            .rx_dropped = readU64(data, 48),
            .tx_dropped = readU64(data, 56),
            .multicast = readU64(data, 64),
            .collisions = readU64(data, 72),
        };
    }

    /// Read stats from unaligned 32-bit stat bytes
    pub fn fromBytes32(data: []const u8) Self {
        return Self{
            .rx_packets = readU32(data, 0),
            .tx_packets = readU32(data, 4),
            .rx_bytes = readU32(data, 8),
            .tx_bytes = readU32(data, 12),
            .rx_errors = readU32(data, 16),
            .tx_errors = readU32(data, 20),
            .rx_dropped = readU32(data, 24),
            .tx_dropped = readU32(data, 28),
            .multicast = readU32(data, 32),
            .collisions = readU32(data, 36),
        };
    }

    /// Format bytes as human-readable (KB, MB, GB)
    pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
        if (bytes >= 1024 * 1024 * 1024) {
            return std.fmt.bufPrint(buf, "{d:.2} GB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024)}) catch "?";
        } else if (bytes >= 1024 * 1024) {
            return std.fmt.bufPrint(buf, "{d:.2} MB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024)}) catch "?";
        } else if (bytes >= 1024) {
            return std.fmt.bufPrint(buf, "{d:.2} KB", .{@as(f64, @floatFromInt(bytes)) / 1024}) catch "?";
        } else {
            return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
        }
    }

    /// Format stats for display
    pub fn format(self: *const Self, writer: anytype) !void {
        var rx_buf: [32]u8 = undefined;
        var tx_buf: [32]u8 = undefined;

        try writer.print("  RX: {d} packets, {s}\n", .{
            self.rx_packets,
            formatBytes(self.rx_bytes, &rx_buf),
        });
        try writer.print("  TX: {d} packets, {s}\n", .{
            self.tx_packets,
            formatBytes(self.tx_bytes, &tx_buf),
        });

        if (self.rx_errors > 0 or self.tx_errors > 0) {
            try writer.print("  Errors: RX {d}, TX {d}\n", .{ self.rx_errors, self.tx_errors });
        }
        if (self.rx_dropped > 0 or self.tx_dropped > 0) {
            try writer.print("  Dropped: RX {d}, TX {d}\n", .{ self.rx_dropped, self.tx_dropped });
        }
        if (self.collisions > 0) {
            try writer.print("  Collisions: {d}\n", .{self.collisions});
        }
        if (self.multicast > 0) {
            try writer.print("  Multicast: {d}\n", .{self.multicast});
        }
    }
};

/// Interface with statistics
pub const InterfaceWithStats = struct {
    index: i32,
    name: [16]u8,
    name_len: usize,
    stats: ?Stats,

    pub fn getName(self: *const InterfaceWithStats) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Get statistics for all interfaces
pub fn getAllInterfaceStats(allocator: std.mem.Allocator) ![]InterfaceWithStats {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    // Build RTM_GETLINK request
    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.GETLINK, socket.NLM_F.REQUEST | socket.NLM_F.DUMP);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});

    const msg = builder.finalize(hdr);

    // Send request and get responses
    const response = try nl.request(msg, allocator);
    defer allocator.free(response);

    // Parse responses
    var interfaces = std.ArrayList(InterfaceWithStats).init(allocator);
    errdefer interfaces.deinit();

    var offset: usize = 0;
    while (offset + @sizeOf(socket.NlMsgHdr) <= response.len) {
        const nlhdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(response[offset..].ptr));

        if (nlhdr.len < @sizeOf(socket.NlMsgHdr) or offset + nlhdr.len > response.len) {
            break;
        }

        if (nlhdr.type == socket.RTM.NEWLINK) {
            const ifinfo_offset = offset + @sizeOf(socket.NlMsgHdr);
            if (ifinfo_offset + @sizeOf(socket.IfInfoMsg) <= response.len) {
                const ifinfo: *const socket.IfInfoMsg = @ptrCast(@alignCast(response[ifinfo_offset..].ptr));

                var iface = InterfaceWithStats{
                    .index = ifinfo.index,
                    .name = undefined,
                    .name_len = 0,
                    .stats = null,
                };
                @memset(&iface.name, 0);

                // Parse attributes
                const attrs_offset = ifinfo_offset + @sizeOf(socket.IfInfoMsg);
                const attrs_len = nlhdr.len - @sizeOf(socket.NlMsgHdr) - @sizeOf(socket.IfInfoMsg);

                if (attrs_offset + attrs_len <= response.len) {
                    var parser = socket.AttrParser.init(response[attrs_offset .. attrs_offset + attrs_len]);

                    while (parser.next()) |attr| {
                        switch (attr.attr_type) {
                            socket.IFLA.IFNAME => {
                                const name_end = std.mem.indexOfScalar(u8, attr.value, 0) orelse attr.value.len;
                                const copy_len = @min(name_end, iface.name.len);
                                @memcpy(iface.name[0..copy_len], attr.value[0..copy_len]);
                                iface.name_len = copy_len;
                            },
                            IFLA_STATS64 => {
                                if (attr.value.len >= @sizeOf(InterfaceStats64)) {
                                    // Read stats from unaligned bytes
                                    iface.stats = Stats.fromBytes64(attr.value);
                                }
                            },
                            socket.IFLA.STATS => {
                                // Use 32-bit stats if 64-bit not available
                                if (iface.stats == null and attr.value.len >= @sizeOf(InterfaceStats)) {
                                    // Read stats from unaligned bytes
                                    iface.stats = Stats.fromBytes32(attr.value);
                                }
                            },
                            else => {},
                        }
                    }
                }

                if (iface.name_len > 0) {
                    try interfaces.append(iface);
                }
            }
        }

        offset += socket.nlAlign(nlhdr.len);
    }

    return interfaces.toOwnedSlice();
}

/// Get statistics for a specific interface by name
pub fn getInterfaceStatsByName(allocator: std.mem.Allocator, name: []const u8) !?Stats {
    const all = try getAllInterfaceStats(allocator);
    defer allocator.free(all);

    for (all) |iface| {
        if (std.mem.eql(u8, iface.getName(), name)) {
            return iface.stats;
        }
    }

    return null;
}

/// Get statistics for a specific interface by index
pub fn getInterfaceStatsByIndex(allocator: std.mem.Allocator, index: i32) !?Stats {
    const all = try getAllInterfaceStats(allocator);
    defer allocator.free(all);

    for (all) |iface| {
        if (iface.index == index) {
            return iface.stats;
        }
    }

    return null;
}

/// Display statistics for all interfaces
pub fn displayAllStats(allocator: std.mem.Allocator, writer: anytype) !void {
    const interfaces = try getAllInterfaceStats(allocator);
    defer allocator.free(interfaces);

    if (interfaces.len == 0) {
        try writer.print("No interfaces found.\n", .{});
        return;
    }

    for (interfaces) |iface| {
        try writer.print("{s}:\n", .{iface.getName()});
        if (iface.stats) |*stats| {
            try stats.format(writer);
        } else {
            try writer.print("  (no statistics available)\n", .{});
        }
        try writer.print("\n", .{});
    }
}

/// Calculate rate between two stat snapshots
pub const RateStats = struct {
    rx_packets_per_sec: f64,
    tx_packets_per_sec: f64,
    rx_bytes_per_sec: f64,
    tx_bytes_per_sec: f64,
    rx_errors_per_sec: f64,
    tx_errors_per_sec: f64,

    pub fn calculate(old: *const Stats, new: *const Stats, elapsed_secs: f64) RateStats {
        return RateStats{
            .rx_packets_per_sec = @as(f64, @floatFromInt(new.rx_packets -| old.rx_packets)) / elapsed_secs,
            .tx_packets_per_sec = @as(f64, @floatFromInt(new.tx_packets -| old.tx_packets)) / elapsed_secs,
            .rx_bytes_per_sec = @as(f64, @floatFromInt(new.rx_bytes -| old.rx_bytes)) / elapsed_secs,
            .tx_bytes_per_sec = @as(f64, @floatFromInt(new.tx_bytes -| old.tx_bytes)) / elapsed_secs,
            .rx_errors_per_sec = @as(f64, @floatFromInt(new.rx_errors -| old.rx_errors)) / elapsed_secs,
            .tx_errors_per_sec = @as(f64, @floatFromInt(new.tx_errors -| old.tx_errors)) / elapsed_secs,
        };
    }

    pub fn format(self: *const RateStats, writer: anytype) !void {
        var rx_buf: [32]u8 = undefined;
        var tx_buf: [32]u8 = undefined;

        try writer.print("  RX: {d:.0} pps, {s}/s\n", .{
            self.rx_packets_per_sec,
            Stats.formatBytes(@intFromFloat(self.rx_bytes_per_sec), &rx_buf),
        });
        try writer.print("  TX: {d:.0} pps, {s}/s\n", .{
            self.tx_packets_per_sec,
            Stats.formatBytes(@intFromFloat(self.tx_bytes_per_sec), &tx_buf),
        });

        if (self.rx_errors_per_sec > 0 or self.tx_errors_per_sec > 0) {
            try writer.print("  Errors: RX {d:.1}/s, TX {d:.1}/s\n", .{
                self.rx_errors_per_sec,
                self.tx_errors_per_sec,
            });
        }
    }
};

// Tests

test "InterfaceStats size" {
    // rtnl_link_stats is 24 u32 fields = 96 bytes
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(InterfaceStats));
}

test "InterfaceStats64 size" {
    // rtnl_link_stats64 is 24 u64 fields = 192 bytes
    try std.testing.expectEqual(@as(usize, 192), @sizeOf(InterfaceStats64));
}

test "Stats formatBytes" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("0 B", Stats.formatBytes(0, &buf));
    try std.testing.expectEqualStrings("512 B", Stats.formatBytes(512, &buf));
    try std.testing.expectEqualStrings("1.00 KB", Stats.formatBytes(1024, &buf));
    try std.testing.expectEqualStrings("1.50 MB", Stats.formatBytes(1024 * 1024 + 512 * 1024, &buf));
}

test "RateStats calculate" {
    const old = Stats{
        .rx_packets = 100,
        .tx_packets = 50,
        .rx_bytes = 10000,
        .tx_bytes = 5000,
        .rx_errors = 0,
        .tx_errors = 0,
        .rx_dropped = 0,
        .tx_dropped = 0,
        .multicast = 0,
        .collisions = 0,
    };

    const new = Stats{
        .rx_packets = 200,
        .tx_packets = 100,
        .rx_bytes = 20000,
        .tx_bytes = 10000,
        .rx_errors = 0,
        .tx_errors = 0,
        .rx_dropped = 0,
        .tx_dropped = 0,
        .multicast = 0,
        .collisions = 0,
    };

    const rate = RateStats.calculate(&old, &new, 1.0);

    try std.testing.expectEqual(@as(f64, 100.0), rate.rx_packets_per_sec);
    try std.testing.expectEqual(@as(f64, 50.0), rate.tx_packets_per_sec);
    try std.testing.expectEqual(@as(f64, 10000.0), rate.rx_bytes_per_sec);
}
