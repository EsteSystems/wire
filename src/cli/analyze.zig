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

pub fn handleAnalyze(allocator: std.mem.Allocator, io: std.Io) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    try stdout.print("\nNetwork Analysis Report\n", .{});
    try stdout.print("=======================\n\n", .{});

    // Query live state
    var live_state = state_live.queryLiveState(allocator) catch {
        try stdout.print("Error: Could not query network state\n", .{});
        return;
    };
    defer live_state.deinit();

    // Connectivity Analysis
    var conn_analyzer = connectivity.ConnectivityAnalyzer.init(allocator);
    defer conn_analyzer.deinit();

    _ = conn_analyzer.analyze(&live_state) catch {};
    try conn_analyzer.format(stdout);
    try stdout.print("\n", .{});

    // Configuration Health
    var health_analyzer = health.HealthAnalyzer.init(allocator);
    defer health_analyzer.deinit();

    _ = health_analyzer.analyze(&live_state) catch {};
    try health_analyzer.format(stdout);
    try stdout.print("\n", .{});

    // Interface Details
    try stdout.print("Interface Details\n", .{});
    try stdout.print("-----------------\n", .{});

    for (live_state.interfaces.items) |*iface| {
        const status: []const u8 = if (iface.isUp() and iface.hasCarrier())
            "[ok]"
        else if (iface.isUp())
            "[warn]"
        else
            "[down]";

        const addrs = live_state.getAddressesForInterface(iface.index);

        var addr_info: [64]u8 = undefined;
        var addr_len: usize = 0;

        if (addrs.len > 0) {
            if (addrs[0].family == 2) {
                const addr_str = std.fmt.bufPrint(&addr_info, "{d}.{d}.{d}.{d}/{d}", .{
                    addrs[0].address[0],
                    addrs[0].address[1],
                    addrs[0].address[2],
                    addrs[0].address[3],
                    addrs[0].prefix_len,
                }) catch continue;
                addr_len = addr_str.len;
            }
        }

        const state = if (iface.isUp()) "up" else "down";
        const carrier = if (iface.hasCarrier()) "carrier" else "no-carrier";

        if (addr_len > 0) {
            try stdout.print("{s} {s}: {s}, {s}, {s}\n", .{ status, iface.getName(), state, carrier, addr_info[0..addr_len] });
        } else if (iface.link_type != .loopback) {
            try stdout.print("{s} {s}: {s}, {s}, no address\n", .{ status, iface.getName(), state, carrier });
        } else {
            try stdout.print("{s} {s}: {s}, loopback\n", .{ status, iface.getName(), state });
        }
    }

    // Summary
    try stdout.print("\nSummary\n", .{});
    try stdout.print("-------\n", .{});

    const conn_counts = conn_analyzer.countByStatus();
    const health_counts = health_analyzer.countByStatus();
    const overall = health_analyzer.overallStatus();

    try stdout.print("Connectivity: {d} ok, {d} warnings, {d} errors\n", .{ conn_counts.ok, conn_counts.warning, conn_counts.err });
    try stdout.print("Health: {d} healthy, {d} degraded, {d} unhealthy\n", .{ health_counts.healthy, health_counts.degraded, health_counts.unhealthy });
    try stdout.print("Overall status: {s}\n", .{switch (overall) {
        .healthy => "HEALTHY",
        .degraded => "DEGRADED",
        .unhealthy => "UNHEALTHY",
    }});

    try stdout.print("\n", .{});
}

