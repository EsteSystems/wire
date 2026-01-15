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

/// Add HTB (Hierarchical Token Bucket) qdisc
/// HTB is the standard qdisc for class-based traffic shaping
pub fn addHtbQdisc(if_index: i32, handle: u32, parent: u32, default_class: ?u32) !void {
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

    try builder.addAttrString(TCA.KIND, "htb");

    // Add HTB global options
    const options_start = try builder.startNestedAttr(TCA.OPTIONS);

    var glob = TcHtbGlob{
        .version = 3,
        .rate2quantum = 10,
        .defcls = default_class orelse 0,
        .debug = 0,
        .direct_pkts = 0,
    };

    try builder.addAttr(TCA_HTB.INIT, std.mem.asBytes(&glob));

    builder.endNestedAttr(options_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Class info (for HTB classes)
pub const ClassInfo = struct {
    handle: u32,
    parent: u32,
    kind: [32]u8,
    kind_len: usize,
    ifindex: i32,

    pub fn getKind(self: *const ClassInfo) []const u8 {
        return self.kind[0..self.kind_len];
    }

    pub fn formatHandle(self: *const ClassInfo, buf: []u8) ![]const u8 {
        const major = TC_H.getMajor(self.handle);
        const minor = TC_H.getMinor(self.handle);
        if (minor == 0) {
            return std.fmt.bufPrint(buf, "{d}:", .{major});
        } else {
            return std.fmt.bufPrint(buf, "{d}:{d}", .{ major, minor });
        }
    }

    pub fn formatParent(self: *const ClassInfo, buf: []u8) ![]const u8 {
        if (self.parent == TC_H.ROOT) {
            return "root";
        } else {
            const major = TC_H.getMajor(self.parent);
            const minor = TC_H.getMinor(self.parent);
            if (minor == 0) {
                return std.fmt.bufPrint(buf, "{d}:", .{major});
            } else {
                return std.fmt.bufPrint(buf, "{d}:{d}", .{ major, minor });
            }
        }
    }
};

/// Get all classes for an interface
pub fn getClasses(allocator: std.mem.Allocator, if_index: i32) ![]ClassInfo {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [128]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.GETTCLASS, socket.NLM_F.REQUEST | socket.NLM_F.DUMP);
    try builder.addData(TcMsg, TcMsg{ .ifindex = if_index });

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    defer allocator.free(response);

    var classes = std.ArrayList(ClassInfo).init(allocator);
    errdefer classes.deinit();

    // Parse response
    var offset: usize = 0;
    while (offset + @sizeOf(socket.NlMsgHdr) <= response.len) {
        const resp_hdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(response[offset..].ptr));

        if (resp_hdr.type == socket.NLMSG.DONE or resp_hdr.type == socket.NLMSG.ERROR) {
            break;
        }

        if (resp_hdr.type == socket.RTM.NEWTCLASS) {
            const tc_start = offset + @sizeOf(socket.NlMsgHdr);
            if (tc_start + @sizeOf(TcMsg) <= response.len) {
                const tcmsg: *const TcMsg = @ptrCast(@alignCast(response[tc_start..].ptr));

                var info = ClassInfo{
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

                // Only add if it matches our interface
                if (if_index == 0 or tcmsg.ifindex == if_index) {
                    try classes.append(info);
                }
            }
        }

        offset += socket.nlAlign(resp_hdr.len);
    }

    return classes.toOwnedSlice();
}

/// Add an HTB class
/// rate_bps: guaranteed rate in bits per second
/// ceil_bps: maximum rate in bits per second (if 0, uses rate)
/// prio: priority (0 = highest, 7 = lowest)
pub fn addHtbClass(if_index: i32, classid: u32, parent: u32, rate_bps: u64, ceil_bps: u64, prio: u32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [1024]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWTCLASS, socket.NLM_F.REQUEST | socket.NLM_F.CREATE | socket.NLM_F.EXCL | socket.NLM_F.ACK);

    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .handle = classid,
        .parent = parent,
    });

    try builder.addAttrString(TCA.KIND, "htb");

    // Add HTB class options
    const options_start = try builder.startNestedAttr(TCA.OPTIONS);

    // Calculate buffer sizes (based on rate and 100ms burst time)
    const rate_bytes = rate_bps / 8;
    const actual_ceil = if (ceil_bps == 0) rate_bps else ceil_bps;
    const ceil_bytes = actual_ceil / 8;

    // Buffer = rate * burst_time (100ms = 0.1s)
    // Minimum buffer of 1600 bytes (one Ethernet frame)
    const buffer: u32 = @intCast(@max(rate_bytes / 10, 1600));
    const cbuffer: u32 = @intCast(@max(ceil_bytes / 10, 1600));

    var opt = TcHtbOpt{
        .rate = TcRateSpec{
            .rate = @intCast(@min(rate_bytes, 0xFFFFFFFF)),
        },
        .ceil = TcRateSpec{
            .rate = @intCast(@min(ceil_bytes, 0xFFFFFFFF)),
        },
        .buffer = buffer,
        .cbuffer = cbuffer,
        .quantum = 0, // Let kernel calculate
        .level = 0, // Leaf class
        .prio = prio,
    };

    try builder.addAttr(TCA_HTB.PARMS, std.mem.asBytes(&opt));

    // Add 64-bit rates if needed
    if (rate_bytes > 0xFFFFFFFF) {
        try builder.addAttr(TCA_HTB.RATE64, std.mem.asBytes(&rate_bytes));
    }
    if (ceil_bytes > 0xFFFFFFFF) {
        try builder.addAttr(TCA_HTB.CEIL64, std.mem.asBytes(&ceil_bytes));
    }

    builder.endNestedAttr(options_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a class
pub fn deleteClass(if_index: i32, classid: u32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [128]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.DELTCLASS, socket.NLM_F.REQUEST | socket.NLM_F.ACK);

    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .handle = classid,
        .parent = TC_H.ROOT,
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

/// Filter info
pub const FilterInfo = struct {
    handle: u32,
    parent: u32,
    priority: u16,
    protocol: u16,
    kind: [32]u8,
    kind_len: usize,
    ifindex: i32,

    pub fn getKind(self: *const FilterInfo) []const u8 {
        return self.kind[0..self.kind_len];
    }

    pub fn formatHandle(self: *const FilterInfo, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "0x{x}", .{self.handle});
    }

    pub fn formatParent(self: *const FilterInfo, buf: []u8) ![]const u8 {
        const major = TC_H.getMajor(self.parent);
        const minor = TC_H.getMinor(self.parent);
        if (minor == 0) {
            return std.fmt.bufPrint(buf, "{d}:", .{major});
        } else {
            return std.fmt.bufPrint(buf, "{d}:{d}", .{ major, minor });
        }
    }
};

