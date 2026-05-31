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

pub fn handleTopology(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    // Query live state
    var live_state = state_live.queryLiveState(allocator) catch |err| {
        try stdout.print("Failed to query network state: {}\n", .{err});
        return;
    };
    defer live_state.deinit();

    // Build topology graph
    var graph = topology.TopologyGraph.buildFromState(allocator, &live_state) catch |err| {
        try stdout.print("Failed to build topology: {}\n", .{err});
        return;
    };
    defer graph.deinit();

    // Default to show
    var subcommand: []const u8 = "show";
    if (args.len > 0) {
        subcommand = args[0];
    }

    if (std.mem.eql(u8, subcommand, "show")) {
        // wire topology show
        try graph.displayTree(stdout);
    } else if (std.mem.eql(u8, subcommand, "path")) {
        // wire topology path <src> to <dst>
        if (args.len < 4 or !std.mem.eql(u8, args[2], "to")) {
            try stdout.print("Usage: wire topology path <src> to <dst>\n", .{});
            try stdout.print("Example: wire topology path eth0 to br0\n", .{});
            return;
        }

        const src = args[1];
        const dst = args[3];

        const path = graph.findPath(src, dst, allocator) catch |err| {
            try stdout.print("Failed to find path: {}\n", .{err});
            return;
        };

        if (path) |p| {
            defer allocator.free(p);

            try stdout.print("Path from {s} to {s}:\n\n", .{ src, dst });
            try graph.displayPath(p, stdout);
            try stdout.print("\n", .{});

            // Validate path
            var validation = graph.validatePath(p);
            defer validation.deinit();
            try validation.format(stdout);
        } else {
            try stdout.print("No path found between {s} and {s}\n", .{ src, dst });
        }
    } else if (std.mem.eql(u8, subcommand, "children")) {
        // wire topology children <interface>
        if (args.len < 2) {
            try stdout.print("Usage: wire topology children <interface>\n", .{});
            return;
        }

        const iface_name = args[1];
        const node = graph.findNodeByName(iface_name);

        if (node) |n| {
            const children = graph.getChildren(n.index, allocator) catch |err| {
                try stdout.print("Failed to get children: {}\n", .{err});
                return;
            };
            defer allocator.free(children);

            if (children.len == 0) {
                try stdout.print("{s} has no child interfaces\n", .{iface_name});
            } else {
                try stdout.print("Children of {s}:\n", .{iface_name});
                for (children) |*child| {
                    try stdout.print("  ", .{});
                    try child.format(stdout);
                    try stdout.print("\n", .{});
                }
            }
        } else {
            try stdout.print("Interface {s} not found\n", .{iface_name});
        }
    } else {
        try stdout.print("Unknown topology subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, path, children\n", .{});
    }
}

