const std = @import("std");
const socket = @import("socket.zig");
const linux = std.os.linux;

/// Represents an IP address on an interface
pub const Address = struct {
    family: u8, // AF_INET or AF_INET6
    prefixlen: u8,
    scope: u8,
    index: u32,
    address: [16]u8, // Big enough for IPv6
    local: [16]u8,
    label: [16]u8,
    label_len: usize,

    pub fn isIPv4(self: *const Address) bool {
        return self.family == linux.AF.INET;
    }

    pub fn isIPv6(self: *const Address) bool {
        return self.family == linux.AF.INET6;
    }

    pub fn formatAddress(self: *const Address, buf: []u8) ![]u8 {
        if (self.isIPv4()) {
            return std.fmt.bufPrint(buf, "{}.{}.{}.{}/{}", .{
                self.address[0],
                self.address[1],
                self.address[2],
                self.address[3],
                self.prefixlen,
            });
        } else {
            // IPv6 - simplified formatting
            return std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}/{}", .{
                self.address[0],  self.address[1],
                self.address[2],  self.address[3],
                self.address[4],  self.address[5],
                self.address[6],  self.address[7],
                self.address[8],  self.address[9],
                self.address[10], self.address[11],
                self.address[12], self.address[13],
                self.address[14], self.address[15],
                self.prefixlen,
            });
        }
    }

    pub fn scopeString(self: *const Address) []const u8 {
        return switch (self.scope) {
            0 => "global",
            200 => "site",
            253 => "link",
            254 => "host",
            255 => "nowhere",
            else => "unknown",
        };
    }
};

/// Get all addresses
pub fn getAddresses(allocator: std.mem.Allocator) ![]Address {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.GETADDR, socket.NLM_F.REQUEST | socket.NLM_F.DUMP);
    try builder.addData(socket.IfAddrMsg, socket.IfAddrMsg{});

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    defer allocator.free(response);

    var addresses = std.ArrayList(Address).init(allocator);
    errdefer addresses.deinit();

    var offset: usize = 0;
    while (offset + @sizeOf(socket.NlMsgHdr) <= response.len) {
        const nlhdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(response[offset..].ptr));

        if (nlhdr.len < @sizeOf(socket.NlMsgHdr) or offset + nlhdr.len > response.len) {
            break;
        }

        if (nlhdr.type == socket.RTM.NEWADDR) {
            const ifa_offset = offset + @sizeOf(socket.NlMsgHdr);
            if (ifa_offset + @sizeOf(socket.IfAddrMsg) <= response.len) {
                const ifaddr: *const socket.IfAddrMsg = @ptrCast(@alignCast(response[ifa_offset..].ptr));

                var addr = Address{
                    .family = ifaddr.family,
                    .prefixlen = ifaddr.prefixlen,
                    .scope = ifaddr.scope,
                    .index = ifaddr.index,
                    .address = undefined,
                    .local = undefined,
                    .label = undefined,
                    .label_len = 0,
                };
                @memset(&addr.address, 0);
                @memset(&addr.local, 0);
                @memset(&addr.label, 0);

                const attrs_offset = ifa_offset + @sizeOf(socket.IfAddrMsg);
                const attrs_len = nlhdr.len - @sizeOf(socket.NlMsgHdr) - @sizeOf(socket.IfAddrMsg);

                if (attrs_offset + attrs_len <= response.len) {
                    var parser = socket.AttrParser.init(response[attrs_offset .. attrs_offset + attrs_len]);

                    while (parser.next()) |attr| {
                        switch (attr.attr_type) {
                            socket.IFA.ADDRESS => {
                                const copy_len = @min(attr.value.len, addr.address.len);
                                @memcpy(addr.address[0..copy_len], attr.value[0..copy_len]);
                            },
                            socket.IFA.LOCAL => {
                                const copy_len = @min(attr.value.len, addr.local.len);
                                @memcpy(addr.local[0..copy_len], attr.value[0..copy_len]);
                            },
                            socket.IFA.LABEL => {
                                const name_end = std.mem.indexOfScalar(u8, attr.value, 0) orelse attr.value.len;
                                const copy_len = @min(name_end, addr.label.len);
                                @memcpy(addr.label[0..copy_len], attr.value[0..copy_len]);
                                addr.label_len = copy_len;
                            },
                            else => {},
                        }
                    }
                }

                try addresses.append(addr);
            }
        }

        offset += socket.nlAlign(nlhdr.len);
    }

    return addresses.toOwnedSlice();
}

/// Get addresses for a specific interface index
pub fn getAddressesForInterface(allocator: std.mem.Allocator, if_index: u32) ![]Address {
    const all = try getAddresses(allocator);
    defer allocator.free(all);

    var filtered = std.ArrayList(Address).init(allocator);
    errdefer filtered.deinit();

    for (all) |addr| {
        if (addr.index == if_index) {
            try filtered.append(addr);
        }
    }

    return filtered.toOwnedSlice();
}

/// Add an address to an interface
pub fn addAddress(if_index: u32, family: u8, addr_bytes: []const u8, prefixlen: u8) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWADDR, socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.EXCL);
    try builder.addData(socket.IfAddrMsg, socket.IfAddrMsg{
        .family = family,
        .prefixlen = prefixlen,
        .scope = 0, // Global
        .index = if_index,
    });

    try builder.addAttr(socket.IFA.LOCAL, addr_bytes);
    try builder.addAttr(socket.IFA.ADDRESS, addr_bytes);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete an address from an interface
pub fn deleteAddress(if_index: u32, family: u8, addr_bytes: []const u8, prefixlen: u8) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.DELADDR, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfAddrMsg, socket.IfAddrMsg{
        .family = family,
        .prefixlen = prefixlen,
        .index = if_index,
    });

    try builder.addAttr(socket.IFA.LOCAL, addr_bytes);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Parse an IPv4 address string (e.g., "10.0.0.1/24")
pub fn parseIPv4(str: []const u8) !struct { addr: [4]u8, prefix: u8 } {
    var addr: [4]u8 = undefined;
    var prefix: u8 = 32;

    // Split by /
    var parts = std.mem.splitScalar(u8, str, '/');
    const ip_part = parts.first();

    if (parts.next()) |prefix_part| {
        prefix = std.fmt.parseInt(u8, prefix_part, 10) catch return error.InvalidPrefix;
    }

    // Parse IP octets
    var octets = std.mem.splitScalar(u8, ip_part, '.');
    var i: usize = 0;
    while (octets.next()) |octet| {
        if (i >= 4) return error.InvalidAddress;
        addr[i] = std.fmt.parseInt(u8, octet, 10) catch return error.InvalidAddress;
        i += 1;
    }

    if (i != 4) return error.InvalidAddress;

    return .{ .addr = addr, .prefix = prefix };
}