/// Filter action attributes (for u32 filter)
pub const TCA_U32 = struct {
    pub const UNSPEC: u16 = 0;
    pub const CLASSID: u16 = 1;
    pub const HASH: u16 = 2;
    pub const LINK: u16 = 3;
    pub const DIVISOR: u16 = 4;
    pub const SEL: u16 = 5;
    pub const POLICE: u16 = 6;
    pub const ACT: u16 = 7;
    pub const INDEV: u16 = 8;
    pub const PCNT: u16 = 9;
    pub const MARK: u16 = 10;
    pub const FLAGS: u16 = 11;
    pub const PAD: u16 = 12;
};

/// U32 selector structure
pub const TcU32Sel = extern struct {
    flags: u8 = 0,
    offshift: u8 = 0,
    nkeys: u8 = 0,
    offmask: u8 = 0,
    off: u16 = 0,
    offoff: i16 = 0,
    hoff: i16 = 0,
    hmask: u32 = 0,
};

/// U32 key structure
pub const TcU32Key = extern struct {
    mask: u32 = 0,
    val: u32 = 0,
    off: i32 = 0,
    offmask: i32 = 0,
};

/// FW filter attributes
pub const TCA_FW = struct {
    pub const UNSPEC: u16 = 0;
    pub const CLASSID: u16 = 1;
    pub const POLICE: u16 = 2;
    pub const INDEV: u16 = 3;
    pub const ACT: u16 = 4;
    pub const MASK: u16 = 5;
};

/// Common protocol values
pub const ETH_P = struct {
    pub const ALL: u16 = 0x0003;
    pub const IP: u16 = 0x0800;
    pub const IPV6: u16 = 0x86DD;
    pub const ARP: u16 = 0x0806;
};

