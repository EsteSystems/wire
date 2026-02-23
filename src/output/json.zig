const std = @import("std");
const netlink_interface = @import("../netlink/interface.zig");
const netlink_address = @import("../netlink/address.zig");
const netlink_route = @import("../netlink/route.zig");
const netlink_bond = @import("../netlink/bond.zig");
const neighbor = @import("../netlink/neighbor.zig");
const ip_rule = @import("../netlink/rule.zig");
const qdisc = @import("../netlink/qdisc.zig");
const stats = @import("../netlink/stats.zig");
const state_types = @import("../state/types.zig");

/// Output format for CLI commands
pub const OutputFormat = enum {
    text,
    json,
};

/// JSON output helper
pub const JsonOutput = struct {
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) Self {
        return Self{
            .writer = writer,
            .allocator = allocator,
        };
    }

    /// Write interfaces as JSON array
    pub fn writeInterfaces(self: *Self, interfaces: []const netlink_interface.Interface, addresses: ?[]const []const netlink_address.Address) !void {
        try self.writer.writeAll("[\n");

        for (interfaces, 0..) |iface, i| {
            if (i > 0) try self.writer.writeAll(",\n");
            try self.writeInterface(&iface, if (addresses) |addrs| addrs[i] else null);
        }

        try self.writer.writeAll("\n]\n");
    }

    /// Write single interface as JSON object
    pub fn writeInterface(self: *Self, iface: *const netlink_interface.Interface, addrs: ?[]const netlink_address.Address) !void {
        try self.writer.writeAll("  {\n");
        try self.writer.print("    \"index\": {d},\n", .{iface.index});
        try self.writer.print("    \"name\": \"{s}\",\n", .{iface.getName()});
        try self.writer.print("    \"mtu\": {d},\n", .{iface.mtu});
        try self.writer.print("    \"flags\": {d},\n", .{iface.flags});
        try self.writer.print("    \"up\": {s},\n", .{if (iface.isUp()) "true" else "false"});
        try self.writer.print("    \"carrier\": {s},\n", .{if (iface.hasCarrier()) "true" else "false"});
        try self.writer.print("    \"operstate\": \"{s}\",\n", .{iface.operstateString()});

        if (iface.has_mac) {
            const mac = iface.formatMac();
            try self.writer.print("    \"mac\": \"{s}\",\n", .{mac});
        } else {
            try self.writer.writeAll("    \"mac\": null,\n");
        }

        // Addresses
        try self.writer.writeAll("    \"addresses\": [");
        if (addrs) |addresses| {
            for (addresses, 0..) |addr, j| {
                if (j > 0) try self.writer.writeAll(", ");
                var addr_buf: [64]u8 = undefined;
                const addr_str = addr.formatAddress(&addr_buf) catch "?";
                try self.writer.print("\"{s}\"", .{addr_str});
            }
        }
        try self.writer.writeAll("]\n");

        try self.writer.writeAll("  }");
    }

    /// Write routes as JSON array
    pub fn writeRoutes(self: *Self, routes: []const netlink_route.Route, interfaces: []const netlink_interface.Interface) !void {
        try self.writer.writeAll("[\n");

        var first = true;
        for (routes) |route| {
            // Skip non-unicast routes
            if (route.route_type != 1) continue;

            if (!first) try self.writer.writeAll(",\n");
            first = false;

            try self.writer.writeAll("  {\n");

            // Destination
            var dst_buf: [64]u8 = undefined;
            const dst = route.formatDst(&dst_buf) catch "?";
            try self.writer.print("    \"destination\": \"{s}\",\n", .{dst});

            // Gateway
            if (route.has_gateway) {
                var gw_buf: [64]u8 = undefined;
                const gw = route.formatGateway(&gw_buf) catch "?";
                try self.writer.print("    \"gateway\": \"{s}\",\n", .{gw});
            } else {
                try self.writer.writeAll("    \"gateway\": null,\n");
            }

            // Device
            var dev_name: []const u8 = "?";
            if (route.oif != 0) {
                for (interfaces) |iface| {
                    if (@as(u32, @intCast(iface.index)) == route.oif) {
                        dev_name = iface.getName();
                        break;
                    }
                }
            }
            try self.writer.print("    \"device\": \"{s}\",\n", .{dev_name});

            try self.writer.print("    \"protocol\": \"{s}\",\n", .{route.protocolString()});
            try self.writer.print("    \"metric\": {d}\n", .{route.priority});

            try self.writer.writeAll("  }");
        }

        try self.writer.writeAll("\n]\n");
    }

    /// Write neighbors as JSON array
    pub fn writeNeighbors(self: *Self, neighbors: []const neighbor.NeighborEntry, interfaces: []const netlink_interface.Interface) !void {
        try self.writer.writeAll("[\n");

        for (neighbors, 0..) |neigh, i| {
            if (i > 0) try self.writer.writeAll(",\n");

            try self.writer.writeAll("  {\n");

            // IP address
            var ip_buf: [64]u8 = undefined;
            const ip_str = neigh.formatAddress(&ip_buf) catch "?";
            try self.writer.print("    \"address\": \"{s}\",\n", .{ip_str});

            // MAC address
            const mac_str = neigh.formatLladdr();
            try self.writer.print("    \"lladdr\": \"{s}\",\n", .{mac_str});

            // Device
            var dev_name: []const u8 = "?";
            for (interfaces) |iface| {
                if (iface.index == neigh.interface_index) {
                    dev_name = iface.getName();
                    break;
                }
            }
            try self.writer.print("    \"device\": \"{s}\",\n", .{dev_name});

            try self.writer.print("    \"state\": \"{s}\"\n", .{neigh.state.toString()});

            try self.writer.writeAll("  }");
        }

        try self.writer.writeAll("\n]\n");
    }

    /// Write bonds as JSON array
    pub fn writeBonds(self: *Self, bonds: []const netlink_bond.Bond) !void {
        try self.writer.writeAll("[\n");

        for (bonds, 0..) |bond, i| {
            if (i > 0) try self.writer.writeAll(",\n");

            try self.writer.writeAll("  {\n");
            try self.writer.print("    \"name\": \"{s}\",\n", .{bond.getName()});
            try self.writer.print("    \"index\": {d},\n", .{bond.index});
            try self.writer.print("    \"mode\": \"{s}\",\n", .{bond.mode.toString()});

            // Members (as interface indices)
            try self.writer.writeAll("    \"member_indices\": [");
            var first = true;
            for (bond.members) |member_index| {
                if (!first) try self.writer.writeAll(", ");
                first = false;
                try self.writer.print("{d}", .{member_index});
            }
            try self.writer.writeAll("]\n");

            try self.writer.writeAll("  }");
        }

        try self.writer.writeAll("\n]\n");
    }

    /// Write qdiscs as JSON array
    pub fn writeQdiscs(self: *Self, qdiscs_list: []const qdisc.QdiscInfo) !void {
        try self.writer.writeAll("[\n");

        for (qdiscs_list, 0..) |q, i| {
            if (i > 0) try self.writer.writeAll(",\n");

            try self.writer.writeAll("  {\n");

            var handle_buf: [16]u8 = undefined;
            var parent_buf: [16]u8 = undefined;
            const handle_str = q.formatHandle(&handle_buf) catch "?";
            const parent_str = q.formatParent(&parent_buf) catch "?";

            try self.writer.print("    \"handle\": \"{s}\",\n", .{handle_str});
            try self.writer.print("    \"parent\": \"{s}\",\n", .{parent_str});
            try self.writer.print("    \"kind\": \"{s}\"\n", .{q.getKind()});

            try self.writer.writeAll("  }");
        }

        try self.writer.writeAll("\n]\n");
    }

    /// Write interface statistics as JSON
    pub fn writeStats(self: *Self, iface_name: []const u8, iface_stats: *const stats.InterfaceStats) !void {
        try self.writer.writeAll("{\n");
        try self.writer.print("  \"interface\": \"{s}\",\n", .{iface_name});
        try self.writer.print("  \"rx_packets\": {d},\n", .{iface_stats.rx_packets});
        try self.writer.print("  \"tx_packets\": {d},\n", .{iface_stats.tx_packets});
        try self.writer.print("  \"rx_bytes\": {d},\n", .{iface_stats.rx_bytes});
        try self.writer.print("  \"tx_bytes\": {d},\n", .{iface_stats.tx_bytes});
        try self.writer.print("  \"rx_errors\": {d},\n", .{iface_stats.rx_errors});
        try self.writer.print("  \"tx_errors\": {d},\n", .{iface_stats.tx_errors});
        try self.writer.print("  \"rx_dropped\": {d},\n", .{iface_stats.rx_dropped});
        try self.writer.print("  \"tx_dropped\": {d},\n", .{iface_stats.tx_dropped});
        try self.writer.print("  \"multicast\": {d},\n", .{iface_stats.multicast});
        try self.writer.print("  \"collisions\": {d}\n", .{iface_stats.collisions});
        try self.writer.writeAll("}\n");
    }

    /// Write rules as JSON array
    pub fn writeRules(self: *Self, rules: []const ip_rule.Rule) !void {
        try self.writer.writeAll("[\n");

        for (rules, 0..) |rule, i| {
            if (i > 0) try self.writer.writeAll(",\n");

            try self.writer.writeAll("  {\n");
            try self.writer.print("    \"priority\": {d},\n", .{rule.priority});

            // Source
            if (rule.src_len > 0) {
                var src_buf: [64]u8 = undefined;
                const src_str = rule.formatSrc(&src_buf) catch "?";
                try self.writer.print("    \"from\": \"{s}\",\n", .{src_str});
            } else {
                try self.writer.writeAll("    \"from\": \"all\",\n");
            }

            // Destination
            if (rule.dst_len > 0) {
                var dst_buf: [64]u8 = undefined;
                const dst_str = rule.formatDst(&dst_buf) catch "?";
                try self.writer.print("    \"to\": \"{s}\",\n", .{dst_str});
            } else {
                try self.writer.writeAll("    \"to\": \"all\",\n");
            }

            try self.writer.print("    \"table\": {d},\n", .{rule.table});
            try self.writer.print("    \"action\": \"{s}\"\n", .{rule.actionName()});

            try self.writer.writeAll("  }");
        }

        try self.writer.writeAll("\n]\n");
    }

    /// Write generic success message as JSON
    pub fn writeSuccess(self: *Self, message: []const u8) !void {
        try self.writer.writeAll("{\n");
        try self.writer.writeAll("  \"status\": \"success\",\n");
        try self.writer.print("  \"message\": \"{s}\"\n", .{message});
        try self.writer.writeAll("}\n");
    }

    /// Write error as JSON
    pub fn writeError(self: *Self, message: []const u8) !void {
        try self.writer.writeAll("{\n");
        try self.writer.writeAll("  \"status\": \"error\",\n");
        try self.writer.print("  \"message\": \"{s}\"\n", .{message});
        try self.writer.writeAll("}\n");
    }
};

/// Parse --json flag from args, returns (format, remaining_args)
pub fn parseOutputFormat(args: []const []const u8) struct { format: OutputFormat, args: []const []const u8 } {
    var format = OutputFormat.text;
    var start: usize = 0;

    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            format = OutputFormat.json;
            start = i + 1;
            break;
        }
    }

    // Return remaining args after --json, or all args if no --json
    if (format == .json and start > 0) {
        // Filter out --json from args
        return .{ .format = format, .args = args };
    }

    return .{ .format = format, .args = args };
}

/// Check if --json flag is present in args
pub fn hasJsonFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            return true;
        }
    }
    return false;
}

/// Filter out --json flag from args
pub fn filterJsonFlag(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var filtered = std.array_list.Managed([]const u8).init(allocator);
    errdefer filtered.deinit();

    for (args) |arg| {
        if (!std.mem.eql(u8, arg, "--json") and !std.mem.eql(u8, arg, "-j")) {
            try filtered.append(arg);
        }
    }

    return filtered.toOwnedSlice();
}
