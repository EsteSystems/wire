const std = @import("std");
const linux = std.os.linux;

/// Netlink protocol families
pub const NETLINK_ROUTE: u32 = 0;

/// Netlink message types for NETLINK_ROUTE
pub const RTM = struct {
    pub const NEWLINK: u16 = 16;
    pub const DELLINK: u16 = 17;
    pub const GETLINK: u16 = 18;
    pub const SETLINK: u16 = 19;

    pub const NEWADDR: u16 = 20;
    pub const DELADDR: u16 = 21;
    pub const GETADDR: u16 = 22;

    pub const NEWROUTE: u16 = 24;
    pub const DELROUTE: u16 = 25;
    pub const GETROUTE: u16 = 26;

    pub const NEWNEIGH: u16 = 28;
    pub const DELNEIGH: u16 = 29;
    pub const GETNEIGH: u16 = 30;
};

/// Netlink message header (16 bytes)
pub const NlMsgHdr = extern struct {
    len: u32,
    type: u16,
    flags: u16,
    seq: u32,
    pid: u32,
};

/// Netlink message flags
pub const NLM_F = struct {
    pub const REQUEST: u16 = 0x01;
    pub const MULTI: u16 = 0x02;
    pub const ACK: u16 = 0x04;
    pub const ECHO: u16 = 0x08;
    pub const ROOT: u16 = 0x100;
    pub const MATCH: u16 = 0x200;
    pub const ATOMIC: u16 = 0x400;
    pub const DUMP: u16 = ROOT | MATCH;
    pub const REPLACE: u16 = 0x100;
    pub const EXCL: u16 = 0x200;
    pub const CREATE: u16 = 0x400;
    pub const APPEND: u16 = 0x800;
};

/// Netlink message type for done/error
pub const NLMSG = struct {
    pub const NOOP: u16 = 0x1;
    pub const ERROR: u16 = 0x2;
    pub const DONE: u16 = 0x3;
    pub const OVERRUN: u16 = 0x4;
};

/// Interface info message (for RTM_*LINK)
pub const IfInfoMsg = extern struct {
    family: u8 = 0,
    __pad: u8 = 0,
    type: u16 = 0,
    index: i32 = 0,
    flags: u32 = 0,
    change: u32 = 0xFFFFFFFF,
};

/// Interface flags
pub const IFF = struct {
    pub const UP: u32 = 1 << 0;
    pub const BROADCAST: u32 = 1 << 1;
    pub const DEBUG: u32 = 1 << 2;
    pub const LOOPBACK: u32 = 1 << 3;
    pub const POINTOPOINT: u32 = 1 << 4;
    pub const NOTRAILERS: u32 = 1 << 5;
    pub const RUNNING: u32 = 1 << 6;
    pub const NOARP: u32 = 1 << 7;
    pub const PROMISC: u32 = 1 << 8;
    pub const ALLMULTI: u32 = 1 << 9;
    pub const MASTER: u32 = 1 << 10;
    pub const SLAVE: u32 = 1 << 11;
    pub const MULTICAST: u32 = 1 << 12;
    pub const PORTSEL: u32 = 1 << 13;
    pub const AUTOMEDIA: u32 = 1 << 14;
    pub const DYNAMIC: u32 = 1 << 15;
    pub const LOWER_UP: u32 = 1 << 16;
    pub const DORMANT: u32 = 1 << 17;
    pub const ECHO: u32 = 1 << 18;
};

/// Address message (for RTM_*ADDR)
pub const IfAddrMsg = extern struct {
    family: u8 = linux.AF.INET,
    prefixlen: u8 = 0,
    flags: u8 = 0,
    scope: u8 = 0,
    index: u32 = 0,
};

/// Route message (for RTM_*ROUTE)
pub const RtMsg = extern struct {
    family: u8 = linux.AF.INET,
    dst_len: u8 = 0,
    src_len: u8 = 0,
    tos: u8 = 0,
    table: u8 = 254, // RT_TABLE_MAIN
    protocol: u8 = 4, // RTPROT_STATIC
    scope: u8 = 0, // RT_SCOPE_UNIVERSE
    type: u8 = 1, // RTN_UNICAST
    flags: u32 = 0,
};

