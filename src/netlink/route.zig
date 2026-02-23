const std = @import("std");
const socket = @import("socket.zig");
const linux = std.os.linux;

/// Represents a route
pub const Route = struct {
    family: u8,
    dst_len: u8,
    src_len: u8,
    table: u8,
    protocol: u8,
    scope: u8,
    route_type: u8,
    dst: [16]u8, // Big enough for IPv6
    gateway: [16]u8,
    oif: u32, // Output interface index
    priority: u32,
    has_gateway: bool,

    pub fn isIPv4(self: *const Route) bool {
        return self.family == linux.AF.INET;
    }

    pub fn isDefault(self: *const Route) bool {
        return self.dst_len == 0;
    }

    pub fn formatDst(self: *const Route, buf: []u8) ![]u8 {
        if (self.isDefault()) {
            return std.fmt.bufPrint(buf, "default", .{});
        }

        if (self.isIPv4()) {
            return std.fmt.bufPrint(buf, "{}.{}.{}.{}/{}", .{
                self.dst[0],
                self.dst[1],
                self.dst[2],
                self.dst[3],
                self.dst_len,
            });
        } else {
            // Simplified IPv6
            return std.fmt.bufPrint(buf, "ipv6/{}", .{self.dst_len});
        }
    }

    pub fn formatGateway(self: *const Route, buf: []u8) ![]u8 {
        if (!self.has_gateway) {
            return buf[0..0];
        }

        if (self.isIPv4()) {
            return std.fmt.bufPrint(buf, "{}.{}.{}.{}", .{
                self.gateway[0],
                self.gateway[1],
                self.gateway[2],
                self.gateway[3],
            });
        } else {
            return std.fmt.bufPrint(buf, "ipv6-gateway", .{});
        }
    }

    pub fn typeString(self: *const Route) []const u8 {
        return switch (self.route_type) {
            socket.RTN.UNICAST => "unicast",
            socket.RTN.LOCAL => "local",
            socket.RTN.BROADCAST => "broadcast",
            socket.RTN.MULTICAST => "multicast",
            socket.RTN.BLACKHOLE => "blackhole",
            socket.RTN.UNREACHABLE => "unreachable",
            socket.RTN.PROHIBIT => "prohibit",
            else => "unknown",
        };
    }

    pub fn protocolString(self: *const Route) []const u8 {
        return switch (self.protocol) {
            0 => "unspec",
            1 => "redirect",
            2 => "kernel",
            3 => "boot",
            4 => "static",
            8 => "gated",
            9 => "ra",
            10 => "mrt",
            11 => "zebra",
            12 => "bird",
            13 => "dnrouted",
            14 => "xorp",
            15 => "ntk",
            16 => "dhcp",
            else => "other",
        };
    }
};

/// Get all routes
pub fn getRoutes(allocator: std.mem.Allocator) ![]Route {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.GETROUTE, socket.NLM_F.REQUEST | socket.NLM_F.DUMP);
    try builder.addData(socket.RtMsg, socket.RtMsg{});

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    defer allocator.free(response);

    var routes = std.array_list.Managed(Route).init(allocator);
    errdefer routes.deinit();

    var offset: usize = 0;
    while (offset + @sizeOf(socket.NlMsgHdr) <= response.len) {
        const nlhdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(response[offset..].ptr));

        if (nlhdr.len < @sizeOf(socket.NlMsgHdr) or offset + nlhdr.len > response.len) {
            break;
        }

        if (nlhdr.type == socket.RTM.NEWROUTE) {
            const rtm_offset = offset + @sizeOf(socket.NlMsgHdr);
            if (rtm_offset + @sizeOf(socket.RtMsg) <= response.len) {
                const rtm: *const socket.RtMsg = @ptrCast(@alignCast(response[rtm_offset..].ptr));

                // Skip non-main table routes and local/broadcast routes
                if (rtm.table != socket.RT_TABLE.MAIN and rtm.table != socket.RT_TABLE.DEFAULT) {
                    offset += socket.nlAlign(nlhdr.len);
                    continue;
                }

                var route = Route{
                    .family = rtm.family,
                    .dst_len = rtm.dst_len,
                    .src_len = rtm.src_len,
                    .table = rtm.table,
                    .protocol = rtm.protocol,
                    .scope = rtm.scope,
                    .route_type = rtm.type,
                    .dst = undefined,
                    .gateway = undefined,
                    .oif = 0,
                    .priority = 0,
                    .has_gateway = false,
                };
                @memset(&route.dst, 0);
                @memset(&route.gateway, 0);

                const attrs_offset = rtm_offset + @sizeOf(socket.RtMsg);
                const attrs_len = nlhdr.len - @sizeOf(socket.NlMsgHdr) - @sizeOf(socket.RtMsg);

                if (attrs_offset + attrs_len <= response.len) {
                    var parser = socket.AttrParser.init(response[attrs_offset .. attrs_offset + attrs_len]);

                    while (parser.next()) |attr| {
                        switch (attr.attr_type) {
                            socket.RTA.DST => {
                                const copy_len = @min(attr.value.len, route.dst.len);
                                @memcpy(route.dst[0..copy_len], attr.value[0..copy_len]);
                            },
                            socket.RTA.GATEWAY => {
                                const copy_len = @min(attr.value.len, route.gateway.len);
                                @memcpy(route.gateway[0..copy_len], attr.value[0..copy_len]);
                                route.has_gateway = true;
                            },
                            socket.RTA.OIF => {
                                if (attr.value.len >= 4) {
                                    route.oif = std.mem.readInt(u32, attr.value[0..4], .little);
                                }
                            },
                            socket.RTA.PRIORITY => {
                                if (attr.value.len >= 4) {
                                    route.priority = std.mem.readInt(u32, attr.value[0..4], .little);
                                }
                            },
                            else => {},
                        }
                    }
                }

                try routes.append(route);
            }
        }

        offset += socket.nlAlign(nlhdr.len);
    }

    return routes.toOwnedSlice();
}

