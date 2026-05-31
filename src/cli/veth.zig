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

pub fn handleVeth(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("Veth pair commands:\n", .{});
        try stdout.print("  veth <name> peer <peer>        Create veth pair\n", .{});
        try stdout.print("  veth <name> delete             Delete veth pair\n", .{});
        try stdout.print("  veth <name> show               Show veth details\n", .{});
        try stdout.print("  veth <name> netns <pid>        Move veth to namespace (by PID)\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire veth veth0 peer veth1     Creates veth0 <-> veth1 pair\n", .{});
        try stdout.print("  wire veth veth0 delete         Deletes veth0 (and veth1)\n", .{});
        try stdout.print("  wire veth veth1 netns 12345    Moves veth1 to PID 12345's netns\n", .{});
        return;
    }

    const veth_name = args[0];

    if (args.len == 1) {
        // wire veth <name> - show veth details
        try showVethDetails(allocator, veth_name, stdout);
        return;
    }

    const action = args[1];

    // wire veth <name> peer <peer_name>
    if (std.mem.eql(u8, action, "peer")) {
        if (args.len < 3) {
            try stdout.print("Missing peer name. Usage: wire veth <name> peer <peer_name>\n", .{});
            return;
        }
        const peer_name = args[2];

        netlink_veth.createVethPair(veth_name, peer_name) catch |err| {
            try stdout.print("Failed to create veth pair: {}\n", .{err});
            return;
        };
        try stdout.print("Veth pair created: {s} <-> {s}\n", .{ veth_name, peer_name });
        return;
    }

    // wire veth <name> delete
    if (std.mem.eql(u8, action, "delete")) {
        netlink_veth.deleteVeth(veth_name) catch |err| {
            try stdout.print("Failed to delete veth: {}\n", .{err});
            return;
        };
        try stdout.print("Veth {s} deleted (and its peer)\n", .{veth_name});
        return;
    }

    // wire veth <name> show
    if (std.mem.eql(u8, action, "show")) {
        try showVethDetails(allocator, veth_name, stdout);
        return;
    }

    // wire veth <name> netns <pid>
    if (std.mem.eql(u8, action, "netns")) {
        if (args.len < 3) {
            try stdout.print("Missing PID. Usage: wire veth <name> netns <pid>\n", .{});
            return;
        }
        const pid = std.fmt.parseInt(i32, args[2], 10) catch {
            try stdout.print("Invalid PID: {s}\n", .{args[2]});
            return;
        };

        netlink_veth.setVethNetnsbyPid(veth_name, pid) catch |err| {
            try stdout.print("Failed to move veth to namespace: {}\n", .{err});
            return;
        };
        try stdout.print("Veth {s} moved to namespace of PID {d}\n", .{ veth_name, pid });
        return;
    }

    try stdout.print("Unknown veth action: {s}. Run 'wire veth' for help.\n", .{action});
}

fn showVethDetails(allocator: std.mem.Allocator, name: []const u8, writer: anytype) !void {
    const veth = netlink_veth.getVethInfo(allocator, name) catch |err| {
        try writer.print("Error getting veth info: {}\n", .{err});
        return;
    };

    if (veth == null) {
        try writer.print("Interface {s} not found or is not a veth\n", .{name});
        return;
    }

    const v = veth.?;
    try writer.print("Veth: {s}\n", .{v.getName()});
    try writer.print("  Index: {d}\n", .{v.index});
    try writer.print("  State: {s}\n", .{if (v.isUp()) "UP" else "DOWN"});
    if (v.peer_name_len > 0) {
        try writer.print("  Peer: {s} (index {d})\n", .{ v.getPeerName(), v.peer_index });
    } else if (v.peer_index > 0) {
        try writer.print("  Peer: index {d} (in different namespace)\n", .{v.peer_index});
    } else {
        try writer.print("  Peer: unknown\n", .{});
    }
}
