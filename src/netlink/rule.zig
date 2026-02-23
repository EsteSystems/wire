const std = @import("std");
const socket = @import("socket.zig");
const linux = std.os.linux;

/// Fib rule message (for RTM_*RULE)
pub const FibRuleHdr = extern struct {
    family: u8 = linux.AF.INET,
    dst_len: u8 = 0,
    src_len: u8 = 0,
    tos: u8 = 0,
    table: u8 = 0, // Routing table ID (use FRA_TABLE for > 255)
    res1: u8 = 0,
    res2: u8 = 0,
    action: u8 = FR_ACT.TO_TBL,
    flags: u32 = 0,
};

/// Fib rule actions
pub const FR_ACT = struct {
    pub const UNSPEC: u8 = 0;
    pub const TO_TBL: u8 = 1; // Pass to routing table
    pub const GOTO: u8 = 2; // Jump to another rule
    pub const NOP: u8 = 3; // No operation
    pub const RES3: u8 = 4;
    pub const RES4: u8 = 5;
    pub const BLACKHOLE: u8 = 6;
    pub const UNREACHABLE: u8 = 7;
    pub const PROHIBIT: u8 = 8;
};

/// Fib rule attributes (FRA_*)
pub const FRA = struct {
    pub const UNSPEC: u16 = 0;
    pub const DST: u16 = 1; // Destination prefix
    pub const SRC: u16 = 2; // Source prefix
    pub const IIFNAME: u16 = 3; // Input interface name
    pub const GOTO: u16 = 4; // Target rule priority for GOTO
    pub const UNUSED2: u16 = 5;
    pub const PRIORITY: u16 = 6; // Rule priority (0-32767)
    pub const UNUSED3: u16 = 7;
    pub const UNUSED4: u16 = 8;
    pub const UNUSED5: u16 = 9;
    pub const FWMARK: u16 = 10; // Firewall mark
    pub const FLOW: u16 = 11;
    pub const TUN_ID: u16 = 12;
    pub const SUPPRESS_IFGROUP: u16 = 13;
    pub const SUPPRESS_PREFIXLEN: u16 = 14;
    pub const TABLE: u16 = 15; // Extended routing table ID (u32)
    pub const FWMASK: u16 = 16; // Firewall mark mask
    pub const OIFNAME: u16 = 17; // Output interface name
    pub const PAD: u16 = 18;
    pub const L3MDEV: u16 = 19;
    pub const UID_RANGE: u16 = 20;
    pub const PROTOCOL: u16 = 21;
    pub const IP_PROTO: u16 = 22;
    pub const SPORT_RANGE: u16 = 23;
    pub const DPORT_RANGE: u16 = 24;
};

/// Well-known routing table IDs
pub const RT_TABLE = struct {
    pub const UNSPEC: u32 = 0;
    pub const COMPAT: u32 = 252;
    pub const DEFAULT: u32 = 253;
    pub const MAIN: u32 = 254;
    pub const LOCAL: u32 = 255;
};

/// IP rule entry
pub const Rule = struct {
    family: u8,
    priority: u32,
    table: u32,
    action: u8,
    src_len: u8,
    dst_len: u8,
    src: [16]u8,
    dst: [16]u8,
    iifname: [16]u8,
    iifname_len: usize,
    oifname: [16]u8,
    oifname_len: usize,
    fwmark: u32,
    fwmask: u32,

    const Self = @This();

    pub fn getIifname(self: *const Self) ?[]const u8 {
        if (self.iifname_len == 0) return null;
        return self.iifname[0..self.iifname_len];
    }

    pub fn getOifname(self: *const Self) ?[]const u8 {
        if (self.oifname_len == 0) return null;
        return self.oifname[0..self.oifname_len];
    }

    pub fn tableName(self: *const Self) []const u8 {
        return switch (self.table) {
            RT_TABLE.LOCAL => "local",
            RT_TABLE.MAIN => "main",
            RT_TABLE.DEFAULT => "default",
            else => "custom",
        };
    }

    pub fn actionName(self: *const Self) []const u8 {
        return switch (self.action) {
            FR_ACT.TO_TBL => "lookup",
            FR_ACT.GOTO => "goto",
            FR_ACT.NOP => "nop",
            FR_ACT.BLACKHOLE => "blackhole",
            FR_ACT.UNREACHABLE => "unreachable",
            FR_ACT.PROHIBIT => "prohibit",
            else => "unknown",
        };
    }

    /// Format source prefix
    pub fn formatSrc(self: *const Self, buf: []u8) ![]const u8 {
        if (self.src_len == 0) return "all";
        if (self.family == linux.AF.INET) {
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}/{d}", .{
                self.src[0], self.src[1], self.src[2], self.src[3], self.src_len,
            });
        }
        return "?";
    }

    /// Format destination prefix
    pub fn formatDst(self: *const Self, buf: []u8) ![]const u8 {
        if (self.dst_len == 0) return "all";
        if (self.family == linux.AF.INET) {
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}/{d}", .{
                self.dst[0], self.dst[1], self.dst[2], self.dst[3], self.dst_len,
            });
        }
        return "?";
    }
};

