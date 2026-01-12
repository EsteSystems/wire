const std = @import("std");
const socket = @import("socket.zig");
const interface = @import("interface.zig");

/// Bridge information
pub const Bridge = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    flags: u32,
    stp_state: bool,
    forward_delay: u32,
    members: []i32,

    pub fn getName(self: *const Bridge) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isUp(self: *const Bridge) bool {
        return (self.flags & socket.IFF.UP) != 0;
    }
};

/// Create a bridge interface
pub fn createBridge(name: []const u8) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    // Build RTM_NEWLINK message
    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.EXCL);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});

    // Add interface name
    try builder.addAttrString(socket.IFLA.IFNAME, name);

    // Add IFLA_LINKINFO nested attribute
    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);

    // IFLA_INFO_KIND = "bridge"
    try builder.addAttrString(socket.IFLA_INFO.KIND, "bridge");

    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a bridge interface
pub fn deleteBridge(name: []const u8) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // First get the interface index
    const maybe_iface = try interface.getInterfaceByName(allocator, name);
    if (maybe_iface == null) {
        return error.InterfaceNotFound;
    }
    const iface = maybe_iface.?;

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.DELLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = iface.index,
    });

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Add a member interface to a bridge
pub fn addBridgeMember(bridge_name: []const u8, member_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get bridge interface
    const maybe_bridge = try interface.getInterfaceByName(allocator, bridge_name);
    if (maybe_bridge == null) {
        return error.InterfaceNotFound;
    }
    const bridge = maybe_bridge.?;

    // Get member interface
    const maybe_member = try interface.getInterfaceByName(allocator, member_name);
    if (maybe_member == null) {
        return error.InterfaceNotFound;
    }
    const member = maybe_member.?;

    // Set IFLA_MASTER to add to bridge
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = member.index,
    });

    // Set master to bridge index
    try builder.addAttrU32(socket.IFLA.MASTER, @intCast(bridge.index));

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Remove a member interface from a bridge
pub fn removeBridgeMember(member_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get member interface
    const maybe_member = try interface.getInterfaceByName(allocator, member_name);
    if (maybe_member == null) {
        return error.InterfaceNotFound;
    }
    const member = maybe_member.?;

    // Set IFLA_MASTER to 0 to remove from bridge
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = member.index,
    });

    // Set master to 0 to detach
    try builder.addAttrU32(socket.IFLA.MASTER, 0);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Set bridge STP state
pub fn setBridgeStp(name: []const u8, enabled: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get bridge interface
    const maybe_bridge = try interface.getInterfaceByName(allocator, name);
    if (maybe_bridge == null) {
        return error.InterfaceNotFound;
    }
    const bridge = maybe_bridge.?;

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    // Use RTM_NEWLINK for modification (not SETLINK)
    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = bridge.index,
    });

    // Add IFLA_LINKINFO nested attribute
    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);

    // IFLA_INFO_KIND = "bridge"
    try builder.addAttrString(socket.IFLA_INFO.KIND, "bridge");

    // IFLA_INFO_DATA (bridge-specific attributes)
    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);

    // IFLA_BR_STP_STATE
    try builder.addAttrU32(socket.IFLA_BR.STP_STATE, if (enabled) 1 else 0);

    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Neighbor type flags for FDB entries (NTF_*)
pub const NTF = struct {
    pub const USE: u8 = 0x01;
    pub const SELF: u8 = 0x02; // Entry is local to the bridge
    pub const MASTER: u8 = 0x04; // Entry points to the bridge master
    pub const PROXY: u8 = 0x08;
    pub const EXT_LEARNED: u8 = 0x10;
    pub const OFFLOADED: u8 = 0x20;
    pub const STICKY: u8 = 0x40;
    pub const ROUTER: u8 = 0x80;
};

/// Bridge FDB entry
pub const FdbEntry = struct {
    mac: [6]u8,
    interface_index: i32,
    vlan: ?u16,
    state: u16,
    flags: u8,
    is_local: bool, // NTF_SELF
    is_permanent: bool, // NUD_PERMANENT
    is_offloaded: bool, // NTF_OFFLOADED

    const Self = @This();

    /// Format MAC address as string
    pub fn formatMac(self: *const Self) [17]u8 {
        var buf: [17]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            self.mac[0], self.mac[1], self.mac[2],
            self.mac[3], self.mac[4], self.mac[5],
        }) catch unreachable;
        return buf;
    }

    /// Get state as string
    pub fn stateString(self: *const Self) []const u8 {
        if (self.is_permanent) return "permanent";
        if (self.is_local) return "local";
        return "learned";
    }
};

