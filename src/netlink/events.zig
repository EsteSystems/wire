const std = @import("std");
const socket = @import("socket.zig");
const linux = std.os.linux;

/// Network event types
pub const EventType = enum {
    // Interface events
    interface_added,
    interface_removed,
    interface_up,
    interface_down,
    interface_renamed,
    interface_mtu_changed,
    interface_master_changed,

    // Address events
    address_added,
    address_removed,

    // Route events
    route_added,
    route_removed,

    // Neighbor events
    neighbor_added,
    neighbor_removed,
    neighbor_changed,
};

/// Network event data
pub const NetworkEvent = struct {
    event_type: EventType,
    timestamp: i64,

    // Interface info (for interface events)
    interface_index: ?i32 = null,
    interface_name: ?[16]u8 = null,
    interface_name_len: usize = 0,
    old_flags: ?u32 = null,
    new_flags: ?u32 = null,
    mtu: ?u32 = null,
    master_index: ?i32 = null,

    // Address info (for address events)
    address_family: ?u8 = null,
    address: ?[16]u8 = null,
    prefix_len: ?u8 = null,

    // Route info (for route events)
    route_family: ?u8 = null,
    route_dst: ?[16]u8 = null,
    route_dst_len: ?u8 = null,
    route_gateway: ?[16]u8 = null,
    route_oif: ?u32 = null,

    pub fn getInterfaceName(self: *const NetworkEvent) ?[]const u8 {
        if (self.interface_name) |*name| {
            return name[0..self.interface_name_len];
        }
        return null;
    }
};

/// Event callback function type
pub const EventCallback = *const fn (event: NetworkEvent, userdata: ?*anyopaque) void;

