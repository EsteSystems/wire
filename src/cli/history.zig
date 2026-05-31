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

pub fn handleHistory(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    // Default to showing recent changes
    var subcommand: []const u8 = "show";
    if (args.len > 0) {
        subcommand = args[0];
    }

    if (std.mem.eql(u8, subcommand, "show")) {
        // wire history show [N]
        var count: usize = 10;
        if (args.len > 1) {
            count = std.fmt.parseInt(usize, args[1], 10) catch 10;
        }

        var logger = changelog.ChangeLogger.init(allocator, null);
        try logger.displayRecent(count, stdout);
    } else if (std.mem.eql(u8, subcommand, "snapshot")) {
        // wire history snapshot - create snapshot now
        var live = state_live.queryLiveState(allocator) catch |err| {
            try stdout.print("Failed to query live state: {}\n", .{err});
            return;
        };
        defer live.deinit();

        var mgr = snapshots.SnapshotManager.init(allocator, null);
        const snap = mgr.createSnapshot(&live) catch |err| {
            try stdout.print("Failed to create snapshot: {}\n", .{err});
            return;
        };

        try stdout.print("Created snapshot: {s}\n", .{snap.getPath()});
        try stdout.print("Timestamp: {d}\n", .{snap.timestamp});
    } else if (std.mem.eql(u8, subcommand, "list")) {
        // wire history list - list all snapshots
        var mgr = snapshots.SnapshotManager.init(allocator, null);
        const snap_list = mgr.listSnapshots() catch |err| {
            try stdout.print("Failed to list snapshots: {}\n", .{err});
            return;
        };
        defer allocator.free(snap_list);

        if (snap_list.len == 0) {
            try stdout.print("No snapshots found.\n", .{});
            return;
        }

        try stdout.print("Snapshots ({d} total)\n", .{snap_list.len});
        try stdout.print("---------------------\n", .{});

        for (snap_list) |*info| {
            try snapshots.SnapshotManager.formatSnapshotInfo(info, stdout);
        }
    } else if (std.mem.eql(u8, subcommand, "diff")) {
        // wire history diff <timestamp> - compare to snapshot
        if (args.len < 2) {
            try stdout.print("Usage: wire history diff <timestamp>\n", .{});
            return;
        }

        const timestamp = std.fmt.parseInt(i64, args[1], 10) catch {
            try stdout.print("Invalid timestamp: {s}\n", .{args[1]});
            return;
        };

        var mgr = snapshots.SnapshotManager.init(allocator, null);

        // Load snapshot
        var snap_state = mgr.loadSnapshot(timestamp) catch |err| {
            try stdout.print("Failed to load snapshot: {}\n", .{err});
            return;
        };
        defer snap_state.deinit();

        // Query live state
        var live = state_live.queryLiveState(allocator) catch |err| {
            try stdout.print("Failed to query live state: {}\n", .{err});
            return;
        };
        defer live.deinit();

        // Compare
        var diff = state_diff.compare(&snap_state, &live, allocator) catch |err| {
            try stdout.print("Failed to compare states: {}\n", .{err});
            return;
        };
        defer diff.deinit();

        if (diff.isEmpty()) {
            try stdout.print("No differences from snapshot {d}\n", .{timestamp});
        } else {
            try stdout.print("Differences from snapshot {d}:\n", .{timestamp});
            try stdout.print("-------------------------------\n", .{});
            try stdout.print("{d} changes detected\n", .{diff.changes.items.len});

            for (diff.changes.items) |change| {
                const entry = changelog.stateChangeToEntry(change);
                try entry.format(stdout);
            }
        }
    } else if (std.mem.eql(u8, subcommand, "log")) {
        // wire history log - show full changelog
        var logger = changelog.ChangeLogger.init(allocator, null);
        const entries = logger.readAll() catch |err| {
            try stdout.print("Failed to read changelog: {}\n", .{err});
            return;
        };
        defer allocator.free(entries);

        if (entries.len == 0) {
            try stdout.print("No changes recorded.\n", .{});
            return;
        }

        try stdout.print("Change Log ({d} entries)\n", .{entries.len});
        try stdout.print("-----------------------\n", .{});

        for (entries) |*entry| {
            try entry.format(stdout);
        }
    } else {
        try stdout.print("Unknown history subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, snapshot, list, diff, log\n", .{});
    }
}

