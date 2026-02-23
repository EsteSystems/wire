const std = @import("std");
const socket = @import("socket.zig");
const interface = @import("interface.zig");
const linux = std.os.linux;

/// Bond mode enumeration
pub const BondMode = enum(u8) {
    balance_rr = 0,
    active_backup = 1,
    balance_xor = 2,
    broadcast = 3,
    @"802.3ad" = 4,
    balance_tlb = 5,
    balance_alb = 6,

    pub fn fromString(str: []const u8) ?BondMode {
        if (std.mem.eql(u8, str, "balance-rr") or std.mem.eql(u8, str, "0")) return .balance_rr;
        if (std.mem.eql(u8, str, "active-backup") or std.mem.eql(u8, str, "1")) return .active_backup;
        if (std.mem.eql(u8, str, "balance-xor") or std.mem.eql(u8, str, "2")) return .balance_xor;
        if (std.mem.eql(u8, str, "broadcast") or std.mem.eql(u8, str, "3")) return .broadcast;
        if (std.mem.eql(u8, str, "802.3ad") or std.mem.eql(u8, str, "4")) return .@"802.3ad";
        if (std.mem.eql(u8, str, "balance-tlb") or std.mem.eql(u8, str, "5")) return .balance_tlb;
        if (std.mem.eql(u8, str, "balance-alb") or std.mem.eql(u8, str, "6")) return .balance_alb;
        return null;
    }

    pub fn toString(self: BondMode) []const u8 {
        return switch (self) {
            .balance_rr => "balance-rr",
            .active_backup => "active-backup",
            .balance_xor => "balance-xor",
            .broadcast => "broadcast",
            .@"802.3ad" => "802.3ad",
            .balance_tlb => "balance-tlb",
            .balance_alb => "balance-alb",
        };
    }
};

/// LACP rate (for 802.3ad mode)
pub const LacpRate = enum(u8) {
    slow = 0, // 30 second interval
    fast = 1, // 1 second interval

    pub fn fromString(str: []const u8) ?LacpRate {
        if (std.mem.eql(u8, str, "slow") or std.mem.eql(u8, str, "0")) return .slow;
        if (std.mem.eql(u8, str, "fast") or std.mem.eql(u8, str, "1")) return .fast;
        return null;
    }

    pub fn toString(self: LacpRate) []const u8 {
        return switch (self) {
            .slow => "slow",
            .fast => "fast",
        };
    }
};

/// Transmit hash policy (for load balancing modes)
pub const XmitHashPolicy = enum(u8) {
    layer2 = 0, // Uses XOR of MAC addresses
    layer3_4 = 1, // Uses upper layer (IP + port) info
    layer2_3 = 2, // Uses XOR of MAC + IP addresses
    encap2_3 = 3, // Uses encapsulated layer 2+3
    encap3_4 = 4, // Uses encapsulated layer 3+4
    vlan_srcmac = 5, // Uses VLAN + source MAC

    pub fn fromString(str: []const u8) ?XmitHashPolicy {
        if (std.mem.eql(u8, str, "layer2") or std.mem.eql(u8, str, "0")) return .layer2;
        if (std.mem.eql(u8, str, "layer3+4") or std.mem.eql(u8, str, "1")) return .layer3_4;
        if (std.mem.eql(u8, str, "layer2+3") or std.mem.eql(u8, str, "2")) return .layer2_3;
        if (std.mem.eql(u8, str, "encap2+3") or std.mem.eql(u8, str, "3")) return .encap2_3;
        if (std.mem.eql(u8, str, "encap3+4") or std.mem.eql(u8, str, "4")) return .encap3_4;
        if (std.mem.eql(u8, str, "vlan+srcmac") or std.mem.eql(u8, str, "5")) return .vlan_srcmac;
        return null;
    }

    pub fn toString(self: XmitHashPolicy) []const u8 {
        return switch (self) {
            .layer2 => "layer2",
            .layer3_4 => "layer3+4",
            .layer2_3 => "layer2+3",
            .encap2_3 => "encap2+3",
            .encap3_4 => "encap3+4",
            .vlan_srcmac => "vlan+srcmac",
        };
    }
};

