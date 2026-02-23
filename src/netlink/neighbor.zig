const std = @import("std");
const socket = @import("socket.zig");
const linux = std.os.linux;

/// Neighbor discovery message (for RTM_*NEIGH)
pub const NdMsg = extern struct {
    family: u8 = linux.AF.INET,
    pad1: u8 = 0,
    pad2: u16 = 0,
    ifindex: i32 = 0,
    state: u16 = 0,
    flags: u8 = 0,
    type: u8 = 0,
};

/// Neighbor attributes (NDA_*)
pub const NDA = struct {
    pub const UNSPEC: u16 = 0;
    pub const DST: u16 = 1; // Network address
    pub const LLADDR: u16 = 2; // Link layer address (MAC)
    pub const CACHEINFO: u16 = 3;
    pub const PROBES: u16 = 4;
    pub const VLAN: u16 = 5;
    pub const PORT: u16 = 6;
    pub const VNI: u16 = 7;
    pub const IFINDEX: u16 = 8;
    pub const MASTER: u16 = 9;
    pub const LINK_NETNSID: u16 = 10;
    pub const SRC_VNI: u16 = 11;
    pub const PROTOCOL: u16 = 12;
};

/// Neighbor states (NUD_*)
pub const NUD = struct {
    pub const INCOMPLETE: u16 = 0x01;
    pub const REACHABLE: u16 = 0x02;
    pub const STALE: u16 = 0x04;
    pub const DELAY: u16 = 0x08;
    pub const PROBE: u16 = 0x10;
    pub const FAILED: u16 = 0x20;
    pub const NOARP: u16 = 0x40;
    pub const PERMANENT: u16 = 0x80;
    pub const NONE: u16 = 0x00;
};

/// Neighbor state enum for easier use
pub const NeighState = enum {
    incomplete,
    reachable,
    stale,
    delay,
    probe,
    failed,
    noarp,
    permanent,
    none,
    unknown,

    pub fn fromNud(nud: u16) NeighState {
        if (nud & NUD.PERMANENT != 0) return .permanent;
        if (nud & NUD.NOARP != 0) return .noarp;
        if (nud & NUD.REACHABLE != 0) return .reachable;
        if (nud & NUD.STALE != 0) return .stale;
        if (nud & NUD.DELAY != 0) return .delay;
        if (nud & NUD.PROBE != 0) return .probe;
        if (nud & NUD.INCOMPLETE != 0) return .incomplete;
        if (nud & NUD.FAILED != 0) return .failed;
        if (nud == NUD.NONE) return .none;
        return .unknown;
    }

    pub fn toString(self: NeighState) []const u8 {
        return switch (self) {
            .incomplete => "INCOMPLETE",
            .reachable => "REACHABLE",
            .stale => "STALE",
            .delay => "DELAY",
            .probe => "PROBE",
            .failed => "FAILED",
            .noarp => "NOARP",
            .permanent => "PERMANENT",
            .none => "NONE",
            .unknown => "UNKNOWN",
        };
    }
};

/// A neighbor table entry (ARP/NDP)
pub const NeighborEntry = struct {
    family: u8, // AF_INET or AF_INET6
    interface_index: i32,
    state: NeighState,
    state_raw: u16,
    flags: u8,
    // IP address (4 bytes for IPv4, 16 for IPv6)
    address: [16]u8,
    address_len: usize,
    // MAC address (6 bytes)
    lladdr: [6]u8,
    has_lladdr: bool,

    const Self = @This();

    /// Format IP address as string
    pub fn formatAddress(self: *const Self, buf: []u8) ![]const u8 {
        if (self.family == linux.AF.INET) {
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                self.address[0],
                self.address[1],
                self.address[2],
                self.address[3],
            });
        } else if (self.family == linux.AF.INET6) {
            // Simplified IPv6 formatting
            return std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
                self.address[0],  self.address[1],  self.address[2],  self.address[3],
                self.address[4],  self.address[5],  self.address[6],  self.address[7],
                self.address[8],  self.address[9],  self.address[10], self.address[11],
                self.address[12], self.address[13], self.address[14], self.address[15],
            });
        }
        return "?";
    }

    /// Format MAC address as string
    pub fn formatLladdr(self: *const Self) [17]u8 {
        var buf: [17]u8 = undefined;
        if (self.has_lladdr) {
            _ = std.fmt.bufPrint(&buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
                self.lladdr[0], self.lladdr[1], self.lladdr[2],
                self.lladdr[3], self.lladdr[4], self.lladdr[5],
            }) catch unreachable;
        } else {
            @memcpy(&buf, "(incomplete)     ");
        }
        return buf;
    }

    /// Check if this is an IPv4 entry
    pub fn isIPv4(self: *const Self) bool {
        return self.family == linux.AF.INET;
    }

    /// Check if this is an IPv6 entry
    pub fn isIPv6(self: *const Self) bool {
        return self.family == linux.AF.INET6;
    }
};