/// Add a route
pub fn addRoute(family: u8, dst: ?[]const u8, dst_len: u8, gateway: ?[]const u8, oif: ?u32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWROUTE, socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.EXCL);
    try builder.addData(socket.RtMsg, socket.RtMsg{
        .family = family,
        .dst_len = dst_len,
        .table = socket.RT_TABLE.MAIN,
        .protocol = 4, // RTPROT_STATIC
        .scope = if (gateway != null) socket.RT_SCOPE.UNIVERSE else socket.RT_SCOPE.LINK,
        .type = socket.RTN.UNICAST,
    });

    if (dst) |d| {
        try builder.addAttr(socket.RTA.DST, d);
    }

    if (gateway) |gw| {
        try builder.addAttr(socket.RTA.GATEWAY, gw);
    }

    if (oif) |o| {
        try builder.addAttrU32(socket.RTA.OIF, o);
    }

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// ECMP nexthop specification
pub const Nexthop = struct {
    gateway: []const u8, // Gateway IP bytes (4 for IPv4, 16 for IPv6)
    oif: ?u32, // Output interface index (optional)
    weight: u8, // Weight for load balancing (0 = equal)
};

/// rtnexthop structure (kernel: struct rtnexthop)
const RtNexthop = extern struct {
    len: u16,
    flags: u8,
    hops: u8, // Weight - 1 (0 means weight of 1)
    ifindex: i32,
};

/// Add an ECMP (Equal-Cost Multi-Path) route with multiple nexthops
pub fn addEcmpRoute(family: u8, dst: ?[]const u8, dst_len: u8, nexthops: []const Nexthop) !void {
    if (nexthops.len == 0) return error.NoNexthops;

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [1024]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWROUTE, socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.EXCL);
    try builder.addData(socket.RtMsg, socket.RtMsg{
        .family = family,
        .dst_len = dst_len,
        .table = socket.RT_TABLE.MAIN,
        .protocol = 4, // RTPROT_STATIC
        .scope = socket.RT_SCOPE.UNIVERSE,
        .type = socket.RTN.UNICAST,
    });

    if (dst) |d| {
        try builder.addAttr(socket.RTA.DST, d);
    }

    // Build RTA_MULTIPATH attribute containing multiple rtnexthop structs
    // Each rtnexthop is followed by its own RTA_GATEWAY attribute
    const mp_start = try builder.startNestedAttr(socket.RTA.MULTIPATH);

    for (nexthops) |nh| {
        // Record where this nexthop starts
        const nh_offset = builder.offset;

        // Write rtnexthop header (will patch len later)
        if (builder.offset + @sizeOf(RtNexthop) > builder.buffer.len) {
            return error.BufferTooSmall;
        }
        const rtnh: *RtNexthop = @ptrCast(@alignCast(builder.buffer[builder.offset..].ptr));
        rtnh.* = RtNexthop{
            .len = @sizeOf(RtNexthop),
            .flags = 0,
            .hops = if (nh.weight > 0) nh.weight - 1 else 0,
            .ifindex = if (nh.oif) |o| @intCast(o) else 0,
        };
        builder.offset += @sizeOf(RtNexthop);

        // Add RTA_GATEWAY attribute after rtnexthop
        try builder.addAttr(socket.RTA.GATEWAY, nh.gateway);

        // Patch rtnexthop length to include gateway attr
        rtnh.len = @intCast(builder.offset - nh_offset);
    }

    builder.endNestedAttr(mp_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a route
pub fn deleteRoute(family: u8, dst: ?[]const u8, dst_len: u8) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.DELROUTE, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.RtMsg, socket.RtMsg{
        .family = family,
        .dst_len = dst_len,
        .table = socket.RT_TABLE.MAIN,
    });

    if (dst) |d| {
        try builder.addAttr(socket.RTA.DST, d);
    }

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}
