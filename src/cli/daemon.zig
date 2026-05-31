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

pub fn handleDaemon(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};
    const pid_file = "/run/wire.pid";
    const socket_path = "/run/wire.sock";

    if (args.len == 0) {
        try stdout.print("Daemon commands:\n", .{});
        try stdout.print("  wire daemon start [config]    Start the daemon\n", .{});
        try stdout.print("  wire daemon stop              Stop the daemon\n", .{});
        try stdout.print("  wire daemon status            Show daemon status (via IPC)\n", .{});
        try stdout.print("  wire daemon reload            Reload configuration (via IPC)\n", .{});
        try stdout.print("  wire daemon diff              Show drift from desired state\n", .{});
        try stdout.print("  wire daemon state             Show live state from daemon\n", .{});
        return;
    }

    const action = args[0];

    if (std.mem.eql(u8, action, "start")) {
        // Check if already running
        if (supervisor.isRunning(pid_file)) {
            try stdout.print("Daemon is already running\n", .{});
            return;
        }

        // Parse start command options
        var config_path: []const u8 = "/etc/wire/network.conf";
        var verbose = false;
        var dry_run = false;

        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                verbose = true;
            } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
                dry_run = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                config_path = arg;
            }
        }

        try stdout.print("Starting wire daemon with config: {s}\n", .{config_path});

        // Create and start supervisor
        const config = supervisor.DaemonConfig{
            .config_path = config_path,
            .pid_file = pid_file,
            .socket_path = socket_path,
            .verbose = verbose,
            .dry_run = dry_run,
        };

        var sup = supervisor.Supervisor.init(allocator, config);
        defer sup.deinit();

        sup.start() catch |err| {
            try stdout.print("Failed to start daemon: {}\n", .{err});
            return;
        };

    } else if (std.mem.eql(u8, action, "stop")) {
        // Try IPC first, fall back to signal
        if (ipc.isDaemonRunning(socket_path)) {
            var client = ipc.IpcClient.init(allocator, socket_path);
            const response = client.requestStop() catch {
                // Fall back to signal
                try stopViaSignal(stdout, pid_file);
                return;
            };
            defer allocator.free(response);
            try stdout.print("{s}", .{response});
        } else if (supervisor.isRunning(pid_file)) {
            try stopViaSignal(stdout, pid_file);
        } else {
            try stdout.print("Daemon is not running\n", .{});
        }

    } else if (std.mem.eql(u8, action, "status")) {
        // Try IPC first for detailed status
        if (ipc.isDaemonRunning(socket_path)) {
            var client = ipc.IpcClient.init(allocator, socket_path);
            const response = client.getStatus() catch {
                // Fall back to PID check
                try statusViaPid(stdout, pid_file);
                return;
            };
            defer allocator.free(response);
            try stdout.print("Daemon Status (via IPC):\n", .{});
            try stdout.print("{s}", .{response});
        } else {
            try statusViaPid(stdout, pid_file);
        }

    } else if (std.mem.eql(u8, action, "reload")) {
        // Try IPC first
        if (ipc.isDaemonRunning(socket_path)) {
            var client = ipc.IpcClient.init(allocator, socket_path);
            const response = client.requestReload() catch {
                // Fall back to signal
                try reloadViaSignal(stdout, pid_file);
                return;
            };
            defer allocator.free(response);
            try stdout.print("{s}", .{response});
        } else if (supervisor.isRunning(pid_file)) {
            try reloadViaSignal(stdout, pid_file);
        } else {
            try stdout.print("Daemon is not running\n", .{});
        }

    } else if (std.mem.eql(u8, action, "diff")) {
        // Get drift from daemon via IPC
        if (!ipc.isDaemonRunning(socket_path)) {
            try stdout.print("Daemon is not running. Use 'wire diff <config>' for offline comparison.\n", .{});
            return;
        }

        var client = ipc.IpcClient.init(allocator, socket_path);
        const response = client.getDiff() catch |err| {
            try stdout.print("Failed to get diff from daemon: {}\n", .{err});
            return;
        };
        defer allocator.free(response);
        try stdout.print("{s}", .{response});

    } else if (std.mem.eql(u8, action, "state")) {
        // Get live state from daemon via IPC
        if (!ipc.isDaemonRunning(socket_path)) {
            try stdout.print("Daemon is not running. Use 'wire state' for direct query.\n", .{});
            return;
        }

        var client = ipc.IpcClient.init(allocator, socket_path);
        const response = client.getState() catch |err| {
            try stdout.print("Failed to get state from daemon: {}\n", .{err});
            return;
        };
        defer allocator.free(response);
        try stdout.print("{s}", .{response});

    } else {
        try stdout.print("Unknown daemon action: {s}\n", .{action});
        try stdout.print("Run 'wire daemon' for help.\n", .{});
    }
}

fn stopViaSignal(stdout: anytype, pid_file: []const u8) !void {
    try stdout.print("Stopping wire daemon...\n", .{});
    supervisor.sendSignal(pid_file, @intFromEnum(linux.SIG.TERM)) catch |err| {
        try stdout.print("Failed to stop daemon: {}\n", .{err});
        return;
    };
    try stdout.print("Stop signal sent\n", .{});
}
fn statusViaPid(stdout: anytype, pid_file: []const u8) !void {
    const pid = supervisor.readPidFile(pid_file) catch {
        try stdout.print("Daemon is not running\n", .{});
        return;
    };
    try stdout.print("Daemon is running (pid: {d})\n", .{pid});
}
fn reloadViaSignal(stdout: anytype, pid_file: []const u8) !void {
    try stdout.print("Reloading wire daemon configuration...\n", .{});
    supervisor.sendSignal(pid_file, @intFromEnum(linux.SIG.HUP)) catch |err| {
        try stdout.print("Failed to reload daemon: {}\n", .{err});
        return;
    };
    try stdout.print("Reload signal sent\n", .{});
}