/// Aggregator selection logic (for 802.3ad mode)
pub const AdSelect = enum(u8) {
    stable = 0, // Default, don't reselect unless partner changes
    bandwidth = 1, // Select based on total bandwidth
    count = 2, // Select based on number of ports

    pub fn fromString(str: []const u8) ?AdSelect {
        if (std.mem.eql(u8, str, "stable") or std.mem.eql(u8, str, "0")) return .stable;
        if (std.mem.eql(u8, str, "bandwidth") or std.mem.eql(u8, str, "1")) return .bandwidth;
        if (std.mem.eql(u8, str, "count") or std.mem.eql(u8, str, "2")) return .count;
        return null;
    }

    pub fn toString(self: AdSelect) []const u8 {
        return switch (self) {
            .stable => "stable",
            .bandwidth => "bandwidth",
            .count => "count",
        };
    }
};

/// Bond creation options
pub const BondOptions = struct {
    mode: BondMode = .balance_rr,
    miimon: u32 = 100, // MII monitoring interval (ms)
    updelay: u32 = 0, // Delay before enabling slave (ms)
    downdelay: u32 = 0, // Delay before disabling slave (ms)
    lacp_rate: ?LacpRate = null, // Only for 802.3ad
    xmit_hash_policy: ?XmitHashPolicy = null, // For modes that do load balancing
    ad_select: ?AdSelect = null, // Only for 802.3ad
};

/// Bond information
pub const Bond = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    mode: BondMode,
    miimon: u32,
    updelay: u32,
    downdelay: u32,
    members: [MAX_BOND_MEMBERS]i32,
    member_count: usize,
    flags: u32,
    xmit_hash_policy: ?XmitHashPolicy,
    lacp_rate: ?LacpRate,
    ad_select: ?AdSelect,

    const MAX_BOND_MEMBERS = 16;

    pub fn getName(self: *const Bond) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isUp(self: *const Bond) bool {
        return (self.flags & socket.IFF.UP) != 0;
    }

    pub fn getMembers(self: *const Bond) []const i32 {
        return self.members[0..self.member_count];
    }
};

/// Build bond IFLA_LINKINFO/IFLA_INFO_DATA attributes into a message builder
fn buildBondInfoData(builder: *socket.MessageBuilder, options: BondOptions) !void {
    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);

    try builder.addAttrString(socket.IFLA_INFO.KIND, "bond");

    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);

    try builder.addAttrU8(socket.IFLA_BOND.MODE, @intFromEnum(options.mode));
    try builder.addAttrU32(socket.IFLA_BOND.MIIMON, options.miimon);

    if (options.updelay > 0) {
        try builder.addAttrU32(socket.IFLA_BOND.UPDELAY, options.updelay);
    }
    if (options.downdelay > 0) {
        try builder.addAttrU32(socket.IFLA_BOND.DOWNDELAY, options.downdelay);
    }

    if (options.lacp_rate) |rate| {
        try builder.addAttrU8(socket.IFLA_BOND.AD_LACP_RATE, @intFromEnum(rate));
    }

    if (options.xmit_hash_policy) |policy| {
        try builder.addAttrU8(socket.IFLA_BOND.XMIT_HASH_POLICY, @intFromEnum(policy));
    }

    if (options.ad_select) |sel| {
        try builder.addAttrU8(socket.IFLA_BOND.AD_SELECT, @intFromEnum(sel));
    }

    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);
}

/// Validate bond creation pre-checks
pub fn validateBondCreation(allocator: std.mem.Allocator, member_names: []const []const u8) !void {
    const interfaces = try interface.getInterfaces(allocator);
    defer allocator.free(interfaces);

    for (member_names) |member_name| {
        var found = false;
        for (interfaces) |iface| {
            if (std.mem.eql(u8, iface.getName(), member_name)) {
                found = true;
                // Check if already enslaved to a master
                if (iface.master_index != null) {
                    return error.InterfaceAlreadyEnslaved;
                }
                break;
            }
        }
        if (!found) {
            return error.InterfaceNotFound;
        }
    }
}