/// Get all neighbor entries (ARP and NDP tables)
pub fn getNeighbors(allocator: std.mem.Allocator) ![]NeighborEntry {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    // Build RTM_GETNEIGH request
    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.GETNEIGH, socket.NLM_F.REQUEST | socket.NLM_F.DUMP);
    try builder.addData(NdMsg, NdMsg{
        .family = linux.AF.UNSPEC, // Get both IPv4 and IPv6
    });

    const msg = builder.finalize(hdr);

    // Send request and get responses
    const response = try nl.request(msg, allocator);
    defer allocator.free(response);

    // Parse responses
    var neighbors = std.array_list.Managed(NeighborEntry).init(allocator);
    errdefer neighbors.deinit();

    var offset: usize = 0;
    while (offset + @sizeOf(socket.NlMsgHdr) <= response.len) {
        const nlhdr: *const socket.NlMsgHdr = @ptrCast(@alignCast(response[offset..].ptr));

        if (nlhdr.len < @sizeOf(socket.NlMsgHdr) or offset + nlhdr.len > response.len) {
            break;
        }

        if (nlhdr.type == socket.RTM.NEWNEIGH) {
            const ndmsg_offset = offset + @sizeOf(socket.NlMsgHdr);
            if (ndmsg_offset + @sizeOf(NdMsg) <= response.len) {
                const ndmsg: *const NdMsg = @ptrCast(@alignCast(response[ndmsg_offset..].ptr));

                var entry = NeighborEntry{
                    .family = ndmsg.family,
                    .interface_index = ndmsg.ifindex,
                    .state = NeighState.fromNud(ndmsg.state),
                    .state_raw = ndmsg.state,
                    .flags = ndmsg.flags,
                    .address = undefined,
                    .address_len = 0,
                    .lladdr = undefined,
                    .has_lladdr = false,
                };
                @memset(&entry.address, 0);
                @memset(&entry.lladdr, 0);

                // Parse attributes
                const attrs_offset = ndmsg_offset + @sizeOf(NdMsg);
                const attrs_len = nlhdr.len - @sizeOf(socket.NlMsgHdr) - @sizeOf(NdMsg);

                if (attrs_offset + attrs_len <= response.len) {
                    var parser = socket.AttrParser.init(response[attrs_offset .. attrs_offset + attrs_len]);

                    while (parser.next()) |attr| {
                        switch (attr.attr_type) {
                            NDA.DST => {
                                const copy_len = @min(attr.value.len, entry.address.len);
                                @memcpy(entry.address[0..copy_len], attr.value[0..copy_len]);
                                entry.address_len = copy_len;
                            },
                            NDA.LLADDR => {
                                if (attr.value.len >= 6) {
                                    @memcpy(&entry.lladdr, attr.value[0..6]);
                                    entry.has_lladdr = true;
                                }
                            },
                            else => {},
                        }
                    }
                }

                // Only add entries that have an address
                if (entry.address_len > 0) {
                    try neighbors.append(entry);
                }
            }
        }

        offset += socket.nlAlign(nlhdr.len);
    }

    return neighbors.toOwnedSlice();
}

/// Get IPv4 neighbors only (ARP table)
pub fn getArpTable(allocator: std.mem.Allocator) ![]NeighborEntry {
    const all = try getNeighbors(allocator);
    defer allocator.free(all);

    var arp_entries = std.array_list.Managed(NeighborEntry).init(allocator);
    errdefer arp_entries.deinit();

    for (all) |entry| {
        if (entry.isIPv4()) {
            try arp_entries.append(entry);
        }
    }

    return arp_entries.toOwnedSlice();
}

/// Get IPv6 neighbors only (NDP table)
pub fn getNdpTable(allocator: std.mem.Allocator) ![]NeighborEntry {
    const all = try getNeighbors(allocator);
    defer allocator.free(all);

    var ndp_entries = std.array_list.Managed(NeighborEntry).init(allocator);
    errdefer ndp_entries.deinit();

    for (all) |entry| {
        if (entry.isIPv6()) {
            try ndp_entries.append(entry);
        }
    }

    return ndp_entries.toOwnedSlice();
}

