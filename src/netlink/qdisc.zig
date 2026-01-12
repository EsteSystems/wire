const std = @import("std");
const socket = @import("socket.zig");
const linux = std.os.linux;

/// TC message header
pub const TcMsg = extern struct {
    family: u8 = 0,
    pad1: u8 = 0,
    pad2: u16 = 0,
    ifindex: i32 = 0,
    handle: u32 = 0,
    parent: u32 = 0,
    info: u32 = 0,
};

/// TC attributes
pub const TCA = struct {
    pub const UNSPEC: u16 = 0;
    pub const KIND: u16 = 1;
    pub const OPTIONS: u16 = 2;
    pub const STATS: u16 = 3;
    pub const XSTATS: u16 = 4;
    pub const RATE: u16 = 5;
    pub const FCNT: u16 = 6;
    pub const STATS2: u16 = 7;
    pub const STAB: u16 = 8;
    pub const PAD: u16 = 9;
    pub const DUMP_INVISIBLE: u16 = 10;
    pub const CHAIN: u16 = 11;
    pub const HW_OFFLOAD: u16 = 12;
    pub const INGRESS_BLOCK: u16 = 13;
    pub const EGRESS_BLOCK: u16 = 14;
};

/// Special handles
pub const TC_H = struct {
    pub const ROOT: u32 = 0xFFFFFFFF;
    pub const INGRESS: u32 = 0xFFFFFFF1;
    pub const CLSACT: u32 = 0xFFFFFFF2;
    pub const UNSPEC: u32 = 0;

    /// Make handle from major:minor
    pub fn make(maj: u16, min: u16) u32 {
        return (@as(u32, maj) << 16) | @as(u32, min);
    }

    /// Get major part of handle
    pub fn getMajor(handle: u32) u16 {
        return @intCast(handle >> 16);
    }

    /// Get minor part of handle
    pub fn getMinor(handle: u32) u16 {
        return @intCast(handle & 0xFFFF);
    }
};

/// TBF (Token Bucket Filter) parameters
pub const TcTbfQopt = extern struct {
    rate: TcRateSpec,
    peakrate: TcRateSpec,
    limit: u32,
    buffer: u32,
    mtu: u32,
};

/// Rate specification
pub const TcRateSpec = extern struct {
    cell_log: u8 = 0,
    linklayer: u8 = 1, // ATM=0, ETHERNET=1
    overhead: u16 = 0,
    cell_align: i16 = 0,
    mpu: u16 = 0,
    rate: u32 = 0,
};

/// TBF attribute types
pub const TCA_TBF = struct {
    pub const UNSPEC: u16 = 0;
    pub const PARMS: u16 = 1;
    pub const RTAB: u16 = 2;
    pub const PTAB: u16 = 3;
    pub const RATE64: u16 = 4;
    pub const PRATE64: u16 = 5;
    pub const BURST: u16 = 6;
    pub const PBURST: u16 = 7;
    pub const PAD: u16 = 8;
};

/// HTB parameters
pub const TcHtbGlob = extern struct {
    version: u32 = 3,
    rate2quantum: u32 = 10,
    defcls: u32 = 0,
    debug: u32 = 0,
    direct_pkts: u32 = 0,
};

pub const TcHtbOpt = extern struct {
    rate: TcRateSpec,
    ceil: TcRateSpec,
    buffer: u32,
    cbuffer: u32,
    quantum: u32,
    level: u32,
    prio: u32,
};

/// HTB attribute types
pub const TCA_HTB = struct {
    pub const UNSPEC: u16 = 0;
    pub const PARMS: u16 = 1;
    pub const INIT: u16 = 2;
    pub const CTAB: u16 = 3;
    pub const RTAB: u16 = 4;
    pub const DIRECT_QLEN: u16 = 5;
    pub const RATE64: u16 = 6;
    pub const CEIL64: u16 = 7;
    pub const PAD: u16 = 8;
    pub const OFFLOAD: u16 = 9;
};

/// Qdisc info
pub const QdiscInfo = struct {
    handle: u32,
    parent: u32,
    kind: [32]u8,
    kind_len: usize,
    ifindex: i32,

    pub fn getKind(self: *const QdiscInfo) []const u8 {
        return self.kind[0..self.kind_len];
    }

    pub fn formatHandle(self: *const QdiscInfo, buf: []u8) ![]const u8 {
        const major = TC_H.getMajor(self.handle);
        const minor = TC_H.getMinor(self.handle);
        if (minor == 0) {
            return std.fmt.bufPrint(buf, "{d}:", .{major});
        } else {
            return std.fmt.bufPrint(buf, "{d}:{d}", .{ major, minor });
        }
    }

    pub fn formatParent(self: *const QdiscInfo, buf: []u8) ![]const u8 {
        if (self.parent == TC_H.ROOT) {
            return "root";
        } else if (self.parent == TC_H.INGRESS) {
            return "ingress";
        } else if (self.parent == TC_H.CLSACT) {
            return "clsact";
        } else {
            const major = TC_H.getMajor(self.parent);
            const minor = TC_H.getMinor(self.parent);
            return std.fmt.bufPrint(buf, "{d}:{d}", .{ major, minor });
        }
    }
};

