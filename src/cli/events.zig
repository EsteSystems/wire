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

pub fn handleEvents(io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    // Parse duration argument (default 10 seconds)
    var duration_secs: i32 = 10;
    if (args.len > 0) {
        duration_secs = std.fmt.parseInt(i32, args[0], 10) catch 10;
    }

    try stdout.print("Monitoring network events for {d} seconds...\n", .{duration_secs});
    try stdout.print("(Make network changes to see events)\n\n", .{});

    // Create event monitor
    var monitor = netlink_events.EventMonitor.initDefault() catch |err| {
        try stdout.print("Failed to create event monitor: {}\n", .{err});
        return;
    };
    defer monitor.deinit();

    // Set up callback context
    const Context = struct {
        stdout: @TypeOf(stdout),
        event_count: u32,

        fn callback(event: netlink_events.NetworkEvent, userdata: ?*anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(userdata.?));
            ctx.event_count += 1;

            var buf: [256]u8 = undefined;
            const event_str = netlink_events.formatEvent(&event, &buf) catch "?";
            ctx.stdout.print("[{d}] {s}\n", .{ ctx.event_count, event_str }) catch {};
        }
    };

    var ctx = Context{ .stdout = stdout, .event_count = 0 };
    monitor.setCallback(Context.callback, @ptrCast(&ctx));

    // Poll for events
    const start_time = compat.timestamp();
    const end_time = start_time + duration_secs;

    while (compat.timestamp() < end_time) {
        const result = monitor.poll(1000); // 1 second timeout
        if (result < 0) {
            try stdout.print("Error polling events\n", .{});
            break;
        }
    }

    try stdout.print("\nMonitoring complete. {d} events received.\n", .{ctx.event_count});
}

