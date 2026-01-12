const std = @import("std");
const socket = @import("socket.zig");
const linux = std.os.linux;

/// Represents a network interface
pub const Interface = struct {
    index: i32,
    name: [16]u8,
    name_len: usize,
    flags: u32,
    mtu: u32,
    mac: [6]u8,
    has_mac: bool,
    operstate: u8,
    carrier: bool,
    master_index: ?i32, // Index of master interface (bond/bridge)
    link_index: ?i32, // IFLA_LINK - peer index for veth, parent for vlan
    link_netns_id: ?i32, // IFLA_LINK_NETNSID - namespace of peer (for veth)
    link_kind: [16]u8, // IFLA_INFO_KIND - "veth", "bridge", "bond", etc.
    link_kind_len: usize,

    pub fn getName(self: *const Interface) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getLinkKind(self: *const Interface) ?[]const u8 {
        if (self.link_kind_len == 0) return null;
        return self.link_kind[0..self.link_kind_len];
    }

    pub fn isVeth(self: *const Interface) bool {
        if (self.getLinkKind()) |kind| {
            return std.mem.eql(u8, kind, "veth");
        }
        return false;
    }

    pub fn isUp(self: *const Interface) bool {
        return (self.flags & socket.IFF.UP) != 0;
    }

    pub fn isRunning(self: *const Interface) bool {
        return (self.flags & socket.IFF.RUNNING) != 0;
    }

    pub fn isLoopback(self: *const Interface) bool {
        return (self.flags & socket.IFF.LOOPBACK) != 0;
    }

    pub fn hasCarrier(self: *const Interface) bool {
        return self.carrier or (self.flags & socket.IFF.LOWER_UP) != 0;
    }

    pub fn formatMac(self: *const Interface) [17]u8 {
        var buf: [17]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            self.mac[0], self.mac[1], self.mac[2],
            self.mac[3], self.mac[4], self.mac[5],
        }) catch unreachable;
        return buf;
    }

    pub fn operstateString(self: *const Interface) []const u8 {
        return switch (self.operstate) {
            0 => "unknown",
            1 => "notpresent",
            2 => "down",
            3 => "lowerlayerdown",
            4 => "testing",
            5 => "dormant",
            6 => "up",
            else => "unknown",
        };
    }
};

/// Get all network interfaces
pub fn getInterfaces(allocator: std.mem.Allocator) ![]Interface {
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
    var interfaces = std.ArrayList(Interface).init(allocator);
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

                var iface = Interface{
                    .index = ifinfo.index,
                    .name = undefined,
                    .name_len = 0,
                    .flags = ifinfo.flags,
                    .mtu = 0,
                    .mac = undefined,
                    .has_mac = false,
                    .operstate = 0,
                    .carrier = false,
                    .master_index = null,
                    .link_index = null,
                    .link_netns_id = null,
                    .link_kind = undefined,
                    .link_kind_len = 0,
                };
                @memset(&iface.name, 0);
                @memset(&iface.mac, 0);
                @memset(&iface.link_kind, 0);

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
                            socket.IFLA.MTU => {
                                if (attr.value.len >= 4) {
                                    iface.mtu = std.mem.readInt(u32, attr.value[0..4], .little);
                                }
                            },
                            socket.IFLA.ADDRESS => {
                                if (attr.value.len >= 6) {
                                    @memcpy(&iface.mac, attr.value[0..6]);
                                    iface.has_mac = true;
                                }
                            },
                            socket.IFLA.OPERSTATE => {
                                if (attr.value.len >= 1) {
                                    iface.operstate = attr.value[0];
                                }
                            },
                            socket.IFLA.CARRIER => {
                                if (attr.value.len >= 1) {
                                    iface.carrier = attr.value[0] != 0;
                                }
                            },
                            socket.IFLA.MASTER => {
                                if (attr.value.len >= 4) {
                                    const master_idx = std.mem.readInt(i32, attr.value[0..4], .little);
                                    if (master_idx > 0) {
                                        iface.master_index = master_idx;
                                    }
                                }
                            },
                            socket.IFLA.LINK => {
                                if (attr.value.len >= 4) {
                                    const link_idx = std.mem.readInt(i32, attr.value[0..4], .little);
                                    if (link_idx > 0) {
                                        iface.link_index = link_idx;
                                    }
                                }
                            },
                            socket.IFLA.LINK_NETNSID => {
                                if (attr.value.len >= 4) {
                                    iface.link_netns_id = std.mem.readInt(i32, attr.value[0..4], .little);
                                }
                            },
                            socket.IFLA.LINKINFO => {
                                // Parse nested LINKINFO attributes to get KIND
                                var nested_parser = socket.AttrParser.init(attr.value);
                                while (nested_parser.next()) |nested_attr| {
                                    if (nested_attr.attr_type == socket.IFLA_INFO.KIND) {
                                        const kind_end = std.mem.indexOfScalar(u8, nested_attr.value, 0) orelse nested_attr.value.len;
                                        const copy_len = @min(kind_end, iface.link_kind.len);
                                        @memcpy(iface.link_kind[0..copy_len], nested_attr.value[0..copy_len]);
                                        iface.link_kind_len = copy_len;
                                        break;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }

                try interfaces.append(iface);
            }
        }

        offset += socket.nlAlign(nlhdr.len);
    }

    return interfaces.toOwnedSlice();
}

/// Get a specific interface by name
pub fn getInterfaceByName(allocator: std.mem.Allocator, name: []const u8) !?Interface {
    const interfaces = try getInterfaces(allocator);
    defer allocator.free(interfaces);

    for (interfaces) |iface| {
        if (std.mem.eql(u8, iface.getName(), name)) {
            return iface;
        }
    }

    return null;
}

/// Set interface up or down
pub fn setInterfaceState(name: []const u8, up: bool) !void {
    // First get the interface to get its index
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const maybe_iface = try getInterfaceByName(allocator, name);
    const iface = maybe_iface orelse return error.InterfaceNotFound;

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    // Build RTM_SETLINK request
    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);

    const new_flags = if (up) iface.flags | socket.IFF.UP else iface.flags & ~socket.IFF.UP;
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = iface.index,
        .flags = new_flags,
        .change = socket.IFF.UP, // Only change UP flag
    });

    const msg = builder.finalize(hdr);

    // Send request (will wait for ACK)
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Set interface MTU
pub fn setInterfaceMtu(name: []const u8, mtu: u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const maybe_iface = try getInterfaceByName(allocator, name);
    const iface = maybe_iface orelse return error.InterfaceNotFound;

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = iface.index,
    });
    try builder.addAttrU32(socket.IFLA.MTU, mtu);

    const msg = builder.finalize(hdr);

    const response = try nl.request(msg, allocator);
    allocator.free(response);
}