/// Get all filters for an interface/parent
pub fn getFilters(allocator: std.mem.Allocator, if_index: i32, parent: u32) ![]FilterInfo {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [128]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.GETTFILTER, socket.NLM_F.REQUEST | socket.NLM_F.DUMP);
    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .parent = parent,
    });

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    defer allocator.free(response);

    var filters = std.ArrayList(FilterInfo).init(allocator);
    errdefer filters.deinit();

    // Parse response
    var offset: usize = 0;
    while (offset + @sizeOf(socket.NlMsgHdr) <= response.len) {
        const resp_hdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(response[offset..].ptr));

        if (resp_hdr.type == socket.NLMSG.DONE or resp_hdr.type == socket.NLMSG.ERROR) {
            break;
        }

        if (resp_hdr.type == socket.RTM.NEWTFILTER) {
            const tc_start = offset + @sizeOf(socket.NlMsgHdr);
            if (tc_start + @sizeOf(TcMsg) <= response.len) {
                const tcmsg: *const TcMsg = @ptrCast(@alignCast(response[tc_start..].ptr));

                var info = FilterInfo{
                    .handle = tcmsg.handle,
                    .parent = tcmsg.parent,
                    .priority = @intCast((tcmsg.info >> 16) & 0xFFFF),
                    .protocol = @intCast(tcmsg.info & 0xFFFF),
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

                if (if_index == 0 or tcmsg.ifindex == if_index) {
                    try filters.append(info);
                }
            }
        }

        offset += socket.nlAlign(resp_hdr.len);
    }

    return filters.toOwnedSlice();
}

/// Add a u32 filter to match destination IP and direct to class
pub fn addU32FilterDstIP(if_index: i32, parent: u32, prio: u16, dst_ip: [4]u8, dst_mask: [4]u8, classid: u32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    // Filter info: priority in upper 16 bits, protocol in lower 16 bits
    const info: u32 = (@as(u32, prio) << 16) | @as(u32, std.mem.nativeToBig(u16, ETH_P.IP));

    const hdr = try builder.addHeader(socket.RTM.NEWTFILTER, socket.NLM_F.REQUEST | socket.NLM_F.CREATE | socket.NLM_F.EXCL | socket.NLM_F.ACK);

    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .handle = 0,
        .parent = parent,
        .info = info,
    });

    try builder.addAttrString(TCA.KIND, "u32");

    const options_start = try builder.startNestedAttr(TCA.OPTIONS);

    // Add classid
    try builder.addAttrU32(TCA_U32.CLASSID, classid);

    // Build selector with 1 key for dst IP
    // IP destination offset is 16 bytes into IP header
    var sel = TcU32Sel{
        .nkeys = 1,
    };

    var key = TcU32Key{
        .mask = std.mem.readInt(u32, &dst_mask, .big),
        .val = std.mem.readInt(u32, &dst_ip, .big),
        .off = 16, // Offset of destination IP in IP header
        .offmask = 0,
    };

    // TCA_U32_SEL contains the selector followed by keys
    var sel_buf: [128]u8 = undefined;
    const sel_bytes = std.mem.asBytes(&sel);
    const key_bytes = std.mem.asBytes(&key);
    @memcpy(sel_buf[0..sel_bytes.len], sel_bytes);
    @memcpy(sel_buf[sel_bytes.len .. sel_bytes.len + key_bytes.len], key_bytes);

    try builder.addAttr(TCA_U32.SEL, sel_buf[0 .. sel_bytes.len + key_bytes.len]);

    builder.endNestedAttr(options_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Add a fw (firewall mark) filter to direct marked packets to class
pub fn addFwFilter(if_index: i32, parent: u32, prio: u16, fwmark: u32, classid: u32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    // Filter info: priority in upper 16 bits, protocol in lower 16 bits
    const info: u32 = (@as(u32, prio) << 16) | @as(u32, std.mem.nativeToBig(u16, ETH_P.IP));

    const hdr = try builder.addHeader(socket.RTM.NEWTFILTER, socket.NLM_F.REQUEST | socket.NLM_F.CREATE | socket.NLM_F.EXCL | socket.NLM_F.ACK);

    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .handle = fwmark, // Handle is the fwmark value
        .parent = parent,
        .info = info,
    });

    try builder.addAttrString(TCA.KIND, "fw");

    const options_start = try builder.startNestedAttr(TCA.OPTIONS);

    // Add classid
    try builder.addAttrU32(TCA_FW.CLASSID, classid);

    builder.endNestedAttr(options_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a filter
pub fn deleteFilter(if_index: i32, parent: u32, prio: u16, handle: u32, protocol: u16) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [128]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const info: u32 = (@as(u32, prio) << 16) | @as(u32, std.mem.nativeToBig(u16, protocol));

    const hdr = try builder.addHeader(socket.RTM.DELTFILTER, socket.NLM_F.REQUEST | socket.NLM_F.ACK);

    try builder.addData(TcMsg, TcMsg{
        .ifindex = if_index,
        .handle = handle,
        .parent = parent,
        .info = info,
    });

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
