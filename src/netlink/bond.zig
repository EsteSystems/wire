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

/// Bond information
pub const Bond = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    mode: BondMode,
    miimon: u32,
    updelay: u32,
    downdelay: u32,
    members: []i32,
    flags: u32,

    pub fn getName(self: *const Bond) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isUp(self: *const Bond) bool {
        return (self.flags & socket.IFF.UP) != 0;
    }
};

/// Create a bond interface
pub fn createBond(name: []const u8, mode: BondMode) !void {
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

    // IFLA_INFO_KIND = "bond"
    try builder.addAttrString(socket.IFLA_INFO.KIND, "bond");

    // IFLA_INFO_DATA (bond-specific attributes)
    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);

    // Bond mode
    try builder.addAttrU8(socket.IFLA_BOND.MODE, @intFromEnum(mode));

    // Default MII monitoring interval (100ms)
    try builder.addAttrU32(socket.IFLA_BOND.MIIMON, 100);

    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);

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

/// Add a member interface to a bond
pub fn addBondMember(bond_name: []const u8, member_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get bond interface
    const maybe_bond = try interface.getInterfaceByName(allocator, bond_name);
    if (maybe_bond == null) {
        return error.InterfaceNotFound;
    }
    const bond = maybe_bond.?;

    // Get member interface
    const maybe_member = try interface.getInterfaceByName(allocator, member_name);
    if (maybe_member == null) {
        return error.InterfaceNotFound;
    }
    const member = maybe_member.?;

    // First bring the member interface down
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

    // Set master to bond index
    try builder.addAttrU32(socket.IFLA.MASTER, @intCast(bond.index));

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

    // Get member interface
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

    // Set master to 0 to detach
    try builder.addAttrU32(socket.IFLA.MASTER, 0);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Get list of bond interfaces
pub fn getBonds(allocator: std.mem.Allocator) ![]Bond {
    // Get all interfaces and filter for bonds
    const interfaces = try interface.getInterfaces(allocator);
    defer allocator.free(interfaces);

    var bonds = std.ArrayList(Bond).init(allocator);
    errdefer bonds.deinit();

    // For now, we identify bonds by checking if the interface type is bond
    // This requires parsing IFLA_LINKINFO which we'll need to add to getInterfaces
    // For simplicity, return empty list - we'll need to enhance interface parsing

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