/// Netlink event monitor
pub const EventMonitor = struct {
    fd: linux.fd_t,
    running: bool,
    callback: ?EventCallback,
    userdata: ?*anyopaque,

    const Self = @This();
    const RECV_BUF_SIZE = 32768;

    /// Create a new event monitor subscribed to the specified multicast groups
    pub fn init(groups: []const u32) !Self {
        const fd_result = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, socket.NETLINK_ROUTE);

        if (@as(isize, @bitCast(fd_result)) < 0) {
            return error.SocketCreationFailed;
        }

        const fd: i32 = @intCast(fd_result);

        // Calculate combined group mask
        var group_mask: u32 = 0;
        for (groups) |g| {
            group_mask |= socket.RTNLGRP.toMask(g);
        }

        var addr = linux.sockaddr.nl{
            .pid = 0,
            .groups = group_mask,
        };

        const bind_result = linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl));

        if (@as(isize, @bitCast(bind_result)) < 0) {
            _ = linux.close(fd);
            return error.BindFailed;
        }

        return Self{
            .fd = fd,
            .running = false,
            .callback = null,
            .userdata = null,
        };
    }

    /// Subscribe to default groups: LINK, IPV4_IFADDR, IPV6_IFADDR, IPV4_ROUTE, IPV6_ROUTE
    pub fn initDefault() !Self {
        const groups = [_]u32{
            socket.RTNLGRP.LINK,
            socket.RTNLGRP.IPV4_IFADDR,
            socket.RTNLGRP.IPV6_IFADDR,
            socket.RTNLGRP.IPV4_ROUTE,
            socket.RTNLGRP.IPV6_ROUTE,
            socket.RTNLGRP.NEIGH,
        };
        return init(&groups);
    }

    pub fn deinit(self: *Self) void {
        self.running = false;
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }

    /// Set the event callback
    pub fn setCallback(self: *Self, callback: EventCallback, userdata: ?*anyopaque) void {
        self.callback = callback;
        self.userdata = userdata;
    }

    /// Poll for events with timeout (milliseconds). Returns number of events processed.
    /// Returns 0 if no events, -1 if error or shutdown requested.
    pub fn poll(self: *Self, timeout_ms: i32) i32 {
        var pfd = [_]linux.pollfd{
            linux.pollfd{
                .fd = self.fd,
                .events = linux.POLL.IN,
                .revents = 0,
            },
        };

        const poll_result = linux.poll(&pfd, 1, timeout_ms);

        if (@as(isize, @bitCast(poll_result)) < 0) {
            return -1;
        }

        if (poll_result == 0) {
            return 0; // Timeout
        }

        if ((pfd[0].revents & linux.POLL.IN) != 0) {
            return self.processMessages();
        }

        return 0;
    }

    /// Process pending netlink messages. Returns number of events processed.
    fn processMessages(self: *Self) i32 {
        var buf: [RECV_BUF_SIZE]u8 = undefined;
        var events_processed: i32 = 0;

        while (true) {
            const recv_result = linux.recvfrom(self.fd, &buf, buf.len, linux.MSG.DONTWAIT, null, null);

            if (@as(isize, @bitCast(recv_result)) < 0) {
                const errno = linux.E.init(recv_result);
                if (errno == .AGAIN) {
                    break; // No more messages (EAGAIN = EWOULDBLOCK on Linux)
                }
                return -1; // Error
            }

            const len: usize = @intCast(recv_result);
            if (len == 0) break;

            // Parse messages
            var offset: usize = 0;
            while (offset + @sizeOf(socket.NlMsgHdr) <= len) {
                const hdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(buf[offset..].ptr));

                if (hdr.len < @sizeOf(socket.NlMsgHdr) or offset + hdr.len > len) {
                    break;
                }

                // Process the message
                if (self.parseMessage(hdr, buf[offset..][0..hdr.len])) |event| {
                    if (self.callback) |cb| {
                        cb(event, self.userdata);
                    }
                    events_processed += 1;
                }

                offset += socket.nlAlign(hdr.len);
            }
        }

        return events_processed;
    }

    /// Parse a netlink message and return an event if relevant
    fn parseMessage(self: *Self, hdr: *const socket.NlMsgHdr, data: []const u8) ?NetworkEvent {
        _ = self;
        const timestamp = std.time.timestamp();

        switch (hdr.type) {
            socket.RTM.NEWLINK => return parseLinkEvent(data, true, timestamp),
            socket.RTM.DELLINK => return parseLinkEvent(data, false, timestamp),
            socket.RTM.NEWADDR => return parseAddrEvent(data, true, timestamp),
            socket.RTM.DELADDR => return parseAddrEvent(data, false, timestamp),
            socket.RTM.NEWROUTE => return parseRouteEvent(data, true, timestamp),
            socket.RTM.DELROUTE => return parseRouteEvent(data, false, timestamp),
            socket.RTM.NEWNEIGH => return parseNeighEvent(data, true, timestamp),
            socket.RTM.DELNEIGH => return parseNeighEvent(data, false, timestamp),
            else => return null,
        }
    }

    /// Start the event loop (blocking). Call stop() from callback to exit.
    pub fn run(self: *Self) void {
        self.running = true;
        while (self.running) {
            const result = self.poll(1000); // 1 second timeout
            if (result < 0) {
                break; // Error
            }
        }
    }

    /// Stop the event loop
    pub fn stop(self: *Self) void {
        self.running = false;
    }

    /// Check if running
    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }
};