/// Get all IP rules
pub fn getRules(allocator: std.mem.Allocator, family: u8) ![]Rule {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.GETRULE, socket.NLM_F.REQUEST | socket.NLM_F.DUMP);
    try builder.addData(FibRuleHdr, FibRuleHdr{ .family = family });

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    defer allocator.free(response);

    var rules = std.array_list.Managed(Rule).init(allocator);
    errdefer rules.deinit();

    var offset: usize = 0;
    while (offset + @sizeOf(socket.NlMsgHdr) <= response.len) {
        const nlhdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(response[offset..].ptr));

        if (nlhdr.len < @sizeOf(socket.NlMsgHdr) or offset + nlhdr.len > response.len) {
            break;
        }

        if (nlhdr.type == socket.RTM.NEWRULE) {
            const frh_offset = offset + @sizeOf(socket.NlMsgHdr);
            if (frh_offset + @sizeOf(FibRuleHdr) <= response.len) {
                const frh: *const FibRuleHdr = @ptrCast(@alignCast(response[frh_offset..].ptr));

                var rule = Rule{
                    .family = frh.family,
                    .priority = 0,
                    .table = frh.table,
                    .action = frh.action,
                    .src_len = frh.src_len,
                    .dst_len = frh.dst_len,
                    .src = undefined,
                    .dst = undefined,
                    .iifname = undefined,
                    .iifname_len = 0,
                    .oifname = undefined,
                    .oifname_len = 0,
                    .fwmark = 0,
                    .fwmask = 0,
                };
                @memset(&rule.src, 0);
                @memset(&rule.dst, 0);
                @memset(&rule.iifname, 0);
                @memset(&rule.oifname, 0);

                // Parse attributes
                const attrs_offset = frh_offset + @sizeOf(FibRuleHdr);
                const attrs_len = nlhdr.len - @sizeOf(socket.NlMsgHdr) - @sizeOf(FibRuleHdr);

                if (attrs_offset + attrs_len <= response.len) {
                    var parser = socket.AttrParser.init(response[attrs_offset .. attrs_offset + attrs_len]);

                    while (parser.next()) |attr| {
                        switch (attr.attr_type) {
                            FRA.PRIORITY => {
                                if (attr.value.len >= 4) {
                                    rule.priority = std.mem.readInt(u32, attr.value[0..4], .little);
                                }
                            },
                            FRA.TABLE => {
                                if (attr.value.len >= 4) {
                                    rule.table = std.mem.readInt(u32, attr.value[0..4], .little);
                                }
                            },
                            FRA.SRC => {
                                const copy_len = @min(attr.value.len, rule.src.len);
                                @memcpy(rule.src[0..copy_len], attr.value[0..copy_len]);
                            },
                            FRA.DST => {
                                const copy_len = @min(attr.value.len, rule.dst.len);
                                @memcpy(rule.dst[0..copy_len], attr.value[0..copy_len]);
                            },
                            FRA.IIFNAME => {
                                const copy_len = @min(attr.value.len, rule.iifname.len);
                                @memcpy(rule.iifname[0..copy_len], attr.value[0..copy_len]);
                                rule.iifname_len = copy_len;
                                // Remove null terminator from length
                                while (rule.iifname_len > 0 and rule.iifname[rule.iifname_len - 1] == 0) {
                                    rule.iifname_len -= 1;
                                }
                            },
                            FRA.OIFNAME => {
                                const copy_len = @min(attr.value.len, rule.oifname.len);
                                @memcpy(rule.oifname[0..copy_len], attr.value[0..copy_len]);
                                rule.oifname_len = copy_len;
                                while (rule.oifname_len > 0 and rule.oifname[rule.oifname_len - 1] == 0) {
                                    rule.oifname_len -= 1;
                                }
                            },
                            FRA.FWMARK => {
                                if (attr.value.len >= 4) {
                                    rule.fwmark = std.mem.readInt(u32, attr.value[0..4], .little);
                                }
                            },
                            FRA.FWMASK => {
                                if (attr.value.len >= 4) {
                                    rule.fwmask = std.mem.readInt(u32, attr.value[0..4], .little);
                                }
                            },
                            else => {},
                        }
                    }
                }

                try rules.append(rule);
            }
        }

        offset += socket.nlAlign(nlhdr.len);
    }

    return rules.toOwnedSlice();
}