/// Find neighbor entry by IP address
pub fn getNeighborByIP(allocator: std.mem.Allocator, ip: []const u8) !?NeighborEntry {
    // Parse the IP address
    var target_addr: [16]u8 = undefined;
    var target_len: usize = 0;
    var family: u8 = linux.AF.INET;

    // Try to parse as IPv4
    if (parseIPv4(ip)) |addr| {
        @memcpy(target_addr[0..4], &addr);
        target_len = 4;
        family = linux.AF.INET;
    } else if (parseIPv6(ip)) |addr| {
        @memcpy(&target_addr, &addr);
        target_len = 16;
        family = linux.AF.INET6;
    } else {
        return null;
    }

    const neighbors = try getNeighbors(allocator);
    defer allocator.free(neighbors);

    for (neighbors) |entry| {
        if (entry.family == family and entry.address_len == target_len) {
            if (std.mem.eql(u8, entry.address[0..target_len], target_addr[0..target_len])) {
                return entry;
            }
        }
    }

    return null;
}

/// Find neighbors for a specific interface
pub fn getNeighborsForInterface(allocator: std.mem.Allocator, if_index: i32) ![]NeighborEntry {
    const all = try getNeighbors(allocator);
    defer allocator.free(all);

    var filtered = std.array_list.Managed(NeighborEntry).init(allocator);
    errdefer filtered.deinit();

    for (all) |entry| {
        if (entry.interface_index == if_index) {
            try filtered.append(entry);
        }
    }

    return filtered.toOwnedSlice();
}

/// Parse IPv4 address string to bytes
fn parseIPv4(ip: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var current_value: u16 = 0;
    var has_digit = false;

    for (ip) |c| {
        if (c >= '0' and c <= '9') {
            current_value = current_value * 10 + (c - '0');
            if (current_value > 255) return null;
            has_digit = true;
        } else if (c == '.') {
            if (!has_digit or octet_idx >= 3) return null;
            result[octet_idx] = @intCast(current_value);
            octet_idx += 1;
            current_value = 0;
            has_digit = false;
        } else {
            return null;
        }
    }

    if (!has_digit or octet_idx != 3) return null;
    result[3] = @intCast(current_value);

    return result;
}

/// Parse IPv6 address string to bytes (simplified - basic format only)
fn parseIPv6(ip: []const u8) ?[16]u8 {
    // Very basic IPv6 parsing - handles full form only for now
    _ = ip;
    // TODO: Implement full IPv6 parsing
    return null;
}

/// Add a static neighbor entry (ARP/NDP)
pub fn addNeighbor(if_index: i32, ip: []const u8, mac: [6]u8, permanent: bool) !void {
    // Parse the IP address
    var addr: [16]u8 = undefined;
    var addr_len: usize = 0;
    var family: u8 = linux.AF.INET;

    if (parseIPv4(ip)) |ipv4| {
        @memcpy(addr[0..4], &ipv4);
        addr_len = 4;
        family = linux.AF.INET;
    } else if (parseIPv6(ip)) |ipv6| {
        @memcpy(&addr, &ipv6);
        addr_len = 16;
        family = linux.AF.INET6;
    } else {
        return error.InvalidAddress;
    }

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.NEWNEIGH, socket.NLM_F.REQUEST | socket.NLM_F.ACK | socket.NLM_F.CREATE | socket.NLM_F.REPLACE);

    // Set state: PERMANENT for static entries, REACHABLE for temporary
    const state: u16 = if (permanent) NUD.PERMANENT else NUD.REACHABLE;

    try builder.addData(NdMsg, NdMsg{
        .family = family,
        .ifindex = if_index,
        .state = state,
        .flags = 0,
        .type = 0,
    });

    // Add destination IP address
    try builder.addAttr(NDA.DST, addr[0..addr_len]);

    // Add link-layer address (MAC)
    try builder.addAttr(NDA.LLADDR, &mac);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Delete a neighbor entry
pub fn deleteNeighbor(if_index: i32, ip: []const u8) !void {
    // Parse the IP address
    var addr: [16]u8 = undefined;
    var addr_len: usize = 0;
    var family: u8 = linux.AF.INET;

    if (parseIPv4(ip)) |ipv4| {
        @memcpy(addr[0..4], &ipv4);
        addr_len = 4;
        family = linux.AF.INET;
    } else if (parseIPv6(ip)) |ipv6| {
        @memcpy(&addr, &ipv6);
        addr_len = 16;
        family = linux.AF.INET6;
    } else {
        return error.InvalidAddress;
    }

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.DELNEIGH, socket.NLM_F.REQUEST | socket.NLM_F.ACK);

    try builder.addData(NdMsg, NdMsg{
        .family = family,
        .ifindex = if_index,
        .state = 0,
        .flags = 0,
        .type = 0,
    });

    // Add destination IP address
    try builder.addAttr(NDA.DST, addr[0..addr_len]);

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Parse MAC address string (aa:bb:cc:dd:ee:ff or aa-bb-cc-dd-ee-ff)
pub fn parseMac(mac_str: []const u8) ?[6]u8 {
    var result: [6]u8 = undefined;
    var byte_idx: usize = 0;
    var current_byte: u8 = 0;
    var nibble_count: usize = 0;

    for (mac_str) |c| {
        if (c == ':' or c == '-') {
            if (nibble_count != 2) return null;
            if (byte_idx >= 5) return null;
            result[byte_idx] = current_byte;
            byte_idx += 1;
            current_byte = 0;
            nibble_count = 0;
        } else {
            const nibble: u8 = if (c >= '0' and c <= '9')
                c - '0'
            else if (c >= 'a' and c <= 'f')
                c - 'a' + 10
            else if (c >= 'A' and c <= 'F')
                c - 'A' + 10
            else
                return null;

            if (nibble_count >= 2) return null;
            current_byte = (current_byte << 4) | nibble;
            nibble_count += 1;
        }
    }

    if (nibble_count != 2 or byte_idx != 5) return null;
    result[5] = current_byte;

    return result;
}

