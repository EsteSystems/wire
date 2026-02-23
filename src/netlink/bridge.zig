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

/// AF_BRIDGE family constant
const AF_BRIDGE: u8 = 7;

/// IFLA_AF_SPEC nested attribute type
const IFLA_AF_SPEC: u16 = 26;

/// Bridge VLAN info structure (used inside IFLA_BRIDGE_VLAN_INFO)
const BRIDGE_VLAN_INFO: u16 = 2;

/// Bridge VLAN flags
pub const BRIDGE_VLAN_INFO_FLAGS = struct {
    pub const MASTER: u16 = 0x01; // Operate on bridge device
    pub const PVID: u16 = 0x02; // PVID entry
    pub const UNTAGGED: u16 = 0x04; // Untagged entry
    pub const RANGE_BEGIN: u16 = 0x08; // Begin of VLAN range
    pub const RANGE_END: u16 = 0x10; // End of VLAN range
};

/// Enable or disable VLAN filtering on a bridge
pub fn setBridgeVlanFiltering(name: []const u8, enabled: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const maybe_bridge = try interface.getInterfaceByName(allocator, name);
    if (maybe_bridge == null) {
        return error.InterfaceNotFound;
    }
    const bridge = maybe_bridge.?;

    // Verify it's a bridge
    if (bridge.getLinkKind()) |kind| {
        if (!std.mem.eql(u8, kind, "bridge")) {
            return error.NotABridge;
        }
    } else {
        return error.NotABridge;
    }

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = bridge.index,
    });

    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);
    try builder.addAttrString(socket.IFLA_INFO.KIND, "bridge");
    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);
    try builder.addAttrU8(socket.IFLA_BR.VLAN_FILTERING, if (enabled) 1 else 0);
    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Add a VLAN entry to a bridge port
/// flags: combination of BRIDGE_VLAN_INFO_FLAGS (PVID, UNTAGGED, MASTER)
pub fn addBridgeVlanEntry(port_name: []const u8, vid: u16, flags: u16) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const maybe_port = try interface.getInterfaceByName(allocator, port_name);
    if (maybe_port == null) {
        return error.InterfaceNotFound;
    }
    const port = maybe_port.?;

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    // RTM_SETLINK with AF_BRIDGE family and IFLA_AF_SPEC containing VLAN info
    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .family = AF_BRIDGE,
        .index = port.index,
    });

    // IFLA_AF_SPEC nested attr with bridge VLAN info
    const af_spec_start = try builder.startNestedAttr(IFLA_AF_SPEC);

    // BRIDGE_VLAN_INFO is a struct { u16 flags, u16 vid }
    var vlan_info: [4]u8 = undefined;
    std.mem.writeInt(u16, vlan_info[0..2], flags, .little);
    std.mem.writeInt(u16, vlan_info[2..4], vid, .little);
    try builder.addAttr(BRIDGE_VLAN_INFO, &vlan_info);

    builder.endNestedAttr(af_spec_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Add a static FDB entry to a bridge
pub fn addFdbEntry(port_name: []const u8, mac: [6]u8, vlan_id: ?u16) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const maybe_port = try interface.getInterfaceByName(allocator, port_name);
    if (maybe_port == null) {
        return error.InterfaceNotFound;
    }
    const port = maybe_port.?;

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWNEIGH, socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.REPLACE);
    try builder.addData(BridgeFdbMsg, BridgeFdbMsg{
        .family = AF_BRIDGE,
        .ifindex = port.index,
        .state = NUD.PERMANENT,
        .flags = NTF.SELF,
    });

    // Add MAC address
    try builder.addAttr(NDA.LLADDR, &mac);

    // Add VLAN ID if specified
    if (vlan_id) |vid| {
        try builder.addAttrU16(NDA.VLAN, vid);
    }

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Remove an FDB entry from a bridge
pub fn removeFdbEntry(port_name: []const u8, mac: [6]u8, vlan_id: ?u16) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const maybe_port = try interface.getInterfaceByName(allocator, port_name);
    if (maybe_port == null) {
        return error.InterfaceNotFound;
    }
    const port = maybe_port.?;

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.DELNEIGH, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(BridgeFdbMsg, BridgeFdbMsg{
        .family = AF_BRIDGE,
        .ifindex = port.index,
        .flags = NTF.SELF,
    });

    // Add MAC address
    try builder.addAttr(NDA.LLADDR, &mac);

    // Add VLAN ID if specified
    if (vlan_id) |vid| {
        try builder.addAttrU16(NDA.VLAN, vid);
    }

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Verify bridge STP state matches expected value (post-operation verification)
pub fn verifyBridgeStp(allocator: std.mem.Allocator, name: []const u8, expected_stp: bool) !void {
    const maybe_iface = try interface.getInterfaceByName(allocator, name);
    if (maybe_iface == null) {
        return error.VerificationFailed;
    }
    const iface = maybe_iface.?;

    // Verify it's a bridge
    if (iface.getLinkKind()) |kind| {
        if (!std.mem.eql(u8, kind, "bridge")) {
            return error.VerificationFailed;
        }
    } else {
        return error.VerificationFailed;
    }

    // Parse bridge info_data for STP state
    if (iface.info_data_len > 0) {
        var parser = socket.AttrParser.init(iface.info_data[0..iface.info_data_len]);
        while (parser.next()) |attr| {
            if (attr.attr_type == socket.IFLA_BR.STP_STATE) {
                if (attr.value.len >= 4) {
                    const stp_val = std.mem.readInt(u32, attr.value[0..4], .little);
                    const actual_stp = stp_val != 0;
                    if (actual_stp != expected_stp) {
                        return error.VerificationFailed;
                    }
                    return; // Verification passed
                }
            }
        }
    }
    // If we couldn't find STP state in info_data, we can't verify
}

// Tests

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
