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

pub fn handleDiff(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("Usage: wire diff <config-file>\n", .{});
        try stdout.print("Compare desired state from config file against live network state.\n", .{});
        return;
    }

    const config_path = args[0];

    // Load and parse configuration
    var loader = config_loader.ConfigLoader.init(allocator);
    defer loader.deinit();

    var loaded = loader.loadFile(config_path) catch |err| {
        try stdout.print("Failed to load config: {s}\n", .{@errorName(err)});
        return;
    };
    defer loaded.deinit(allocator);

    try stdout.print("Loaded {d} commands from {s}\n", .{ loaded.commands.len, config_path });

    // Build desired state
    var desired_state = state_desired.buildDesiredState(loaded.commands, allocator) catch |err| {
        try stdout.print("Failed to build desired state: {}\n", .{err});
        return;
    };
    defer desired_state.deinit();

    // Query live state
    var live_state = state_live.queryLiveState(allocator) catch |err| {
        try stdout.print("Failed to query live state: {}\n", .{err});
        return;
    };
    defer live_state.deinit();

    // Compare states
    var diff = state_diff.compare(&desired_state, &live_state, allocator) catch |err| {
        try stdout.print("Failed to compare states: {}\n", .{err});
        return;
    };
    defer diff.deinit();

    // Format and print diff
    try stdout.print("\n", .{});
    try state_diff.formatDiff(&diff, stdout);
}