/// Find the next available bond name (bond0..bond99)
pub fn nextBondName(allocator: std.mem.Allocator) !struct { name: [16]u8, len: usize } {
    const interfaces = try interface.getInterfaces(allocator);
    defer allocator.free(interfaces);

    var i: u8 = 0;
    while (i < 100) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name_slice = std.fmt.bufPrint(&name_buf, "bond{d}", .{i}) catch continue;
        const name_len = name_slice.len;

        var exists = false;
        for (interfaces) |iface| {
            if (std.mem.eql(u8, iface.getName(), name_buf[0..name_len])) {
                exists = true;
                break;
            }
        }

        if (!exists) {
            var result: struct { name: [16]u8, len: usize } = .{
                .name = undefined,
                .len = name_len,
            };
            @memset(&result.name, 0);
            @memcpy(result.name[0..name_len], name_buf[0..name_len]);
            return result;
        }
    }

    return error.NoBondNameAvailable;
}

/// Create a bond interface with options
pub fn createBondWithOptions(name: []const u8, options: BondOptions) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.EXCL);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});

    try builder.addAttrString(socket.IFLA.IFNAME, name);
    try buildBondInfoData(&builder, options);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Create a bond interface (simple version)
pub fn createBond(name: []const u8, mode: BondMode) !void {
    return createBondWithOptions(name, .{ .mode = mode });
}

/// Modify an existing bond interface's options
pub fn modifyBond(name: []const u8, options: BondOptions) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const maybe_iface = try interface.getInterfaceByName(allocator, name);
    const iface = maybe_iface orelse return error.InterfaceNotFound;

    // Verify it's actually a bond
    if (iface.getLinkKind()) |kind| {
        if (!std.mem.eql(u8, kind, "bond")) {
            return error.NotABond;
        }
    } else {
        return error.NotABond;
    }

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    // RTM_NEWLINK without CREATE/EXCL flags modifies existing interface
    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = iface.index,
    });

    try buildBondInfoData(&builder, options);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a bond interface
pub fn deleteBond(name: []const u8) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

/// Add a member interface to a bond with validation
pub fn addBondMember(bond_name: []const u8, member_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get bond interface
    const maybe_bond = try interface.getInterfaceByName(allocator, bond_name);
    if (maybe_bond == null) {
        return error.InterfaceNotFound;
    }
    const bond_iface = maybe_bond.?;

    // Verify it's a bond
    if (bond_iface.getLinkKind()) |kind| {
        if (!std.mem.eql(u8, kind, "bond")) {
            return error.NotABond;
        }
    } else {
        return error.NotABond;
    }

    // Get member interface
    const maybe_member = try interface.getInterfaceByName(allocator, member_name);
    if (maybe_member == null) {
        return error.InterfaceNotFound;
    }
    const member = maybe_member.?;

    // Check member is not already enslaved
    if (member.master_index != null) {
        return error.InterfaceAlreadyEnslaved;
    }

    // Bring the member interface down first
    try interface.setInterfaceState(member_name, false);

    // Set IFLA_MASTER to add to bond
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = member.index,
    });

    try builder.addAttrU32(socket.IFLA.MASTER, @intCast(bond_iface.index));

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);

    // Bring the member interface back up
    try interface.setInterfaceState(member_name, true);
}

/// Remove a member interface from a bond
pub fn removeBondMember(member_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const maybe_member = try interface.getInterfaceByName(allocator, member_name);
    if (maybe_member == null) {
        return error.InterfaceNotFound;
    }
    const member = maybe_member.?;

    // Bring the member interface down first
    try interface.setInterfaceState(member_name, false);

    // Set IFLA_MASTER to 0 to remove from bond
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = member.index,
    });

    try builder.addAttrU32(socket.IFLA.MASTER, 0);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Get list of bond interfaces by filtering on link_kind == "bond"