/// Route table IDs
pub const RT_TABLE = struct {
    pub const UNSPEC: u8 = 0;
    pub const DEFAULT: u8 = 253;
    pub const MAIN: u8 = 254;
    pub const LOCAL: u8 = 255;
};

/// Route types
pub const RTN = struct {
    pub const UNSPEC: u8 = 0;
    pub const UNICAST: u8 = 1;
    pub const LOCAL: u8 = 2;
    pub const BROADCAST: u8 = 3;
    pub const ANYCAST: u8 = 4;
    pub const MULTICAST: u8 = 5;
    pub const BLACKHOLE: u8 = 6;
    pub const UNREACHABLE: u8 = 7;
    pub const PROHIBIT: u8 = 8;
    pub const THROW: u8 = 9;
    pub const NAT: u8 = 10;
};

/// Route scopes
pub const RT_SCOPE = struct {
    pub const UNIVERSE: u8 = 0;
    pub const SITE: u8 = 200;
    pub const LINK: u8 = 253;
    pub const HOST: u8 = 254;
    pub const NOWHERE: u8 = 255;
};

/// Netlink attribute header
pub const NlAttr = extern struct {
    len: u16,
    type: u16,
};

/// Interface link attributes (IFLA_*)
pub const IFLA = struct {
    pub const UNSPEC: u16 = 0;
    pub const ADDRESS: u16 = 1;
    pub const BROADCAST: u16 = 2;
    pub const IFNAME: u16 = 3;
    pub const MTU: u16 = 4;
    pub const LINK: u16 = 5;
    pub const QDISC: u16 = 6;
    pub const STATS: u16 = 7;
    pub const MASTER: u16 = 10;
    pub const TXQLEN: u16 = 13;
    pub const OPERSTATE: u16 = 16;
    pub const LINKMODE: u16 = 17;
    pub const LINKINFO: u16 = 18;
    pub const CARRIER: u16 = 33;
};

/// Link info attributes (nested in IFLA_LINKINFO)
pub const IFLA_INFO = struct {
    pub const UNSPEC: u16 = 0;
    pub const KIND: u16 = 1;
    pub const DATA: u16 = 2;
    pub const XSTATS: u16 = 3;
    pub const SLAVE_KIND: u16 = 4;
    pub const SLAVE_DATA: u16 = 5;
};

/// Bond mode values
pub const BOND_MODE = struct {
    pub const ROUNDROBIN: u8 = 0;
    pub const ACTIVEBACKUP: u8 = 1;
    pub const XOR: u8 = 2;
    pub const BROADCAST: u8 = 3;
    pub const @"802.3AD": u8 = 4;
    pub const TLB: u8 = 5;
    pub const ALB: u8 = 6;
};

/// Bond attributes (nested in IFLA_INFO_DATA for bonds)
pub const IFLA_BOND = struct {
    pub const UNSPEC: u16 = 0;
    pub const MODE: u16 = 1;
    pub const ACTIVE_SLAVE: u16 = 2;
    pub const MIIMON: u16 = 3;
    pub const UPDELAY: u16 = 4;
    pub const DOWNDELAY: u16 = 5;
    pub const USE_CARRIER: u16 = 6;
    pub const ARP_INTERVAL: u16 = 7;
    pub const ARP_IP_TARGET: u16 = 8;
    pub const ARP_VALIDATE: u16 = 9;
    pub const ARP_ALL_TARGETS: u16 = 10;
    pub const PRIMARY: u16 = 11;
    pub const PRIMARY_RESELECT: u16 = 12;
    pub const FAIL_OVER_MAC: u16 = 13;
    pub const XMIT_HASH_POLICY: u16 = 14;
    pub const RESEND_IGMP: u16 = 15;
    pub const NUM_PEER_NOTIF: u16 = 16;
    pub const ALL_SLAVES_ACTIVE: u16 = 17;
    pub const MIN_LINKS: u16 = 18;
    pub const LP_INTERVAL: u16 = 19;
    pub const PACKETS_PER_SLAVE: u16 = 20;
    pub const AD_LACP_RATE: u16 = 21;
    pub const AD_SELECT: u16 = 22;
    pub const AD_INFO: u16 = 23;
    pub const AD_ACTOR_SYS_PRIO: u16 = 24;
    pub const AD_USER_PORT_KEY: u16 = 25;
    pub const AD_ACTOR_SYSTEM: u16 = 26;
    pub const TLB_DYNAMIC_LB: u16 = 27;
    pub const PEER_NOTIF_DELAY: u16 = 28;
};

