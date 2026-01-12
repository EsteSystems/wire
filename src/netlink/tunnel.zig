const std = @import("std");
const socket = @import("socket.zig");
const linux = std.os.linux;

/// VXLAN attributes (nested in IFLA_INFO_DATA for type "vxlan")
pub const IFLA_VXLAN = struct {
    pub const UNSPEC: u16 = 0;
    pub const ID: u16 = 1; // VNI (VXLAN Network Identifier)
    pub const GROUP: u16 = 2; // Multicast group (IPv4)
    pub const LINK: u16 = 3; // Physical device to bind to
    pub const LOCAL: u16 = 4; // Local IP address
    pub const TTL: u16 = 5;
    pub const TOS: u16 = 6;
    pub const LEARNING: u16 = 7;
    pub const AGEING: u16 = 8;
    pub const LIMIT: u16 = 9;
    pub const PORT_RANGE: u16 = 10;
    pub const PROXY: u16 = 11;
    pub const RSC: u16 = 12;
    pub const L2MISS: u16 = 13;
    pub const L3MISS: u16 = 14;
    pub const PORT: u16 = 15; // Destination port (default 4789)
    pub const GROUP6: u16 = 16; // Multicast group (IPv6)
    pub const LOCAL6: u16 = 17; // Local IPv6 address
    pub const UDP_CSUM: u16 = 18;
    pub const UDP_ZERO_CSUM6_TX: u16 = 19;
    pub const UDP_ZERO_CSUM6_RX: u16 = 20;
    pub const REMCSUM_TX: u16 = 21;
    pub const REMCSUM_RX: u16 = 22;
    pub const GBP: u16 = 23;
    pub const REMCSUM_NOPARTIAL: u16 = 24;
    pub const COLLECT_METADATA: u16 = 25;
    pub const LABEL: u16 = 26;
    pub const GPE: u16 = 27;
};

/// GRE attributes (nested in IFLA_INFO_DATA for type "gre"/"gretap")
pub const IFLA_GRE = struct {
    pub const UNSPEC: u16 = 0;
    pub const LINK: u16 = 1;
    pub const IFLAGS: u16 = 2;
    pub const OFLAGS: u16 = 3;
    pub const IKEY: u16 = 4;
    pub const OKEY: u16 = 5;
    pub const LOCAL: u16 = 6;
    pub const REMOTE: u16 = 7;
    pub const TTL: u16 = 8;
    pub const TOS: u16 = 9;
    pub const PMTUDISC: u16 = 10;
    pub const ENCAP_LIMIT: u16 = 11;
    pub const FLOWINFO: u16 = 12;
    pub const FLAGS: u16 = 13;
    pub const ENCAP_TYPE: u16 = 14;
    pub const ENCAP_FLAGS: u16 = 15;
    pub const ENCAP_SPORT: u16 = 16;
    pub const ENCAP_DPORT: u16 = 17;
    pub const COLLECT_METADATA: u16 = 18;
    pub const IGNORE_DF: u16 = 19;
    pub const FWMARK: u16 = 20;
    pub const ERSPAN_INDEX: u16 = 21;
    pub const ERSPAN_VER: u16 = 22;
    pub const ERSPAN_DIR: u16 = 23;
    pub const ERSPAN_HWID: u16 = 24;
};

/// VXLAN creation options
pub const VxlanOptions = struct {
    vni: u32 = 100,
    local: ?[4]u8 = null,
    group: ?[4]u8 = null, // Multicast group for BUM traffic
    dev: ?[]const u8 = null, // Physical device to bind
    port: u16 = 4789, // Default VXLAN port
    learning: bool = true,
    ttl: u8 = 0, // 0 = inherit
};

/// GRE creation options
pub const GreOptions = struct {
    local: [4]u8,
    remote: [4]u8,
    key: ?u32 = null,
    ttl: u8 = 64,
    pmtudisc: bool = true,
};