/// and collecting bond-specific attributes from IFLA_INFO_DATA
pub fn getBonds(allocator: std.mem.Allocator) ![]Bond {
    const interfaces = try interface.getInterfaces(allocator);
    defer allocator.free(interfaces);

    var bonds = std.ArrayList(Bond).init(allocator);
    errdefer bonds.deinit();

    for (interfaces) |iface| {
        const kind = iface.getLinkKind() orelse continue;
        if (!std.mem.eql(u8, kind, "bond")) continue;

        // Collect members: interfaces whose master_index matches this bond
        var members: [Bond.MAX_BOND_MEMBERS]i32 = undefined;
        var member_count: usize = 0;
        for (interfaces) |other| {
            if (other.master_index) |master_idx| {
                if (master_idx == iface.index and member_count < Bond.MAX_BOND_MEMBERS) {
                    members[member_count] = other.index;
                    member_count += 1;
                }
            }
        }

        // Parse bond-specific attrs from info_data if available
        var mode: BondMode = .balance_rr;
        var miimon: u32 = 0;
        var updelay: u32 = 0;
        var downdelay: u32 = 0;
        var xmit_hash_policy: ?XmitHashPolicy = null;
        var lacp_rate: ?LacpRate = null;
        var ad_select: ?AdSelect = null;

        if (iface.info_data_len > 0) {
            var parser = socket.AttrParser.init(iface.info_data[0..iface.info_data_len]);
            while (parser.next()) |attr| {
                switch (attr.attr_type) {
                    socket.IFLA_BOND.MODE => {
                        if (attr.value.len >= 1) {
                            mode = @enumFromInt(attr.value[0]);
                        }
                    },
                    socket.IFLA_BOND.MIIMON => {
                        if (attr.value.len >= 4) {
                            miimon = std.mem.readInt(u32, attr.value[0..4], .little);
                        }
                    },
                    socket.IFLA_BOND.UPDELAY => {
                        if (attr.value.len >= 4) {
                            updelay = std.mem.readInt(u32, attr.value[0..4], .little);
                        }
                    },
                    socket.IFLA_BOND.DOWNDELAY => {
                        if (attr.value.len >= 4) {
                            downdelay = std.mem.readInt(u32, attr.value[0..4], .little);
                        }
                    },
                    socket.IFLA_BOND.XMIT_HASH_POLICY => {
                        if (attr.value.len >= 1) {
                            xmit_hash_policy = @enumFromInt(attr.value[0]);
                        }
                    },
                    socket.IFLA_BOND.AD_LACP_RATE => {
                        if (attr.value.len >= 1) {
                            lacp_rate = @enumFromInt(attr.value[0]);
                        }
                    },
                    socket.IFLA_BOND.AD_SELECT => {
                        if (attr.value.len >= 1) {
                            ad_select = @enumFromInt(attr.value[0]);
                        }
                    },
                    else => {},
                }
            }
        }

        var bond = Bond{
            .name = undefined,
            .name_len = iface.name_len,
            .index = iface.index,
            .mode = mode,
            .miimon = miimon,
            .updelay = updelay,
            .downdelay = downdelay,
            .members = members,
            .member_count = member_count,
            .flags = iface.flags,
            .xmit_hash_policy = xmit_hash_policy,
            .lacp_rate = lacp_rate,
            .ad_select = ad_select,
        };
        @memset(&bond.name, 0);
        @memcpy(bond.name[0..iface.name_len], iface.name[0..iface.name_len]);

        try bonds.append(bond);
    }

    return bonds.toOwnedSlice();
}

/// Get bond by name
pub fn getBondByName(allocator: std.mem.Allocator, name: []const u8) !?Bond {
    const bonds = try getBonds(allocator);
    defer allocator.free(bonds);

    for (bonds) |bond| {
        if (std.mem.eql(u8, bond.getName(), name)) {
            return bond;
        }
    }

    return null;
}

// Tests

test "bond mode from string" {
    try std.testing.expectEqual(BondMode.balance_rr, BondMode.fromString("balance-rr").?);
    try std.testing.expectEqual(BondMode.active_backup, BondMode.fromString("active-backup").?);
    try std.testing.expectEqual(BondMode.@"802.3ad", BondMode.fromString("802.3ad").?);
    try std.testing.expectEqual(BondMode.balance_rr, BondMode.fromString("0").?);
    try std.testing.expect(BondMode.fromString("invalid") == null);
}