/// Bridge attributes (nested in IFLA_INFO_DATA for bridges)
pub const IFLA_BR = struct {
    pub const UNSPEC: u16 = 0;
    pub const FORWARD_DELAY: u16 = 1;
    pub const HELLO_TIME: u16 = 2;
    pub const MAX_AGE: u16 = 3;
    pub const AGEING_TIME: u16 = 4;
    pub const STP_STATE: u16 = 5;
    pub const PRIORITY: u16 = 6;
    pub const VLAN_FILTERING: u16 = 7;
    pub const VLAN_PROTOCOL: u16 = 8;
    pub const GROUP_FWD_MASK: u16 = 9;
    pub const ROOT_ID: u16 = 10;
    pub const BRIDGE_ID: u16 = 11;
    pub const ROOT_PORT: u16 = 12;
    pub const ROOT_PATH_COST: u16 = 13;
    pub const TOPOLOGY_CHANGE: u16 = 14;
    pub const TOPOLOGY_CHANGE_DETECTED: u16 = 15;
    pub const HELLO_TIMER: u16 = 16;
    pub const TCN_TIMER: u16 = 17;
    pub const TOPOLOGY_CHANGE_TIMER: u16 = 18;
    pub const GC_TIMER: u16 = 19;
    pub const GROUP_ADDR: u16 = 20;
    pub const FDB_FLUSH: u16 = 21;
    pub const MCAST_ROUTER: u16 = 22;
    pub const MCAST_SNOOPING: u16 = 23;
    pub const MCAST_QUERY_USE_IFADDR: u16 = 24;
    pub const MCAST_QUERIER: u16 = 25;
    pub const MCAST_HASH_ELASTICITY: u16 = 26;
    pub const MCAST_HASH_MAX: u16 = 27;
    pub const MCAST_LAST_MEMBER_CNT: u16 = 28;
    pub const MCAST_STARTUP_QUERY_CNT: u16 = 29;
    pub const MCAST_LAST_MEMBER_INTVL: u16 = 30;
    pub const MCAST_MEMBERSHIP_INTVL: u16 = 31;
    pub const MCAST_QUERIER_INTVL: u16 = 32;
    pub const MCAST_QUERY_INTVL: u16 = 33;
    pub const MCAST_QUERY_RESPONSE_INTVL: u16 = 34;
    pub const MCAST_STARTUP_QUERY_INTVL: u16 = 35;
    pub const NF_CALL_IPTABLES: u16 = 36;
    pub const NF_CALL_IP6TABLES: u16 = 37;
    pub const NF_CALL_ARPTABLES: u16 = 38;
    pub const VLAN_DEFAULT_PVID: u16 = 39;
};

/// VLAN attributes (nested in IFLA_INFO_DATA for VLANs)
pub const IFLA_VLAN = struct {
    pub const UNSPEC: u16 = 0;
    pub const ID: u16 = 1;
    pub const FLAGS: u16 = 2;
    pub const EGRESS_QOS: u16 = 3;
    pub const INGRESS_QOS: u16 = 4;
    pub const PROTOCOL: u16 = 5;
};

