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

pub fn handleApply(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("Usage: wire apply <config-file> [options]\n", .{});
        try stdout.print("\nOptions:\n", .{});
        try stdout.print("  --dry-run, -n    Validate without applying changes\n", .{});
        try stdout.print("  --yes, -y        Skip confirmation prompt\n", .{});
        try stdout.print("  --force          Apply despite errors (use with caution)\n", .{});
        try stdout.print("  --strict         Fail on warnings too (for CI/CD)\n", .{});
        try stdout.print("  --staging        Relaxed validation (for staging environments)\n", .{});
        try stdout.print("  --verbose, -v    Show detailed output\n", .{});
        return;
    }

    const config_path = args[0];
    var options = config_loader.ApplyOptions{};

    // Check for flags
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            options.skip_confirmation = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            options.strict = true;
        } else if (std.mem.eql(u8, arg, "--staging")) {
            options.staging = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            options.verbose = true;
        }
    }

    // Warn about conflicting options
    if (options.force and options.strict) {
        try stdout.print("Warning: --force and --strict are conflicting options\n", .{});
        try stdout.print("  --force will apply despite errors, --strict will fail on warnings\n", .{});
        try stdout.print("  Using --force takes precedence\n\n", .{});
    }

    if (options.staging) {
        try stdout.print("Staging mode: Validation warnings will be logged but not block.\n", .{});
        try stdout.print("Unreachable gateways and missing dependencies are expected.\n\n", .{});
    }

    const result = config_loader.applyConfig(config_path, allocator, options) catch |err| {
        try stdout.print("Failed to apply configuration: {}\n", .{err});
        return;
    };

    if (!result.success) {
        std.process.exit(1);
    }
}