/// Get all qdiscs for an interface
pub fn getQdiscs(allocator: std.mem.Allocator, if_index: i32) ![]QdiscInfo {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [128]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.GETQDISC, socket.NLM_F.REQUEST | socket.NLM_F.DUMP);
    try builder.addData(TcMsg, TcMsg{ .ifindex = if_index });

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    defer allocator.free(response);

    var qdiscs = std.ArrayList(QdiscInfo).init(allocator);
    errdefer qdiscs.deinit();

    // Parse response
    var offset: usize = 0;
    while (offset + @sizeOf(socket.NlMsgHdr) <= response.len) {
        const resp_hdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(response[offset..].ptr));

        if (resp_hdr.type == socket.NLMSG.DONE or resp_hdr.type == socket.NLMSG.ERROR) {
            break;
        }

        if (resp_hdr.type == socket.RTM.NEWQDISC) {
            const tc_start = offset + @sizeOf(socket.NlMsgHdr);
            if (tc_start + @sizeOf(TcMsg) <= response.len) {
                const tcmsg: *const TcMsg = @ptrCast(@alignCast(response[tc_start..].ptr));

                var info = QdiscInfo{
                    .handle = tcmsg.handle,
                    .parent = tcmsg.parent,
                    .kind = undefined,
                    .kind_len = 0,
                    .ifindex = tcmsg.ifindex,
                };
                @memset(&info.kind, 0);

                // Parse attributes for kind
                const attr_start = tc_start + @sizeOf(TcMsg);
                if (attr_start < offset + resp_hdr.len) {
                    var parser = socket.AttrParser.init(response[attr_start .. offset + resp_hdr.len]);
                    while (parser.next()) |attr| {
                        if (attr.attr_type == TCA.KIND) {
                            const copy_len = @min(attr.value.len, info.kind.len);
                            @memcpy(info.kind[0..copy_len], attr.value[0..copy_len]);
                            // Find null terminator
                            for (attr.value, 0..) |c, i| {
                                if (c == 0) {
                                    info.kind_len = i;
                                    break;
                                }
                            } else {
                                info.kind_len = copy_len;
                            }
                        }
                    }
                }

                // Only add if it matches our interface (or if if_index is 0)
                if (if_index == 0 or tcmsg.ifindex == if_index) {
                    try qdiscs.append(info);
                }
            }
        }

        offset += socket.nlAlign(resp_hdr.len);
    }

    return qdiscs.toOwnedSlice();
}

/// Add a simple FIFO qdisc
pub fn addPfifoQdisc(if_index: i32, handle: u32, parent: u32, limit: ?u32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWQDISC, socket.NLM_F.REQUEST | socket.NLM_F.CREATE | socket.NLM_F.EXCL | socket.NLM_F.ACK);

    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .handle = handle,
        .parent = parent,
    });

    try builder.addAttrString(TCA.KIND, "pfifo");

    // Add limit option if specified
    if (limit) |l| {
        const options_start = try builder.startNestedAttr(TCA.OPTIONS);
        // pfifo uses tc_fifo_qopt which is just a u32 limit
        try builder.addAttr(1, std.mem.asBytes(&l)); // TCA_FIFO_PARMS
        builder.endNestedAttr(options_start);
    }

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Add a TBF (Token Bucket Filter) qdisc for rate limiting
pub fn addTbfQdisc(if_index: i32, handle: u32, parent: u32, rate_bps: u64, burst: u32, latency_us: u32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWQDISC, socket.NLM_F.REQUEST | socket.NLM_F.CREATE | socket.NLM_F.EXCL | socket.NLM_F.ACK);

    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .handle = handle,
        .parent = parent,
    });

    try builder.addAttrString(TCA.KIND, "tbf");

    // Calculate limit from latency and rate
    // limit = rate * latency + burst
    const rate_bytes_per_us = rate_bps / 8_000_000;
    const limit = @as(u32, @intCast(rate_bytes_per_us * latency_us)) + burst;

    const options_start = try builder.startNestedAttr(TCA.OPTIONS);

    var params = TcTbfQopt{
        .rate = TcRateSpec{
            .rate = @intCast(@min(rate_bps / 8, 0xFFFFFFFF)),
        },
        .peakrate = TcRateSpec{},
        .limit = limit,
        .buffer = burst,
        .mtu = 1514,
    };

    try builder.addAttr(TCA_TBF.PARMS, std.mem.asBytes(&params));

    // If rate > 32-bit max, add 64-bit rate
    if (rate_bps / 8 > 0xFFFFFFFF) {
        const rate64 = rate_bps / 8;
        try builder.addAttr(TCA_TBF.RATE64, std.mem.asBytes(&rate64));
    }

    // Add burst explicitly
    try builder.addAttrU32(TCA_TBF.BURST, burst);

    builder.endNestedAttr(options_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Add fq_codel qdisc (fair queuing with controlled delay)
pub fn addFqCodelQdisc(if_index: i32, handle: u32, parent: u32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWQDISC, socket.NLM_F.REQUEST | socket.NLM_F.CREATE | socket.NLM_F.EXCL | socket.NLM_F.ACK);

    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .handle = handle,
        .parent = parent,
    });

    try builder.addAttrString(TCA.KIND, "fq_codel");

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a qdisc
pub fn deleteQdisc(if_index: i32, handle: u32, parent: u32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [128]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.DELQDISC, socket.NLM_F.REQUEST | socket.NLM_F.ACK);

    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .handle = handle,
        .parent = parent,
    });

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Replace or add qdisc (useful for changing root qdisc)
pub fn replaceQdisc(if_index: i32, kind: []const u8) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    // NLM_F_CREATE | NLM_F_REPLACE allows replacement
    const hdr = try builder.addHeader(socket.RTM.NEWQDISC, socket.NLM_F.REQUEST | socket.NLM_F.CREATE | socket.NLM_F.ACK);

    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .handle = TC_H.make(1, 0),
        .parent = TC_H.ROOT,
    });

    try builder.addAttrString(TCA.KIND, kind);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

// Tests

test "TC_H.make" {
    try std.testing.expectEqual(@as(u32, 0x00010000), TC_H.make(1, 0));
    try std.testing.expectEqual(@as(u32, 0x00010001), TC_H.make(1, 1));
}

test "TcMsg size" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(TcMsg));
}
