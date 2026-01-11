const std = @import("std");
const socket = @import("socket.zig");
const interface = @import("interface.zig");

/// VLAN interface information
pub const Vlan = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    parent_index: i32,
    vlan_id: u16,
    flags: u32,

    pub fn getName(self: *const Vlan) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isUp(self: *const Vlan) bool {
        return (self.flags & socket.IFF.UP) != 0;
    }
};

/// Create a VLAN interface
/// Creates interface named <parent>.<vlan_id> (e.g., eth0.100)
pub fn createVlan(parent_name: []const u8, vlan_id: u16) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get parent interface
    const maybe_parent = try interface.getInterfaceByName(allocator, parent_name);
    if (maybe_parent == null) {
        return error.InterfaceNotFound;
    }
    const parent = maybe_parent.?;

    // Build VLAN interface name: <parent>.<vlan_id>
    var name_buf: [32]u8 = undefined;
    const vlan_name = std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ parent_name, vlan_id }) catch {
        return error.NameTooLong;
    };

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    // Build RTM_NEWLINK message
    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.EXCL);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});

    // Add interface name
    try builder.addAttrString(socket.IFLA.IFNAME, vlan_name);

    // Add IFLA_LINK (parent interface index)
    try builder.addAttrU32(socket.IFLA.LINK, @intCast(parent.index));

    // Add IFLA_LINKINFO nested attribute
    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);

    // IFLA_INFO_KIND = "vlan"
    try builder.addAttrString(socket.IFLA_INFO.KIND, "vlan");

    // IFLA_INFO_DATA (vlan-specific attributes)
    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);

    // IFLA_VLAN_ID
    try builder.addAttrU16(socket.IFLA_VLAN.ID, vlan_id);

    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Create a VLAN interface with custom name
pub fn createVlanWithName(parent_name: []const u8, vlan_id: u16, vlan_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get parent interface
    const maybe_parent = try interface.getInterfaceByName(allocator, parent_name);
    if (maybe_parent == null) {
        return error.InterfaceNotFound;
    }
    const parent = maybe_parent.?;

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    // Build RTM_NEWLINK message
    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.EXCL);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});

    // Add interface name
    try builder.addAttrString(socket.IFLA.IFNAME, vlan_name);

    // Add IFLA_LINK (parent interface index)
    try builder.addAttrU32(socket.IFLA.LINK, @intCast(parent.index));

    // Add IFLA_LINKINFO nested attribute
    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);

    // IFLA_INFO_KIND = "vlan"
    try builder.addAttrString(socket.IFLA_INFO.KIND, "vlan");

    // IFLA_INFO_DATA (vlan-specific attributes)
    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);

    // IFLA_VLAN_ID
    try builder.addAttrU16(socket.IFLA_VLAN.ID, vlan_id);

    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a VLAN interface
pub fn deleteVlan(name: []const u8) !void {
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

// Tests

test "vlan name format" {
    // Just verify the module compiles
}