/// Interface address attributes (IFA_*)
pub const IFA = struct {
    pub const UNSPEC: u16 = 0;
    pub const ADDRESS: u16 = 1;
    pub const LOCAL: u16 = 2;
    pub const LABEL: u16 = 3;
    pub const BROADCAST: u16 = 4;
    pub const ANYCAST: u16 = 5;
    pub const CACHEINFO: u16 = 6;
    pub const MULTICAST: u16 = 7;
    pub const FLAGS: u16 = 8;
};

/// Route attributes (RTA_*)
pub const RTA = struct {
    pub const UNSPEC: u16 = 0;
    pub const DST: u16 = 1;
    pub const SRC: u16 = 2;
    pub const IIF: u16 = 3;
    pub const OIF: u16 = 4;
    pub const GATEWAY: u16 = 5;
    pub const PRIORITY: u16 = 6;
    pub const PREFSRC: u16 = 7;
    pub const METRICS: u16 = 8;
    pub const TABLE: u16 = 15;
};

/// Netlink error message
pub const NlMsgErr = extern struct {
    @"error": i32,
    msg: NlMsgHdr,
};

/// Align to 4-byte boundary
pub fn nlAlign(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

/// Netlink socket wrapper
pub const NetlinkSocket = struct {
    fd: linux.fd_t,
    seq: u32,
    pid: u32,

    const Self = @This();
    const RECV_BUF_SIZE = 32768;

    pub fn open() !Self {
        const fd_result = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, NETLINK_ROUTE);

        if (@as(isize, @bitCast(fd_result)) < 0) {
            return error.SocketCreationFailed;
        }

        const fd: i32 = @intCast(fd_result);

        var addr = linux.sockaddr.nl{
            .pid = 0,
            .groups = 0,
        };

        const bind_result = linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl));

        if (@as(isize, @bitCast(bind_result)) < 0) {
            _ = linux.close(fd);
            return error.BindFailed;
        }

        return Self{
            .fd = fd,
            .seq = 1,
            .pid = @intCast(linux.getpid()),
        };
    }

    pub fn close(self: *Self) void {
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    pub fn nextSeq(self: *Self) u32 {
        const seq = self.seq;
        self.seq +%= 1;
        return seq;
    }

    /// Send a netlink request and receive all responses
    pub fn request(self: *Self, msg: []const u8, allocator: std.mem.Allocator) ![]u8 {
        // Send
        var addr = linux.sockaddr.nl{
            .pid = 0,
            .groups = 0,
        };

        const send_result = linux.sendto(self.fd, msg.ptr, msg.len, 0, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl));

        if (@as(isize, @bitCast(send_result)) < 0) {
            return error.SendFailed;
        }

        // Receive all messages
        var responses = std.ArrayList(u8).init(allocator);
        errdefer responses.deinit();

        var buf: [RECV_BUF_SIZE]u8 = undefined;

        while (true) {
            const recv_result = linux.recvfrom(self.fd, &buf, buf.len, 0, null, null);

            if (@as(isize, @bitCast(recv_result)) < 0) {
                return error.ReceiveFailed;
            }

            const len: usize = @intCast(recv_result);
            if (len == 0) break;

            // Parse messages to check for DONE or ERROR
            var offset: usize = 0;
            var done = false;

            while (offset + @sizeOf(NlMsgHdr) <= len) {
                const hdr: *const NlMsgHdr = @ptrCast(@alignCast(buf[offset..].ptr));

                if (hdr.len < @sizeOf(NlMsgHdr) or offset + hdr.len > len) {
                    break;
                }

                if (hdr.type == NLMSG.DONE) {
                    done = true;
                    break;
                }

                if (hdr.type == NLMSG.ERROR) {
                    const err: *const NlMsgErr = @ptrCast(@alignCast(buf[offset + @sizeOf(NlMsgHdr) ..].ptr));
                    if (err.@"error" != 0) {
                        return error.NetlinkError;
                    }
                    // Error code 0 means ACK
                    done = true;
                    break;
                }

                // Append this message to responses
                try responses.appendSlice(buf[offset .. offset + hdr.len]);

                offset += nlAlign(hdr.len);
            }

            if (done) break;
        }

        return responses.toOwnedSlice();
    }
};

