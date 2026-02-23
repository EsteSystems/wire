const std = @import("std");
const socket = @import("socket.zig");
const interface = @import("interface.zig");

/// Veth pair information
pub const Veth = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    peer_index: i32,
    peer_name: [16]u8,
    peer_name_len: usize,
    flags: u32,

    pub fn getName(self: *const Veth) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getPeerName(self: *const Veth) []const u8 {
        return self.peer_name[0..self.peer_name_len];
    }

    pub fn isUp(self: *const Veth) bool {
        return (self.flags & socket.IFF.UP) != 0;
    }
};

/// Veth info attribute for peer specification (nested in IFLA_INFO_DATA)
pub const VETH_INFO = struct {
    pub const UNSPEC: u16 = 0;
    pub const PEER: u16 = 1;
};

/// Create a veth pair
/// Creates two linked veth interfaces: name <-> peer_name
pub fn createVethPair(name: []const u8, peer_name: []const u8) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [1024]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    // Build RTM_NEWLINK message
    const hdr = try builder.addHeader(
        socket.RTM.NEWLINK,
        socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.EXCL,
    );
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});

    // Add interface name for the first veth
    try builder.addAttrString(socket.IFLA.IFNAME, name);

    // Add IFLA_LINKINFO nested attribute
    const linkinfo_start = try builder.startNestedAttr(socket.IFLA.LINKINFO);

    // IFLA_INFO_KIND = "veth"
    try builder.addAttrString(socket.IFLA_INFO.KIND, "veth");

    // IFLA_INFO_DATA (veth-specific: peer info)
    const data_start = try builder.startNestedAttr(socket.IFLA_INFO.DATA);

    // VETH_INFO_PEER contains a complete ifinfomsg + attributes for the peer
    const peer_start = try builder.startNestedAttr(VETH_INFO.PEER);

    // Add ifinfomsg for peer (required even if empty)
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{});

    // Add peer interface name
    try builder.addAttrString(socket.IFLA.IFNAME, peer_name);

    builder.endNestedAttr(peer_start);
    builder.endNestedAttr(data_start);
    builder.endNestedAttr(linkinfo_start);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a veth pair (deleting one end automatically deletes the other)
pub fn deleteVeth(name: []const u8) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get the interface index
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

/// Move a veth end to a different network namespace
/// ns_fd is a file descriptor to the target namespace (from open("/proc/<pid>/ns/net"))
pub fn setVethNetns(name: []const u8, ns_fd: i32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get the interface index
    const maybe_iface = try interface.getInterfaceByName(allocator, name);
    if (maybe_iface == null) {
        return error.InterfaceNotFound;
    }
    const iface = maybe_iface.?;

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = iface.index,
    });

    // IFLA_NET_NS_FD = 28
    try builder.addAttrU32(28, @intCast(ns_fd));

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Move a veth end to a network namespace by PID
pub fn setVethNetnsbyPid(name: []const u8, pid: i32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get the interface index
    const maybe_iface = try interface.getInterfaceByName(allocator, name);
    if (maybe_iface == null) {
        return error.InterfaceNotFound;
    }
    const iface = maybe_iface.?;

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = iface.index,
    });

    // IFLA_NET_NS_PID = 19
    try builder.addAttrU32(19, @intCast(pid));

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Get veth pair info for an interface (if it is a veth)
pub fn getVethInfo(allocator: std.mem.Allocator, name: []const u8) !?Veth {
    const maybe_iface = try interface.getInterfaceByName(allocator, name);
    if (maybe_iface == null) {
        return null;
    }
    const iface = maybe_iface.?;

    // Check if it's a veth
    if (!iface.isVeth()) {
        return null;
    }

    var veth = Veth{
        .name = undefined,
        .name_len = iface.name_len,
        .index = iface.index,
        .peer_index = iface.link_index orelse 0,
        .peer_name = undefined,
        .peer_name_len = 0,
        .flags = iface.flags,
    };
    @memcpy(veth.name[0..iface.name_len], iface.name[0..iface.name_len]);
    @memset(&veth.peer_name, 0);

    // Get peer name if peer exists
    if (iface.link_index) |peer_idx| {
        const interfaces = try interface.getInterfaces(allocator);
        defer allocator.free(interfaces);

        for (interfaces) |peer| {
            if (peer.index == peer_idx) {
                const peer_name = peer.getName();
                @memcpy(veth.peer_name[0..peer_name.len], peer_name);
                veth.peer_name_len = peer_name.len;
                break;
            }
        }
    }

    return veth;
}

// Tests

test "VETH_INFO constants" {
    try std.testing.expectEqual(@as(u16, 0), VETH_INFO.UNSPEC);
    try std.testing.expectEqual(@as(u16, 1), VETH_INFO.PEER);
}

test "Veth getName" {
    var veth = Veth{
        .name = undefined,
        .name_len = 5,
        .index = 1,
        .peer_index = 2,
        .peer_name = undefined,
        .peer_name_len = 5,
        .flags = 0,
    };
    @memset(&veth.name, 0);
    @memcpy(veth.name[0..5], "veth0");
    @memset(&veth.peer_name, 0);
    @memcpy(veth.peer_name[0..5], "veth1");
    try std.testing.expectEqualStrings("veth0", veth.getName());
}

test "Veth getPeerName" {
    var veth = Veth{
        .name = undefined,
        .name_len = 5,
        .index = 1,
        .peer_index = 2,
        .peer_name = undefined,
        .peer_name_len = 5,
        .flags = 0,
    };
    @memset(&veth.name, 0);
    @memcpy(veth.name[0..5], "veth0");
    @memset(&veth.peer_name, 0);
    @memcpy(veth.peer_name[0..5], "veth1");
    try std.testing.expectEqualStrings("veth1", veth.getPeerName());
}

test "Veth isUp flag" {
    var veth = Veth{
        .name = undefined,
        .name_len = 5,
        .index = 1,
        .peer_index = 2,
        .peer_name = undefined,
        .peer_name_len = 0,
        .flags = socket.IFF.UP | socket.IFF.BROADCAST,
    };
    @memset(&veth.name, 0);
    @memset(&veth.peer_name, 0);
    try std.testing.expect(veth.isUp());

    veth.flags = 0;
    try std.testing.expect(!veth.isUp());
}

test "Veth default peer fields" {
    var veth = Veth{
        .name = undefined,
        .name_len = 4,
        .index = 10,
        .peer_index = 0,
        .peer_name = undefined,
        .peer_name_len = 0,
        .flags = 0,
    };
    @memset(&veth.name, 0);
    @memcpy(veth.name[0..4], "eth0");
    @memset(&veth.peer_name, 0);

    // When no peer is known, peer_index is 0 and peer_name_len is 0
    try std.testing.expectEqual(@as(i32, 0), veth.peer_index);
    try std.testing.expectEqual(@as(usize, 0), veth.peer_name_len);
    try std.testing.expectEqualStrings("", veth.getPeerName());
}

test "Veth name and peer name independence" {
    var veth = Veth{
        .name = undefined,
        .name_len = 6,
        .index = 3,
        .peer_index = 4,
        .peer_name = undefined,
        .peer_name_len = 7,
        .flags = socket.IFF.UP,
    };
    @memset(&veth.name, 0);
    @memcpy(veth.name[0..6], "mynet0");
    @memset(&veth.peer_name, 0);
    @memcpy(veth.peer_name[0..7], "mynet0p");

    try std.testing.expectEqualStrings("mynet0", veth.getName());
    try std.testing.expectEqualStrings("mynet0p", veth.getPeerName());
    try std.testing.expect(veth.isUp());
}
