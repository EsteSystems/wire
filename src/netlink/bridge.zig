const std = @import("std");
const socket = @import("socket.zig");
const interface = @import("interface.zig");

/// Bridge information
pub const Bridge = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    flags: u32,
    stp_state: bool,
    forward_delay: u32,
    members: []i32,

    pub fn getName(self: *const Bridge) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isUp(self: *const Bridge) bool {
        return (self.flags & socket.IFF.UP) != 0;
    }
};

/// Create a bridge interface
pub fn createBridge(name: []const u8) !void {
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

    // IFLA_INFO_KIND = "bridge"
    try builder.addAttrString(socket.IFLA_INFO.KIND, "bridge");

    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a bridge interface
pub fn deleteBridge(name: []const u8) !void {
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

/// Add a member interface to a bridge
pub fn addBridgeMember(bridge_name: []const u8, member_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get bridge interface
    const maybe_bridge = try interface.getInterfaceByName(allocator, bridge_name);
    if (maybe_bridge == null) {
        return error.InterfaceNotFound;
    }
    const bridge = maybe_bridge.?;

    // Get member interface
    const maybe_member = try interface.getInterfaceByName(allocator, member_name);
    if (maybe_member == null) {
        return error.InterfaceNotFound;
    }
    const member = maybe_member.?;

    // Set IFLA_MASTER to add to bridge
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = member.index,
    });

    // Set master to bridge index
    try builder.addAttrU32(socket.IFLA.MASTER, @intCast(bridge.index));

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Remove a member interface from a bridge
pub fn removeBridgeMember(member_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get member interface
    const maybe_member = try interface.getInterfaceByName(allocator, member_name);
    if (maybe_member == null) {
        return error.InterfaceNotFound;
    }
    const member = maybe_member.?;

    // Set IFLA_MASTER to 0 to remove from bridge
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

/// Set bridge STP state
pub fn setBridgeStp(name: []const u8, enabled: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get bridge interface
    const maybe_bridge = try interface.getInterfaceByName(allocator, name);
    if (maybe_bridge == null) {
        return error.InterfaceNotFound;
    }
    const bridge = maybe_bridge.?;

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [512]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    // Use RTM_NEWLINK for modification (not SETLINK)
    const hdr = try builder.addHeader(socket.RTM.NEWLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = bridge.index,
    });

    // Add IFLA_LINKINFO nested attribute
    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);

    // IFLA_INFO_KIND = "bridge"
    try builder.addAttrString(socket.IFLA_INFO.KIND, "bridge");

    // IFLA_INFO_DATA (bridge-specific attributes)
    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);

    // IFLA_BR_STP_STATE
    try builder.addAttrU32(socket.IFLA_BR.STP_STATE, if (enabled) 1 else 0);

    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

// Tests

test "bridge create and delete" {
    // This test would require root privileges
    // Just verify the module compiles
}