/// Message builder for netlink requests
pub const MessageBuilder = struct {
    buffer: []u8,
    offset: usize,
    seq: u32,
    pid: u32,

    const Self = @This();

    pub fn init(buffer: []u8, seq: u32, pid: u32) Self {
        return Self{
            .buffer = buffer,
            .offset = 0,
            .seq = seq,
            .pid = pid,
        };
    }

    pub fn addHeader(self: *Self, msg_type: u16, flags: u16) !*NlMsgHdr {
        if (self.offset + @sizeOf(NlMsgHdr) > self.buffer.len) {
            return error.BufferTooSmall;
        }

        const hdr: *NlMsgHdr = @ptrCast(@alignCast(self.buffer[self.offset..].ptr));
        hdr.* = NlMsgHdr{
            .len = @sizeOf(NlMsgHdr),
            .type = msg_type,
            .flags = flags,
            .seq = self.seq,
            .pid = self.pid,
        };

        self.offset += @sizeOf(NlMsgHdr);
        return hdr;
    }

    pub fn addData(self: *Self, comptime T: type, data: T) !void {
        const size = @sizeOf(T);
        if (self.offset + size > self.buffer.len) {
            return error.BufferTooSmall;
        }

        const ptr: *T = @ptrCast(@alignCast(self.buffer[self.offset..].ptr));
        ptr.* = data;
        self.offset += size;
    }

    pub fn addAttr(self: *Self, attr_type: u16, data: []const u8) !void {
        const attr_len = @sizeOf(NlAttr) + data.len;
        const padded_len = nlAlign(attr_len);

        if (self.offset + padded_len > self.buffer.len) {
            return error.BufferTooSmall;
        }

        const attr: *NlAttr = @ptrCast(@alignCast(self.buffer[self.offset..].ptr));
        attr.* = NlAttr{
            .len = @intCast(attr_len),
            .type = attr_type,
        };

        const data_start = self.offset + @sizeOf(NlAttr);
        @memcpy(self.buffer[data_start .. data_start + data.len], data);

        // Zero padding
        const pad_start = data_start + data.len;
        const pad_end = self.offset + padded_len;
        @memset(self.buffer[pad_start..pad_end], 0);

        self.offset += padded_len;
    }

    pub fn addAttrU32(self: *Self, attr_type: u16, value: u32) !void {
        try self.addAttr(attr_type, std.mem.asBytes(&value));
    }

    pub fn addAttrString(self: *Self, attr_type: u16, str: []const u8) !void {
        // Include null terminator
        const attr_len = @sizeOf(NlAttr) + str.len + 1;
        const padded_len = nlAlign(attr_len);

        if (self.offset + padded_len > self.buffer.len) {
            return error.BufferTooSmall;
        }

        const attr: *NlAttr = @ptrCast(@alignCast(self.buffer[self.offset..].ptr));
        attr.* = NlAttr{
            .len = @intCast(attr_len),
            .type = attr_type,
        };

        const data_start = self.offset + @sizeOf(NlAttr);
        @memcpy(self.buffer[data_start .. data_start + str.len], str);
        self.buffer[data_start + str.len] = 0; // null terminator

        // Zero padding
        const pad_start = data_start + str.len + 1;
        const pad_end = self.offset + padded_len;
        if (pad_start < pad_end) {
            @memset(self.buffer[pad_start..pad_end], 0);
        }

        self.offset += padded_len;
    }

    pub fn addAttrU8(self: *Self, attr_type: u16, value: u8) !void {
        try self.addAttr(attr_type, std.mem.asBytes(&value));
    }

    pub fn addAttrU16(self: *Self, attr_type: u16, value: u16) !void {
        try self.addAttr(attr_type, std.mem.asBytes(&value));
    }

    /// Start a nested attribute. Returns the offset where the nested attr header is.
    /// Use endNestedAttr to finalize.
    pub fn startNestedAttr(self: *Self, attr_type: u16) !usize {
        if (self.offset + @sizeOf(NlAttr) > self.buffer.len) {
            return error.BufferTooSmall;
        }

        const start = self.offset;
        const attr: *NlAttr = @ptrCast(@alignCast(self.buffer[self.offset..].ptr));
        attr.* = NlAttr{
            .len = @sizeOf(NlAttr), // Will be updated in endNestedAttr
            .type = attr_type,
        };

        self.offset += @sizeOf(NlAttr);
        return start;
    }

    /// End a nested attribute. Updates the length of the nested attr.
    pub fn endNestedAttr(self: *Self, start: usize) void {
        const attr: *NlAttr = @ptrCast(@alignCast(self.buffer[start..].ptr));
        attr.len = @intCast(self.offset - start);
        // Align to 4-byte boundary
        const padded_len = nlAlign(self.offset - start);
        const pad_size = padded_len - (self.offset - start);
        if (pad_size > 0 and self.offset + pad_size <= self.buffer.len) {
            @memset(self.buffer[self.offset .. self.offset + pad_size], 0);
            self.offset += pad_size;
        }
    }

    pub fn finalize(self: *Self, hdr: *NlMsgHdr) []u8 {
        hdr.len = @intCast(self.offset);
        return self.buffer[0..self.offset];
    }
};