/// Neighbor discovery message for bridge FDB (same structure as NdMsg)
const BridgeFdbMsg = extern struct {
    family: u8 = 7, // AF_BRIDGE = 7
    pad1: u8 = 0,
    pad2: u16 = 0,
    ifindex: i32 = 0,
    state: u16 = 0,
    flags: u8 = 0,
    type: u8 = 0,
};

/// NDA attributes for FDB (same as neighbor)
const NDA = struct {
    pub const UNSPEC: u16 = 0;
    pub const DST: u16 = 1;
    pub const LLADDR: u16 = 2;
    pub const VLAN: u16 = 5;
    pub const MASTER: u16 = 9;
};

/// NUD states (same as neighbor)
const NUD = struct {
    pub const PERMANENT: u16 = 0x80;
    pub const NOARP: u16 = 0x40;
    pub const REACHABLE: u16 = 0x02;
    pub const STALE: u16 = 0x04;
};

/// Get all FDB entries for a bridge
pub fn getBridgeFdb(allocator: std.mem.Allocator, bridge_name: []const u8) ![]FdbEntry {
    // Get bridge interface
    const maybe_bridge = try interface.getInterfaceByName(allocator, bridge_name);
    if (maybe_bridge == null) {
        return error.InterfaceNotFound;
    }
    const bridge = maybe_bridge.?;

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    // Build RTM_GETNEIGH request with AF_BRIDGE family
    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.GETNEIGH, socket.NLM_F.REQUEST | socket.NLM_F.DUMP);
    try builder.addData(BridgeFdbMsg, BridgeFdbMsg{
        .ifindex = bridge.index,
    });

    const msg = builder.finalize(hdr);

    // Send request and get responses
    const response = try nl.request(msg, allocator);
    defer allocator.free(response);

    // Parse responses
    var entries = std.ArrayList(FdbEntry).init(allocator);
    errdefer entries.deinit();

    var offset: usize = 0;
    while (offset + @sizeOf(socket.NlMsgHdr) <= response.len) {
        const nlhdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(response[offset..].ptr));

        if (nlhdr.len < @sizeOf(socket.NlMsgHdr) or offset + nlhdr.len > response.len) {
            break;
        }

        if (nlhdr.type == socket.RTM.NEWNEIGH) {
            const ndmsg_offset = offset + @sizeOf(socket.NlMsgHdr);
            if (ndmsg_offset + @sizeOf(BridgeFdbMsg) <= response.len) {
                const ndmsg: *const BridgeFdbMsg = @ptrCast(@alignCast(response[ndmsg_offset..].ptr));

                // Only process entries for our bridge or its ports
                var entry = FdbEntry{
                    .mac = undefined,
                    .interface_index = ndmsg.ifindex,
                    .vlan = null,
                    .state = ndmsg.state,
                    .flags = ndmsg.flags,
                    .is_local = (ndmsg.flags & NTF.SELF) != 0,
                    .is_permanent = (ndmsg.state & NUD.PERMANENT) != 0,
                    .is_offloaded = (ndmsg.flags & NTF.OFFLOADED) != 0,
                };
                @memset(&entry.mac, 0);

                var has_mac = false;

                // Parse attributes
                const attrs_offset = ndmsg_offset + @sizeOf(BridgeFdbMsg);
                const attrs_len = nlhdr.len - @sizeOf(socket.NlMsgHdr) - @sizeOf(BridgeFdbMsg);

                if (attrs_offset + attrs_len <= response.len) {
                    var parser = socket.AttrParser.init(response[attrs_offset .. attrs_offset + attrs_len]);

                    while (parser.next()) |attr| {
                        switch (attr.attr_type) {
                            NDA.LLADDR => {
                                if (attr.value.len >= 6) {
                                    @memcpy(&entry.mac, attr.value[0..6]);
                                    has_mac = true;
                                }
                            },
                            NDA.VLAN => {
                                if (attr.value.len >= 2) {
                                    entry.vlan = std.mem.readInt(u16, attr.value[0..2], .little);
                                }
                            },
                            else => {},
                        }
                    }
                }

                // Only add entries with a MAC address
                if (has_mac) {
                    try entries.append(entry);
                }
            }
        }

        offset += socket.nlAlign(nlhdr.len);
    }

    return entries.toOwnedSlice();
}