/// Add an IP rule
pub fn addRule(family: u8, priority: u32, table: u32, options: RuleOptions) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWRULE, socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.EXCL);

    // Use table ID 0 in header if > 255 (use FRA_TABLE attribute instead)
    const table_hdr: u8 = if (table > 255) 0 else @intCast(table);

    try builder.addData(FibRuleHdr, FibRuleHdr{
        .family = family,
        .src_len = options.src_len,
        .dst_len = options.dst_len,
        .table = table_hdr,
        .action = options.action,
    });

    // Priority
    try builder.addAttrU32(FRA.PRIORITY, priority);

    // Table (always use attribute for reliability)
    try builder.addAttrU32(FRA.TABLE, table);

    // Source prefix
    if (options.src_len > 0) {
        const addr_len: usize = if (family == linux.AF.INET) 4 else 16;
        try builder.addAttr(FRA.SRC, options.src[0..addr_len]);
    }

    // Destination prefix
    if (options.dst_len > 0) {
        const addr_len: usize = if (family == linux.AF.INET) 4 else 16;
        try builder.addAttr(FRA.DST, options.dst[0..addr_len]);
    }

    // Firewall mark
    if (options.fwmark > 0) {
        try builder.addAttrU32(FRA.FWMARK, options.fwmark);
        try builder.addAttrU32(FRA.FWMASK, options.fwmask);
    }

    // Input interface
    if (options.iifname_len > 0) {
        try builder.addAttrString(FRA.IIFNAME, options.iifname[0..options.iifname_len]);
    }

    // Output interface
    if (options.oifname_len > 0) {
        try builder.addAttrString(FRA.OIFNAME, options.oifname[0..options.oifname_len]);
    }

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete an IP rule by priority
pub fn deleteRule(family: u8, priority: u32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.DELRULE, socket.NLM_F.REQUEST | socket.NLM_F.ACK);

    try builder.addData(FibRuleHdr, FibRuleHdr{
        .family = family,
    });

    try builder.addAttrU32(FRA.PRIORITY, priority);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Options for adding a rule
pub const RuleOptions = struct {
    action: u8 = FR_ACT.TO_TBL,
    src: [16]u8 = undefined,
    src_len: u8 = 0,
    dst: [16]u8 = undefined,
    dst_len: u8 = 0,
    fwmark: u32 = 0,
    fwmask: u32 = 0xffffffff,
    iifname: [16]u8 = undefined,
    iifname_len: usize = 0,
    oifname: [16]u8 = undefined,
    oifname_len: usize = 0,

    pub fn init() RuleOptions {
        var opts = RuleOptions{};
        @memset(&opts.src, 0);
        @memset(&opts.dst, 0);
        @memset(&opts.iifname, 0);
        @memset(&opts.oifname, 0);
        return opts;
    }
};

/// Parse IPv4 prefix (e.g., "10.0.0.0/8")
pub fn parsePrefix(prefix: []const u8) ?struct { addr: [4]u8, len: u8 } {
    // Find the slash
    var slash_idx: ?usize = null;
    for (prefix, 0..) |c, i| {
        if (c == '/') {
            slash_idx = i;
            break;
        }
    }

    const addr_part = if (slash_idx) |idx| prefix[0..idx] else prefix;
    const len_part = if (slash_idx) |idx| prefix[idx + 1 ..] else null;

    // Parse IP
    var addr: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var current_value: u16 = 0;
    var has_digit = false;

    for (addr_part) |c| {
        if (c >= '0' and c <= '9') {
            current_value = current_value * 10 + (c - '0');
            if (current_value > 255) return null;
            has_digit = true;
        } else if (c == '.') {
            if (!has_digit or octet_idx >= 3) return null;
            addr[octet_idx] = @intCast(current_value);
            octet_idx += 1;
            current_value = 0;
            has_digit = false;
        } else {
            return null;
        }
    }

    if (!has_digit or octet_idx != 3) return null;
    addr[3] = @intCast(current_value);

    // Parse prefix length
    const prefix_len: u8 = if (len_part) |lp|
        std.fmt.parseInt(u8, lp, 10) catch return null
    else
        32;

    if (prefix_len > 32) return null;

    return .{ .addr = addr, .len = prefix_len };
}

// Tests

test "FibRuleHdr size" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(FibRuleHdr));
}

test "parsePrefix" {
    const result = parsePrefix("10.0.0.0/8");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 10), result.?.addr[0]);
    try std.testing.expectEqual(@as(u8, 8), result.?.len);
}

test "parsePrefix full" {
    const result = parsePrefix("192.168.1.1");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 32), result.?.len);
}
