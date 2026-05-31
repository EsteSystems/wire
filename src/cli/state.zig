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

pub fn handleState(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    // Handle subcommands
    if (args.len > 0) {
        const subcmd = args[0];
        if (std.mem.eql(u8, subcmd, "export")) {
            try handleStateExport(allocator, io, args[1..]);
            return;
        } else if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help")) {
            try stdout.print("State commands:\n", .{});
            try stdout.print("  wire state                  Show live network state\n", .{});
            try stdout.print("  wire state export [file]    Export state to wire config format\n", .{});
            try stdout.print("\nExport options:\n", .{});
            try stdout.print("  --interfaces-only           Only export interfaces\n", .{});
            try stdout.print("  --routes-only               Only export routes\n", .{});
            try stdout.print("  --all                       Include all state (loopback, kernel routes)\n", .{});
            try stdout.print("  --no-comments               Omit comments from output\n", .{});
            return;
        }
    }

    try stdout.print("Querying live network state...\n\n", .{});

    var live_state = state_live.queryLiveState(allocator) catch |err| {
        try stdout.print("Failed to query live state: {}\n", .{err});
        return;
    };
    defer live_state.deinit();

    // Print interfaces
    try stdout.print("Interfaces ({d}):\n", .{live_state.interfaces.items.len});
    for (live_state.interfaces.items) |iface| {
        const state_str = if (iface.isUp()) "UP" else "DOWN";
        try stdout.print("  {s}: {s}, mtu {d}, type {s}\n", .{
            iface.getName(),
            state_str,
            iface.mtu,
            @tagName(iface.link_type),
        });
    }

    // Print addresses
    try stdout.print("\nAddresses ({d}):\n", .{live_state.addresses.items.len});
    for (live_state.addresses.items) |addr| {
        const family = if (addr.isIPv4()) "IPv4" else "IPv6";
        if (addr.isIPv4()) {
            try stdout.print("  {s}: {d}.{d}.{d}.{d}/{d}\n", .{
                family,
                addr.address[0],
                addr.address[1],
                addr.address[2],
                addr.address[3],
                addr.prefix_len,
            });
        }
    }

    // Print routes
    try stdout.print("\nRoutes ({d}):\n", .{live_state.routes.items.len});
    for (live_state.routes.items) |route| {
        if (route.isDefault()) {
            try stdout.print("  default via {d}.{d}.{d}.{d}\n", .{
                route.gateway[0],
                route.gateway[1],
                route.gateway[2],
                route.gateway[3],
            });
        } else if (route.family == 2) {
            try stdout.print("  {d}.{d}.{d}.{d}/{d}", .{
                route.dst[0],
                route.dst[1],
                route.dst[2],
                route.dst[3],
                route.dst_len,
            });
            if (route.has_gateway) {
                try stdout.print(" via {d}.{d}.{d}.{d}", .{
                    route.gateway[0],
                    route.gateway[1],
                    route.gateway[2],
                    route.gateway[3],
                });
            }
            try stdout.print("\n", .{});
        }
    }
}

pub fn handleStateExport(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    // Parse options
    var options = state_exporter.ExportOptions.default;
    var output_file: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--interfaces-only")) {
            options = state_exporter.ExportOptions.interfaces_only;
        } else if (std.mem.eql(u8, arg, "--routes-only")) {
            options = state_exporter.ExportOptions.routes_only;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.skip_loopback = false;
            options.skip_auto_addresses = false;
            options.skip_kernel_routes = false;
        } else if (std.mem.eql(u8, arg, "--no-comments")) {
            options.comments = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            output_file = arg;
        }
    }

    // Query live state
    var live_state = state_live.queryLiveState(allocator) catch |err| {
        try stdout.print("Failed to query live state: {}\n", .{err});
        return;
    };
    defer live_state.deinit();

    // Export
    var exporter = state_exporter.StateExporter.init(allocator, options);

    if (output_file) |path| {
        exporter.exportToFile(&live_state, path) catch |err| {
            try stdout.print("Failed to write file: {}\n", .{err});
            return;
        };
        try stdout.print("Exported state to: {s}\n", .{path});
    } else {
        // Export to stdout
        const output = exporter.exportToString(&live_state) catch |err| {
            try stdout.print("Failed to export state: {}\n", .{err});
            return;
        };
        defer allocator.free(output);
        try stdout.print("{s}", .{output});
    }
}