/// Get all FDB entries (for all bridges)
pub fn getAllFdb(allocator: std.mem.Allocator) ![]FdbEntry {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    // Build RTM_GETNEIGH request with AF_BRIDGE family
    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.GETNEIGH, socket.NLM_F.REQUEST | socket.NLM_F.DUMP);
    try builder.addData(BridgeFdbMsg, BridgeFdbMsg{});

    const msg = builder.finalize(hdr);

    // Send request and get responses
    const response = try nl.request(msg, allocator);
    defer allocator.free(response);

    // Parse responses
    var entries = std.ArrayList(FdbEntry).init(allocator);
    errdefer entries.deinit();

    var offset: usize = 0;
    while (offset + @sizeOf(socket.NlMsgHdr) <= response.len) {
        const nlhdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(response[offset..].ptr));

        if (nlhdr.len < @sizeOf(socket.NlMsgHdr) or offset + nlhdr.len > response.len) {
            break;
        }

        if (nlhdr.type == socket.RTM.NEWNEIGH) {
            const ndmsg_offset = offset + @sizeOf(socket.NlMsgHdr);
            if (ndmsg_offset + @sizeOf(BridgeFdbMsg) <= response.len) {
                const ndmsg: *const BridgeFdbMsg = @ptrCast(@alignCast(response[ndmsg_offset..].ptr));

                var entry = FdbEntry{
                    .mac = undefined,
                    .interface_index = ndmsg.ifindex,
                    .vlan = null,
                    .state = ndmsg.state,
                    .flags = ndmsg.flags,
                    .is_local = (ndmsg.flags & NTF.SELF) != 0,
                    .is_permanent = (ndmsg.state & NUD.PERMANENT) != 0,
                    .is_offloaded = (ndmsg.flags & NTF.OFFLOADED) != 0,
                };
                @memset(&entry.mac, 0);

                var has_mac = false;

                // Parse attributes
                const attrs_offset = ndmsg_offset + @sizeOf(BridgeFdbMsg);
                const attrs_len = nlhdr.len - @sizeOf(socket.NlMsgHdr) - @sizeOf(BridgeFdbMsg);

                if (attrs_offset + attrs_len <= response.len) {
                    var parser = socket.AttrParser.init(response[attrs_offset .. attrs_offset + attrs_len]);

                    while (parser.next()) |attr| {
                        switch (attr.attr_type) {
                            NDA.LLADDR => {
                                if (attr.value.len >= 6) {
                                    @memcpy(&entry.mac, attr.value[0..6]);
                                    has_mac = true;
                                }
                            },
                            NDA.VLAN => {
                                if (attr.value.len >= 2) {
                                    entry.vlan = std.mem.readInt(u16, attr.value[0..2], .little);
                                }
                            },
                            else => {},
                        }
                    }
                }

                // Only add entries with a MAC address
                if (has_mac) {
                    try entries.append(entry);
                }
            }
        }

        offset += socket.nlAlign(nlhdr.len);
    }

    return entries.toOwnedSlice();
}

/// Display FDB entries
pub fn displayFdb(entries: []const FdbEntry, writer: anytype, iface_resolver: anytype) !void {
    if (entries.len == 0) {
        try writer.print("No FDB entries found.\n", .{});
        return;
    }

    try writer.print("Bridge FDB ({d} entries)\n", .{entries.len});
    try writer.print("{s:<20} {s:<6} {s:<12} {s:<12}\n", .{ "MAC Address", "VLAN", "State", "Interface" });
    try writer.print("{s:-<20} {s:-<6} {s:-<12} {s:-<12}\n", .{ "", "", "", "" });

    for (entries) |*entry| {
        const mac_str = entry.formatMac();

        // VLAN
        var vlan_buf: [8]u8 = undefined;
        const vlan_str = if (entry.vlan) |v|
            std.fmt.bufPrint(&vlan_buf, "{d}", .{v}) catch "-"
        else
            "-";

        // Resolve interface name
        var if_name: []const u8 = "?";
        if (@TypeOf(iface_resolver) != @TypeOf(null)) {
            if (iface_resolver.resolve(entry.interface_index)) |name| {
                if_name = name;
            }
        }

        try writer.print("{s:<20} {s:<6} {s:<12} {s:<12}\n", .{
            mac_str,
            vlan_str,
            entry.stateString(),
            if_name,
        });
    }
}

// Tests

test "bridge create and delete" {
    // This test would require root privileges
    // Just verify the module compiles
}

test "BridgeFdbMsg size" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(BridgeFdbMsg));
}

test "FdbEntry formatMac" {
    var entry = FdbEntry{
        .mac = .{ 0x00, 0x1a, 0x2b, 0x3c, 0x4d, 0x5e },
        .interface_index = 1,
        .vlan = null,
        .state = 0,
        .flags = 0,
        .is_local = false,
        .is_permanent = false,
        .is_offloaded = false,
    };
    const mac_str = entry.formatMac();
    try std.testing.expectEqualStrings("00:1a:2b:3c:4d:5e", &mac_str);
}