/// Parse RTM_NEWLINK/RTM_DELLINK message
fn parseLinkEvent(data: []const u8, is_new: bool, timestamp: i64) ?NetworkEvent {
    if (data.len < @sizeOf(socket.NlMsgHdr) + @sizeOf(socket.IfInfoMsg)) {
        return null;
    }

    const ifinfo: *const socket.IfInfoMsg = @ptrCast(@alignCast(data[@sizeOf(socket.NlMsgHdr)..].ptr));

    var event = NetworkEvent{
        .event_type = if (is_new) .interface_added else .interface_removed,
        .timestamp = timestamp,
        .interface_index = ifinfo.index,
        .new_flags = ifinfo.flags,
    };

    // Parse attributes for interface name
    const attr_start = @sizeOf(socket.NlMsgHdr) + @sizeOf(socket.IfInfoMsg);
    if (attr_start < data.len) {
        var parser = socket.AttrParser.init(data[attr_start..]);
        while (parser.next()) |attr| {
            switch (attr.attr_type) {
                socket.IFLA.IFNAME => {
                    if (attr.value.len > 0) {
                        const name_len = @min(attr.value.len, @as(usize, 16));
                        var name: [16]u8 = undefined;
                        @memset(&name, 0);
                        @memcpy(name[0..name_len], attr.value[0..name_len]);
                        event.interface_name = name;
                        // Find actual length (until null)
                        event.interface_name_len = 0;
                        for (name[0..name_len]) |c| {
                            if (c == 0) break;
                            event.interface_name_len += 1;
                        }
                    }
                },
                socket.IFLA.MTU => {
                    if (attr.value.len >= 4) {
                        event.mtu = std.mem.readInt(u32, attr.value[0..4], .little);
                    }
                },
                socket.IFLA.MASTER => {
                    if (attr.value.len >= 4) {
                        event.master_index = @bitCast(std.mem.readInt(u32, attr.value[0..4], .little));
                    }
                },
                else => {},
            }
        }
    }

    // Determine more specific event type for NEWLINK
    if (is_new) {
        if ((ifinfo.flags & socket.IFF.UP) != 0) {
            event.event_type = .interface_up;
        }
    }

    return event;
}

/// Parse RTM_NEWADDR/RTM_DELADDR message
fn parseAddrEvent(data: []const u8, is_new: bool, timestamp: i64) ?NetworkEvent {
    if (data.len < @sizeOf(socket.NlMsgHdr) + @sizeOf(socket.IfAddrMsg)) {
        return null;
    }

    const ifaddr: *const socket.IfAddrMsg = @ptrCast(@alignCast(data[@sizeOf(socket.NlMsgHdr)..].ptr));

    var event = NetworkEvent{
        .event_type = if (is_new) .address_added else .address_removed,
        .timestamp = timestamp,
        .interface_index = @intCast(ifaddr.index),
        .address_family = ifaddr.family,
        .prefix_len = ifaddr.prefixlen,
    };

    // Parse attributes for address
    const attr_start = @sizeOf(socket.NlMsgHdr) + @sizeOf(socket.IfAddrMsg);
    if (attr_start < data.len) {
        var parser = socket.AttrParser.init(data[attr_start..]);
        while (parser.next()) |attr| {
            switch (attr.attr_type) {
                socket.IFA.ADDRESS, socket.IFA.LOCAL => {
                    if (attr.value.len > 0) {
                        var addr: [16]u8 = undefined;
                        @memset(&addr, 0);
                        const copy_len = @min(attr.value.len, 16);
                        @memcpy(addr[0..copy_len], attr.value[0..copy_len]);
                        event.address = addr;
                    }
                },
                else => {},
            }
        }
    }

    return event;
}

/// Parse RTM_NEWROUTE/RTM_DELROUTE message
fn parseRouteEvent(data: []const u8, is_new: bool, timestamp: i64) ?NetworkEvent {
    if (data.len < @sizeOf(socket.NlMsgHdr) + @sizeOf(socket.RtMsg)) {
        return null;
    }

    const rtmsg: *const socket.RtMsg = @ptrCast(@alignCast(data[@sizeOf(socket.NlMsgHdr)..].ptr));

    // Only track unicast routes
    if (rtmsg.type != socket.RTN.UNICAST) {
        return null;
    }

    var event = NetworkEvent{
        .event_type = if (is_new) .route_added else .route_removed,
        .timestamp = timestamp,
        .route_family = rtmsg.family,
        .route_dst_len = rtmsg.dst_len,
    };

    // Parse attributes
    const attr_start = @sizeOf(socket.NlMsgHdr) + @sizeOf(socket.RtMsg);
    if (attr_start < data.len) {
        var parser = socket.AttrParser.init(data[attr_start..]);
        while (parser.next()) |attr| {
            switch (attr.attr_type) {
                socket.RTA.DST => {
                    if (attr.value.len > 0) {
                        var dst: [16]u8 = undefined;
                        @memset(&dst, 0);
                        const copy_len = @min(attr.value.len, 16);
                        @memcpy(dst[0..copy_len], attr.value[0..copy_len]);
                        event.route_dst = dst;
                    }
                },
                socket.RTA.GATEWAY => {
                    if (attr.value.len > 0) {
                        var gw: [16]u8 = undefined;
                        @memset(&gw, 0);
                        const copy_len = @min(attr.value.len, 16);
                        @memcpy(gw[0..copy_len], attr.value[0..copy_len]);
                        event.route_gateway = gw;
                    }
                },
                socket.RTA.OIF => {
                    if (attr.value.len >= 4) {
                        event.route_oif = std.mem.readInt(u32, attr.value[0..4], .little);
                    }
                },
                else => {},
            }
        }
    }

    return event;
}