/// Display neighbor table
pub fn displayNeighbors(neighbors: []const NeighborEntry, writer: anytype, interface_resolver: anytype) !void {
    if (neighbors.len == 0) {
        try writer.print("No neighbor entries found.\n", .{});
        return;
    }

    try writer.print("Neighbor Table ({d} entries)\n", .{neighbors.len});
    try writer.print("{s:<20} {s:<20} {s:<12} {s:<12}\n", .{ "IP Address", "MAC Address", "State", "Interface" });
    try writer.print("{s:-<20} {s:-<20} {s:-<12} {s:-<12}\n", .{ "", "", "", "" });

    for (neighbors) |*entry| {
        var ip_buf: [64]u8 = undefined;
        const ip_str = entry.formatAddress(&ip_buf) catch "?";
        const mac_str = entry.formatLladdr();

        // Try to resolve interface name
        var if_name: [16]u8 = undefined;
        var if_name_len: usize = 0;
        if (@TypeOf(interface_resolver) != @TypeOf(null)) {
            if (interface_resolver.resolve(entry.interface_index)) |name| {
                const copy_len = @min(name.len, if_name.len);
                @memcpy(if_name[0..copy_len], name[0..copy_len]);
                if_name_len = copy_len;
            }
        }
        const if_display = if (if_name_len > 0) if_name[0..if_name_len] else "?";

        try writer.print("{s:<20} {s:<20} {s:<12} {s:<12}\n", .{
            ip_str,
            mac_str,
            entry.state.toString(),
            if_display,
        });
    }
}

// Tests

test "NdMsg size" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(NdMsg));
}

test "NeighState fromNud" {
    try std.testing.expectEqual(NeighState.reachable, NeighState.fromNud(NUD.REACHABLE));
    try std.testing.expectEqual(NeighState.stale, NeighState.fromNud(NUD.STALE));
    try std.testing.expectEqual(NeighState.permanent, NeighState.fromNud(NUD.PERMANENT));
    try std.testing.expectEqual(NeighState.failed, NeighState.fromNud(NUD.FAILED));
}

test "parseIPv4" {
    const result = parseIPv4("192.168.1.1");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 192), result.?[0]);
    try std.testing.expectEqual(@as(u8, 168), result.?[1]);
    try std.testing.expectEqual(@as(u8, 1), result.?[2]);
    try std.testing.expectEqual(@as(u8, 1), result.?[3]);
}

test "parseIPv4 invalid" {
    try std.testing.expect(parseIPv4("256.1.1.1") == null);
    try std.testing.expect(parseIPv4("1.1.1") == null);
    try std.testing.expect(parseIPv4("abc") == null);
}

test "parseMac" {
    const result = parseMac("aa:bb:cc:dd:ee:ff");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 0xaa), result.?[0]);
    try std.testing.expectEqual(@as(u8, 0xbb), result.?[1]);
    try std.testing.expectEqual(@as(u8, 0xff), result.?[5]);
}

test "parseMac with dashes" {
    const result = parseMac("AA-BB-CC-DD-EE-FF");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 0xaa), result.?[0]);
}

test "parseMac invalid" {
    try std.testing.expect(parseMac("aa:bb:cc") == null);
    try std.testing.expect(parseMac("gg:bb:cc:dd:ee:ff") == null);
}

test "NeighborEntry formatAddress" {
    var entry = NeighborEntry{
        .family = linux.AF.INET,
        .interface_index = 1,
        .state = .reachable,
        .state_raw = NUD.REACHABLE,
        .flags = 0,
        .address = undefined,
        .address_len = 4,
        .lladdr = undefined,
        .has_lladdr = false,
    };
    entry.address[0] = 10;
    entry.address[1] = 0;
    entry.address[2] = 0;
    entry.address[3] = 1;

    var buf: [64]u8 = undefined;
    const str = try entry.formatAddress(&buf);
    try std.testing.expectEqualStrings("10.0.0.1", str);
}
