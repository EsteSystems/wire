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

pub fn handleValidate(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("Validate commands:\n", .{});
        try stdout.print("  validate config <file>              Validate configuration file\n", .{});
        try stdout.print("  validate vlan <id> on <interface>   Validate VLAN configuration\n", .{});
        try stdout.print("  validate path <iface> to <dest>     Validate network path\n", .{});
        try stdout.print("  validate service <host> <port>      Validate service connectivity\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire validate config /etc/wire/network.wire\n", .{});
        try stdout.print("  wire validate vlan 100 on eth0\n", .{});
        try stdout.print("  wire validate path eth0 to 10.0.0.1\n", .{});
        try stdout.print("  wire validate service 10.0.0.1 ssh\n", .{});
        return;
    }

    const subcommand = args[0];

    // wire validate config <file>
    if (std.mem.eql(u8, subcommand, "config")) {
        if (args.len < 2) {
            try stdout.print("Usage: wire validate config <config-file>\n", .{});
            return;
        }

        const config_path = args[1];

        var report = config_loader.validateConfig(config_path, allocator) catch |err| {
            try stdout.print("Failed to validate configuration: {}\n", .{err});
            return;
        };
        defer report.deinit(allocator);

        try stdout.print("Validation Report\n", .{});
        try stdout.print("-----------------\n", .{});
        try stdout.print("Total commands: {d}\n", .{report.total_commands});
        try stdout.print("Valid: {d}\n", .{report.valid_commands});
        try stdout.print("Errors: {d}\n", .{report.errors});

        if (report.errors > 0) {
            try stdout.print("\nErrors:\n", .{});
            for (report.error_messages) |msg| {
                try stdout.print("  - {s}\n", .{msg});
            }
            std.process.exit(1);
        } else {
            try stdout.print("\nConfiguration is valid.\n", .{});
        }
        return;
    }

    // wire validate vlan <id> on <interface>
    if (std.mem.eql(u8, subcommand, "vlan")) {
        if (args.len < 4) {
            try stdout.print("Usage: wire validate vlan <id> on <interface>\n", .{});
            return;
        }

        const vlan_id = std.fmt.parseInt(u16, args[1], 10) catch {
            try stdout.print("Invalid VLAN ID: {s}\n", .{args[1]});
            return;
        };

        // Expect "on" keyword
        if (!std.mem.eql(u8, args[2], "on")) {
            try stdout.print("Usage: wire validate vlan <id> on <interface>\n", .{});
            return;
        }

        const parent = args[3];

        try stdout.print("Validating VLAN {d} on {s}...\n\n", .{ vlan_id, parent });

        var result = validate.validateVlan(allocator, vlan_id, parent) catch |err| {
            try stdout.print("Validation failed: {}\n", .{err});
            return;
        };
        defer result.deinit();

        try result.format(stdout);
        return;
    }

    // wire validate path <iface> to <dest>
    if (std.mem.eql(u8, subcommand, "path")) {
        if (args.len < 4) {
            try stdout.print("Usage: wire validate path <interface> to <destination>\n", .{});
            return;
        }

        const source_iface = args[1];

        // Expect "to" keyword
        if (!std.mem.eql(u8, args[2], "to")) {
            try stdout.print("Usage: wire validate path <interface> to <destination>\n", .{});
            return;
        }

        const destination = args[3];

        try stdout.print("Validating path from {s} to {s}...\n\n", .{ source_iface, destination });

        var result = validate.validatePath(allocator, source_iface, destination) catch |err| {
            try stdout.print("Validation failed: {}\n", .{err});
            return;
        };
        defer result.deinit();

        try result.format(stdout);
        return;
    }

    // wire validate service <host> <port|service>
    if (std.mem.eql(u8, subcommand, "service")) {
        if (args.len < 3) {
            try stdout.print("Usage: wire validate service <host> <port|service>\n", .{});
            return;
        }

        const host = args[1];
        const port_or_service = args[2];

        try stdout.print("Validating service {s} on {s}...\n\n", .{ port_or_service, host });

        var result = validate.validateService(allocator, host, port_or_service) catch |err| {
            try stdout.print("Validation failed: {}\n", .{err});
            return;
        };
        defer result.deinit();

        try result.format(stdout);
        return;
    }

    try stdout.print("Unknown validate subcommand: {s}\n", .{subcommand});
    try stdout.print("Available: config, vlan, path, service\n", .{});
}