/// Parse RTM_NEWNEIGH/RTM_DELNEIGH message
fn parseNeighEvent(data: []const u8, is_new: bool, timestamp: i64) ?NetworkEvent {
    // Skip neighbor events for now - basic parsing
    _ = data;
    return NetworkEvent{
        .event_type = if (is_new) .neighbor_added else .neighbor_removed,
        .timestamp = timestamp,
    };
}

/// Format an event for display
pub fn formatEvent(event: *const NetworkEvent, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    switch (event.event_type) {
        .interface_added, .interface_removed => {
            const action = if (event.event_type == .interface_added) "added" else "removed";
            if (event.getInterfaceName()) |name| {
                try writer.print("Interface {s} {s}", .{ name, action });
            } else if (event.interface_index) |idx| {
                try writer.print("Interface (index={d}) {s}", .{ idx, action });
            }
        },
        .interface_up => {
            if (event.getInterfaceName()) |name| {
                try writer.print("Interface {s} UP", .{name});
            }
        },
        .interface_down => {
            if (event.getInterfaceName()) |name| {
                try writer.print("Interface {s} DOWN", .{name});
            }
        },
        .address_added, .address_removed => {
            const action = if (event.event_type == .address_added) "added" else "removed";
            if (event.address) |addr| {
                if (event.address_family == 2) { // AF_INET
                    try writer.print("Address {d}.{d}.{d}.{d}/{d} {s}", .{
                        addr[0],
                        addr[1],
                        addr[2],
                        addr[3],
                        event.prefix_len orelse 0,
                        action,
                    });
                } else {
                    try writer.print("Address (IPv6) {s}", .{action});
                }
            }
        },
        .route_added, .route_removed => {
            const action = if (event.event_type == .route_added) "added" else "removed";
            if (event.route_dst_len) |dst_len| {
                if (dst_len == 0) {
                    try writer.print("Route default {s}", .{action});
                } else if (event.route_dst) |dst| {
                    try writer.print("Route {d}.{d}.{d}.{d}/{d} {s}", .{
                        dst[0],
                        dst[1],
                        dst[2],
                        dst[3],
                        dst_len,
                        action,
                    });
                }
            }
        },
        else => {
            try writer.print("Event: {s}", .{@tagName(event.event_type)});
        },
    }

    return stream.getWritten();
}

// Tests

test "RTNLGRP mask calculation" {
    try std.testing.expectEqual(@as(u32, 0), socket.RTNLGRP.toMask(0));
    try std.testing.expectEqual(@as(u32, 1), socket.RTNLGRP.toMask(1)); // LINK
    try std.testing.expectEqual(@as(u32, 2), socket.RTNLGRP.toMask(2)); // NOTIFY
    try std.testing.expectEqual(@as(u32, 16), socket.RTNLGRP.toMask(5)); // IPV4_IFADDR
}

test "EventType values" {
    try std.testing.expect(@intFromEnum(EventType.interface_added) != @intFromEnum(EventType.interface_removed));
}