/// Parse netlink attributes from a message payload
pub const AttrParser = struct {
    data: []const u8,
    offset: usize,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return Self{ .data = data, .offset = 0 };
    }

    pub fn next(self: *Self) ?struct { attr_type: u16, value: []const u8 } {
        if (self.offset + @sizeOf(NlAttr) > self.data.len) {
            return null;
        }

        const attr: *const NlAttr = @ptrCast(@alignCast(self.data[self.offset..].ptr));

        if (attr.len < @sizeOf(NlAttr) or self.offset + attr.len > self.data.len) {
            return null;
        }

        const value_start = self.offset + @sizeOf(NlAttr);
        const value_len = attr.len - @sizeOf(NlAttr);
        const value = self.data[value_start .. value_start + value_len];

        self.offset += nlAlign(attr.len);

        return .{ .attr_type = attr.type, .value = value };
    }
};

// Tests (these use only pure Zig, no syscalls)
test "NlMsgHdr size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(NlMsgHdr));
}

test "IfInfoMsg size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(IfInfoMsg));
}

test "nlAlign" {
    try std.testing.expectEqual(@as(usize, 0), nlAlign(0));
    try std.testing.expectEqual(@as(usize, 4), nlAlign(1));
    try std.testing.expectEqual(@as(usize, 4), nlAlign(4));
    try std.testing.expectEqual(@as(usize, 8), nlAlign(5));
    try std.testing.expectEqual(@as(usize, 20), nlAlign(17));
}

test "MessageBuilder basic" {
    var buf: [256]u8 = undefined;
    var builder = MessageBuilder.init(&buf, 1, 1000);

    const hdr = try builder.addHeader(RTM.GETLINK, NLM_F.REQUEST | NLM_F.DUMP);
    try builder.addData(IfInfoMsg, IfInfoMsg{});

    const msg = builder.finalize(hdr);

    try std.testing.expectEqual(@as(usize, 32), msg.len); // 16 (hdr) + 16 (ifinfomsg)
    try std.testing.expectEqual(@as(u16, RTM.GETLINK), hdr.type);
}

test "AttrParser" {
    // Build a simple attribute buffer
    var buf: [64]u8 = undefined;

    // Attribute: type=3 (IFNAME), value="eth0\0"
    const attr: *NlAttr = @ptrCast(@alignCast(&buf));
    attr.* = NlAttr{ .len = 9, .type = IFLA.IFNAME }; // 4 + 5 (eth0\0)
    @memcpy(buf[4..9], "eth0\x00");

    var parser = AttrParser.init(buf[0..12]); // Include padding

    if (parser.next()) |parsed| {
        try std.testing.expectEqual(@as(u16, IFLA.IFNAME), parsed.attr_type);
        try std.testing.expectEqualStrings("eth0\x00", parsed.value);
    } else {
        return error.TestFailed;
    }
}