/// Create a VXLAN interface
pub fn createVxlan(name: []const u8, options: VxlanOptions) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build the message
    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.CREATE | socket.NLM_F.EXCL | socket.NLM_F.ACK);

    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});

    // Add interface name
    try builder.addAttrString(socket.IFLA.IFNAME, name);

    // Start IFLA_LINKINFO
    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);

    // IFLA_INFO_KIND = "vxlan"
    try builder.addAttrString(socket.IFLA_INFO.KIND, "vxlan");

    // Start IFLA_INFO_DATA
    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);

    // VNI (required)
    try builder.addAttrU32(IFLA_VXLAN.ID, options.vni);

    // Port
    // Note: VXLAN port is in network byte order
    const port_be = std.mem.nativeToBig(u16, options.port);
    try builder.addAttrU16(IFLA_VXLAN.PORT, port_be);

    // Local address
    if (options.local) |local| {
        try builder.addAttr(IFLA_VXLAN.LOCAL, &local);
    }

    // Multicast group
    if (options.group) |group| {
        try builder.addAttr(IFLA_VXLAN.GROUP, &group);
    }

    // Learning
    try builder.addAttrU8(IFLA_VXLAN.LEARNING, if (options.learning) 1 else 0);

    // TTL
    if (options.ttl > 0) {
        try builder.addAttrU8(IFLA_VXLAN.TTL, options.ttl);
    }

    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Create a GRE tunnel interface
pub fn createGre(name: []const u8, options: GreOptions) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.CREATE | socket.NLM_F.EXCL | socket.NLM_F.ACK);

    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});

    // Add interface name
    try builder.addAttrString(socket.IFLA.IFNAME, name);

    // Start IFLA_LINKINFO
    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);

    // IFLA_INFO_KIND = "gre"
    try builder.addAttrString(socket.IFLA_INFO.KIND, "gre");

    // Start IFLA_INFO_DATA
    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);

    // Local address (required)
    try builder.addAttr(IFLA_GRE.LOCAL, &options.local);

    // Remote address (required)
    try builder.addAttr(IFLA_GRE.REMOTE, &options.remote);

    // Key (optional)
    if (options.key) |key| {
        try builder.addAttrU32(IFLA_GRE.IKEY, key);
        try builder.addAttrU32(IFLA_GRE.OKEY, key);
        // Set key flags
        try builder.addAttrU16(IFLA_GRE.IFLAGS, 0x2000); // GRE_KEY
        try builder.addAttrU16(IFLA_GRE.OFLAGS, 0x2000);
    }

    // TTL
    try builder.addAttrU8(IFLA_GRE.TTL, options.ttl);

    // PMTU discovery
    try builder.addAttrU8(IFLA_GRE.PMTUDISC, if (options.pmtudisc) 1 else 0);

    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Create a GRE TAP interface (L2 over GRE)
pub fn createGretap(name: []const u8, options: GreOptions) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.CREATE | socket.NLM_F.EXCL | socket.NLM_F.ACK);

    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});

    // Add interface name
    try builder.addAttrString(socket.IFLA.IFNAME, name);

    // Start IFLA_LINKINFO
    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);

    // IFLA_INFO_KIND = "gretap" (L2 over GRE)
    try builder.addAttrString(socket.IFLA_INFO.KIND, "gretap");

    // Start IFLA_INFO_DATA
    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);

    // Local address (required)
    try builder.addAttr(IFLA_GRE.LOCAL, &options.local);

    // Remote address (required)
    try builder.addAttr(IFLA_GRE.REMOTE, &options.remote);

    // Key (optional)
    if (options.key) |key| {
        try builder.addAttrU32(IFLA_GRE.IKEY, key);
        try builder.addAttrU32(IFLA_GRE.OKEY, key);
        try builder.addAttrU16(IFLA_GRE.IFLAGS, 0x2000);
        try builder.addAttrU16(IFLA_GRE.OFLAGS, 0x2000);
    }

    // TTL
    try builder.addAttrU8(IFLA_GRE.TTL, options.ttl);

    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a tunnel interface (works for any interface)
pub fn deleteTunnel(name: []const u8) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.DELLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);

    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});
    try builder.addAttrString(socket.IFLA.IFNAME, name);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Parse IPv4 address from string
pub fn parseIPv4(ip_str: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var current_val: u16 = 0;

    for (ip_str) |c| {
        if (c == '.') {
            if (octet_idx >= 3 or current_val > 255) return null;
            result[octet_idx] = @intCast(current_val);
            octet_idx += 1;
            current_val = 0;
        } else if (c >= '0' and c <= '9') {
            current_val = current_val * 10 + (c - '0');
            if (current_val > 255) return null;
        } else {
            return null;
        }
    }

    if (octet_idx != 3 or current_val > 255) return null;
    result[3] = @intCast(current_val);
    return result;
}

/// Format IPv4 address to string
pub fn formatIPv4(ip: [4]u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
}

// Tests

test "parseIPv4" {
    const ip = parseIPv4("192.168.1.1");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, ip.?);
}

test "parseIPv4 invalid" {
    try std.testing.expect(parseIPv4("256.1.1.1") == null);
    try std.testing.expect(parseIPv4("1.2.3") == null);
    try std.testing.expect(parseIPv4("1.2.3.4.5") == null);
}