test "bond mode to string" {
    try std.testing.expectEqualStrings("balance-rr", BondMode.balance_rr.toString());
    try std.testing.expectEqualStrings("802.3ad", BondMode.@"802.3ad".toString());
}

test "lacp rate from string" {
    try std.testing.expectEqual(LacpRate.slow, LacpRate.fromString("slow").?);
    try std.testing.expectEqual(LacpRate.fast, LacpRate.fromString("fast").?);
    try std.testing.expectEqual(LacpRate.slow, LacpRate.fromString("0").?);
    try std.testing.expectEqual(LacpRate.fast, LacpRate.fromString("1").?);
    try std.testing.expect(LacpRate.fromString("invalid") == null);
}

test "xmit hash policy from string" {
    try std.testing.expectEqual(XmitHashPolicy.layer2, XmitHashPolicy.fromString("layer2").?);
    try std.testing.expectEqual(XmitHashPolicy.layer3_4, XmitHashPolicy.fromString("layer3+4").?);
    try std.testing.expectEqual(XmitHashPolicy.vlan_srcmac, XmitHashPolicy.fromString("vlan+srcmac").?);
    try std.testing.expect(XmitHashPolicy.fromString("invalid") == null);
}

test "ad select from string" {
    try std.testing.expectEqual(AdSelect.stable, AdSelect.fromString("stable").?);
    try std.testing.expectEqual(AdSelect.bandwidth, AdSelect.fromString("bandwidth").?);
    try std.testing.expectEqual(AdSelect.count, AdSelect.fromString("count").?);
    try std.testing.expect(AdSelect.fromString("invalid") == null);
}

test "bond options default values" {
    const opts = BondOptions{};
    try std.testing.expectEqual(BondMode.balance_rr, opts.mode);
    try std.testing.expectEqual(@as(u32, 100), opts.miimon);
    try std.testing.expectEqual(@as(u32, 0), opts.updelay);
    try std.testing.expectEqual(@as(u32, 0), opts.downdelay);
    try std.testing.expect(opts.lacp_rate == null);
    try std.testing.expect(opts.xmit_hash_policy == null);
    try std.testing.expect(opts.ad_select == null);
}

test "bond struct getName" {
    var bond = Bond{
        .name = undefined,
        .name_len = 5,
        .index = 1,
        .mode = .active_backup,
        .miimon = 100,
        .updelay = 0,
        .downdelay = 0,
        .members = undefined,
        .member_count = 0,
        .flags = 0,
        .xmit_hash_policy = null,
        .lacp_rate = null,
        .ad_select = null,
    };
    @memset(&bond.name, 0);
    @memcpy(bond.name[0..5], "bond0");
    try std.testing.expectEqualStrings("bond0", bond.getName());
}

test "bond struct isUp" {
    var bond = Bond{
        .name = undefined,
        .name_len = 5,
        .index = 1,
        .mode = .balance_rr,
        .miimon = 100,
        .updelay = 0,
        .downdelay = 0,
        .members = undefined,
        .member_count = 0,
        .flags = socket.IFF.UP | socket.IFF.RUNNING,
        .xmit_hash_policy = null,
        .lacp_rate = null,
        .ad_select = null,
    };
    @memset(&bond.name, 0);
    try std.testing.expect(bond.isUp());

    bond.flags = 0;
    try std.testing.expect(!bond.isUp());
}

test "bond mode roundtrip" {
    // Every mode should survive toString -> fromString roundtrip
    const modes = [_]BondMode{
        .balance_rr, .active_backup, .balance_xor,
        .broadcast,  .@"802.3ad",    .balance_tlb,
        .balance_alb,
    };
    for (modes) |mode| {
        const str = mode.toString();
        const recovered = BondMode.fromString(str).?;
        try std.testing.expectEqual(mode, recovered);
    }
}
