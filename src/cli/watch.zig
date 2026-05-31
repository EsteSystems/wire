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

pub fn handleWatch(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("Watch commands:\n", .{});
        try stdout.print("  watch <host> <port|service>         Watch service connectivity\n", .{});
        try stdout.print("  watch <host> <port> --interval <ms> Set probe interval (default 1000)\n", .{});
        try stdout.print("  watch <host> <port> --alert <ms>    Alert if latency exceeds threshold\n", .{});
        try stdout.print("  watch interface <name>              Watch interface status\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire watch 10.0.0.1 ssh\n", .{});
        try stdout.print("  wire watch 10.0.0.1 80 --interval 500\n", .{});
        try stdout.print("  wire watch 10.0.0.1 443 --alert 100\n", .{});
        try stdout.print("  wire watch interface eth0\n", .{});
        return;
    }

    const first_arg = args[0];

    // wire watch interface <name>
    if (std.mem.eql(u8, first_arg, "interface")) {
        if (args.len < 2) {
            try stdout.print("Usage: wire watch interface <name>\n", .{});
            return;
        }

        const iface_name = args[1];
        var interval_ms: u32 = 1000;

        // Parse options
        var i: usize = 2;
        while (i + 1 < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--interval") or std.mem.eql(u8, args[i], "-i")) {
                interval_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    try stdout.print("Invalid interval: {s}\n", .{args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        watch.watchInterface(allocator, iface_name, interval_ms, null, stdout) catch |err| {
            try stdout.print("Watch failed: {}\n", .{err});
        };
        return;
    }

    // wire watch <host> <port|service> [options]
    if (args.len < 2) {
        try stdout.print("Usage: wire watch <host> <port|service>\n", .{});
        return;
    }

    const target = first_arg;
    const port_or_service = args[1];

    // Resolve port
    const port = probe.resolvePort(allocator, port_or_service, .tcp) catch |err| {
        if (err == error.unknownService) {
            try stdout.print("Unknown service: {s}\n", .{port_or_service});
        } else {
            try stdout.print("Failed to resolve port: {}\n", .{err});
        }
        return;
    };

    // Parse options
    var interval_ms: u32 = 1000;
    var timeout_ms: u32 = 3000;
    var alert_threshold_ms: ?u32 = null;

    var i: usize = 2;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--interval") or std.mem.eql(u8, args[i], "-i")) {
            interval_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                try stdout.print("Invalid interval: {s}\n", .{args[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--timeout") or std.mem.eql(u8, args[i], "-t")) {
            timeout_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                try stdout.print("Invalid timeout: {s}\n", .{args[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--alert") or std.mem.eql(u8, args[i], "-a")) {
            alert_threshold_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                try stdout.print("Invalid alert threshold: {s}\n", .{args[i + 1]});
                return;
            };
            i += 1;
        }
    }

    const config = watch.WatchConfig{
        .target = target,
        .port = port,
        .interval_ms = interval_ms,
        .timeout_ms = timeout_ms,
        .alert_threshold_ms = alert_threshold_ms,
        .alert_on_failure = true,
        .max_iterations = null,
    };

    const watch_stats = watch.watch(config, stdout) catch |err| {
        try stdout.print("Watch failed: {}\n", .{err});
        return;
    };

    try watch_stats.format(stdout);
}

