const std = @import("std");
const compat = @import("../compat.zig");
const netlink_interface = @import("../netlink/interface.zig");
const netlink_address = @import("../netlink/address.zig");
const netlink_route = @import("../netlink/route.zig");
const netlink_bond = @import("../netlink/bond.zig");
const netlink_bridge = @import("../netlink/bridge.zig");
const netlink_vlan = @import("../netlink/vlan.zig");
const netlink_veth = @import("../netlink/veth.zig");
const config_loader = @import("../config/loader.zig");
const state_types = @import("../state/types.zig");
const state_live = @import("../state/live.zig");
const state_desired = @import("../state/desired.zig");
const state_diff = @import("../state/diff.zig");
const state_exporter = @import("../state/exporter.zig");
const netlink_events = @import("../netlink/events.zig");
const reconciler = @import("../daemon/reconciler.zig");
const supervisor = @import("../daemon/supervisor.zig");
const ipc = @import("../daemon/ipc.zig");
const connectivity = @import("../analysis/connectivity.zig");
const health = @import("../analysis/health.zig");
const snapshots = @import("../history/snapshots.zig");
const changelog = @import("../history/changelog.zig");
const neighbor = @import("../netlink/neighbor.zig");
const ip_rule = @import("../netlink/rule.zig");
const namespace = @import("../netlink/namespace.zig");
const ethtool = @import("../netlink/ethtool.zig");
const tunnel = @import("../netlink/tunnel.zig");
const qdisc = @import("../netlink/qdisc.zig");
const stats = @import("../netlink/stats.zig");
const topology = @import("../analysis/topology.zig");
const native_ping = @import("../plugins/native/ping.zig");
const native_trace = @import("../plugins/native/traceroute.zig");
const native_capture = @import("../plugins/native/capture.zig");
const path_trace = @import("../diagnostics/trace.zig");
const probe = @import("../diagnostics/probe.zig");
const validate = @import("../diagnostics/validate.zig");
const watch = @import("../diagnostics/watch.zig");
const json_output = @import("../output/json.zig");
const linux = std.os.linux;

const version = "1.0.0";

pub fn handleRoute(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    // wire route show (or just 'wire route')
    if (filtered_args.len == 0 or std.mem.eql(u8, filtered_args[0], "show")) {
        const routes = try netlink_route.getRoutes(allocator);
        defer allocator.free(routes);

        // Get interfaces for name lookup
        const interfaces = try netlink_interface.getInterfaces(allocator);
        defer allocator.free(interfaces);

        if (use_json) {
            var json = json_output.JsonOutput.init(allocator, stdout);
            try json.writeRoutes(routes, interfaces);
            return;
        }

        for (routes) |route| {
            // Skip local/broadcast routes
            if (route.route_type != 1) continue; // Only unicast

            var dst_buf: [64]u8 = undefined;
            const dst = try route.formatDst(&dst_buf);

            try stdout.print("{s}", .{dst});

            if (route.has_gateway) {
                var gw_buf: [64]u8 = undefined;
                const gw = try route.formatGateway(&gw_buf);
                try stdout.print(" via {s}", .{gw});
            }

            // Find interface name
            if (route.oif != 0) {
                for (interfaces) |iface| {
                    if (@as(u32, @intCast(iface.index)) == route.oif) {
                        try stdout.print(" dev {s}", .{iface.getName()});
                        break;
                    }
                }
            }

            try stdout.print(" proto {s}", .{route.protocolString()});

            if (route.priority != 0) {
                try stdout.print(" metric {d}", .{route.priority});
            }

            try stdout.print("\n", .{});
        }
        return;
    }

    const action = filtered_args[0];

    // wire route add <dst> via <gateway>
    // wire route add <dst> dev <interface>
    // wire route add default via <gateway>
    if (std.mem.eql(u8, action, "add") and filtered_args.len >= 2) {
        const dst_str = filtered_args[1];
        var gateway: ?[4]u8 = null;
        var dst: ?[4]u8 = null;
        var dst_len: u8 = 0;
        var oif: ?u32 = null;

        // Parse destination
        if (std.mem.eql(u8, dst_str, "default")) {
            dst_len = 0; // default route
        } else {
            const parsed = netlink_address.parseIPv4(dst_str) catch {
                try stdout.print("Invalid destination: {s}\n", .{dst_str});
                return;
            };
            dst = parsed.addr;
            dst_len = parsed.prefix;
        }

        // Look for 'via' and 'dev'
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "via") and i + 1 < filtered_args.len) {
                const gw_parsed = netlink_address.parseIPv4(filtered_args[i + 1]) catch {
                    try stdout.print("Invalid gateway: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                gateway = gw_parsed.addr;
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "dev") and i + 1 < filtered_args.len) {
                const iface_name = filtered_args[i + 1];
                const maybe_iface = try netlink_interface.getInterfaceByName(allocator, iface_name);
                if (maybe_iface == null) {
                    try stdout.print("Interface {s} not found\n", .{iface_name});
                    return;
                }
                oif = @intCast(maybe_iface.?.index);
                i += 1;
            }
        }

        // Must have either gateway or device
        if (gateway == null and oif == null) {
            try stdout.print("Route requires either 'via <gateway>' or 'dev <interface>'\n", .{});
            return;
        }

        const dst_slice: ?[]const u8 = if (dst) |*d| d[0..4] else null;
        const gw_slice: ?[]const u8 = if (gateway) |*g| g[0..4] else null;

        try netlink_route.addRoute(linux.AF.INET, dst_slice, dst_len, gw_slice, oif);
        try stdout.print("Route added\n", .{});
        return;
    }

    // wire route del <dst>
    if (std.mem.eql(u8, action, "del") and filtered_args.len >= 2) {
        const dst_str = filtered_args[1];
        var dst: ?[4]u8 = null;
        var dst_len: u8 = 0;

        if (std.mem.eql(u8, dst_str, "default")) {
            dst_len = 0;
        } else {
            const parsed = netlink_address.parseIPv4(dst_str) catch {
                try stdout.print("Invalid destination: {s}\n", .{dst_str});
                return;
            };
            dst = parsed.addr;
            dst_len = parsed.prefix;
        }

        const dst_slice: ?[]const u8 = if (dst) |*d| d[0..4] else null;

        try netlink_route.deleteRoute(linux.AF.INET, dst_slice, dst_len);
        try stdout.print("Route deleted\n", .{});
        return;
    }

    try stdout.print("Unknown action: {s}\n", .{action});
}

