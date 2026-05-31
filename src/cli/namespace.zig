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

pub fn handleNamespace(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    var subcommand: []const u8 = "list";
    if (args.len > 0) {
        subcommand = args[0];
    }

    if (std.mem.eql(u8, subcommand, "list") or std.mem.eql(u8, subcommand, "show")) {
        // wire netns list
        const namespaces = namespace.listNamespaces(allocator) catch |err| {
            try stdout.print("Failed to list namespaces: {}\n", .{err});
            return;
        };
        defer allocator.free(namespaces);

        if (namespaces.len == 0) {
            try stdout.print("No named network namespaces found.\n", .{});
            try stdout.print("(Namespaces are stored in /var/run/netns/)\n", .{});
            return;
        }

        try stdout.print("Network Namespaces ({d} total):\n", .{namespaces.len});
        for (namespaces) |*ns| {
            try stdout.print("  {s}\n", .{ns.getName()});
        }
    } else if (std.mem.eql(u8, subcommand, "add") or std.mem.eql(u8, subcommand, "create")) {
        // wire netns add <name>
        if (args.len < 2) {
            try stdout.print("Usage: wire netns add <name>\n", .{});
            try stdout.print("Example: wire netns add myns\n", .{});
            return;
        }

        const name = args[1];

        // Check if already exists
        if (namespace.namespaceExists(name)) {
            try stdout.print("Namespace '{s}' already exists.\n", .{name});
            return;
        }

        namespace.createNamespace(name) catch |err| {
            try stdout.print("Failed to create namespace: {}\n", .{err});
            return;
        };

        try stdout.print("Created network namespace: {s}\n", .{name});
    } else if (std.mem.eql(u8, subcommand, "del") or std.mem.eql(u8, subcommand, "delete")) {
        // wire netns del <name>
        if (args.len < 2) {
            try stdout.print("Usage: wire netns del <name>\n", .{});
            return;
        }

        const name = args[1];

        if (!namespace.namespaceExists(name)) {
            try stdout.print("Namespace '{s}' does not exist.\n", .{name});
            return;
        }

        namespace.deleteNamespace(name) catch |err| {
            try stdout.print("Failed to delete namespace: {}\n", .{err});
            return;
        };

        try stdout.print("Deleted network namespace: {s}\n", .{name});
    } else if (std.mem.eql(u8, subcommand, "exec")) {
        // wire netns exec <name> <command...>
        if (args.len < 3) {
            try stdout.print("Usage: wire netns exec <name> <command> [args...]\n", .{});
            try stdout.print("Example: wire netns exec myns ip addr\n", .{});
            return;
        }

        const ns_name = args[1];
        const cmd_args = args[2..];

        if (!namespace.namespaceExists(ns_name)) {
            try stdout.print("Namespace '{s}' does not exist.\n", .{ns_name});
            return;
        }

        const result = namespace.execInNamespace(allocator, ns_name, cmd_args) catch |err| {
            try stdout.print("Failed to execute in namespace: {}\n", .{err});
            return;
        };

        switch (result) {
            .exited => |code| {
                if (code != 0) {
                    try stdout.print("Command exited with code: {d}\n", .{code});
                }
            },
            .signal => |sig| {
                try stdout.print("Command killed by signal: {d}\n", .{sig});
            },
            else => {},
        }
    } else if (std.mem.eql(u8, subcommand, "set")) {
        // wire netns set <interface> <namespace>
        if (args.len < 3) {
            try stdout.print("Usage: wire netns set <interface> <namespace>\n", .{});
            try stdout.print("Move an interface to a namespace.\n", .{});
            try stdout.print("Example: wire netns set veth1 myns\n", .{});
            return;
        }

        const iface_name = args[1];
        const ns_name = args[2];

        // Get interface index
        const maybe_iface = netlink_interface.getInterfaceByName(allocator, iface_name) catch |err| {
            try stdout.print("Failed to find interface: {}\n", .{err});
            return;
        };

        if (maybe_iface == null) {
            try stdout.print("Interface not found: {s}\n", .{iface_name});
            return;
        }

        if (!namespace.namespaceExists(ns_name)) {
            try stdout.print("Namespace '{s}' does not exist.\n", .{ns_name});
            return;
        }

        const if_index = maybe_iface.?.index;
        namespace.moveInterfaceToNamespace(if_index, ns_name) catch |err| {
            try stdout.print("Failed to move interface to namespace: {}\n", .{err});
            return;
        };

        try stdout.print("Moved interface '{s}' to namespace '{s}'\n", .{ iface_name, ns_name });
    } else if (std.mem.eql(u8, subcommand, "help")) {
        try stdout.print("Network Namespace commands:\n", .{});
        try stdout.print("  netns                            List all named namespaces\n", .{});
        try stdout.print("  netns list                       List all named namespaces\n", .{});
        try stdout.print("  netns add <name>                 Create a new namespace\n", .{});
        try stdout.print("  netns del <name>                 Delete a namespace\n", .{});
        try stdout.print("  netns exec <name> <cmd> [args]   Execute command in namespace\n", .{});
        try stdout.print("  netns set <interface> <name>     Move interface to namespace\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire netns add isolated\n", .{});
        try stdout.print("  wire netns set veth1 isolated\n", .{});
        try stdout.print("  wire netns exec isolated ip addr\n", .{});
        try stdout.print("  wire netns del isolated\n", .{});
    } else {
        try stdout.print("Unknown netns subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: list, add, del, exec, set, help\n", .{});
    }
}

