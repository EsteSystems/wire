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

pub fn handleHardware(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    if (filtered_args.len < 1) {
        try stdout.print("Usage: wire hw <interface> [show|ring|coalesce]\n", .{});
        try stdout.print("\nCommands:\n", .{});
        try stdout.print("  wire hw <interface>              Show hardware info\n", .{});
        try stdout.print("  wire hw <interface> show         Show driver and hardware info\n", .{});
        try stdout.print("  wire hw <interface> ring         Show ring buffer settings\n", .{});
        try stdout.print("  wire hw <interface> ring set rx <n> tx <n>\n", .{});
        try stdout.print("  wire hw <interface> coalesce     Show interrupt coalescing\n", .{});
        try stdout.print("  wire hw <interface> coalesce set rx <usecs> tx <usecs>\n", .{});
        return;
    }

    const iface_name = filtered_args[0];

    if (std.mem.eql(u8, iface_name, "help")) {
        try stdout.print("Hardware Tuning commands:\n", .{});
        try stdout.print("  wire hw <interface>              Show hardware info\n", .{});
        try stdout.print("  wire hw <interface> show         Show driver and hardware info\n", .{});
        try stdout.print("  wire hw <interface> ring         Show ring buffer settings\n", .{});
        try stdout.print("  wire hw <interface> ring set rx <n> tx <n>\n", .{});
        try stdout.print("  wire hw <interface> coalesce     Show interrupt coalescing\n", .{});
        try stdout.print("  wire hw <interface> coalesce set rx <usecs> tx <usecs>\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire hw eth0                     Show eth0 hardware info\n", .{});
        try stdout.print("  wire hw eth0 ring                Show eth0 ring buffers\n", .{});
        try stdout.print("  wire hw eth0 ring set rx 4096    Set RX ring to 4096\n", .{});
        return;
    }

    var subcommand: []const u8 = "show";
    if (filtered_args.len > 1) {
        subcommand = filtered_args[1];
    }

    if (std.mem.eql(u8, subcommand, "show")) {
        // wire hw <interface> show
        try stdout.print("Interface: {s}\n", .{iface_name});

        // Driver info
        const drv = ethtool.getDriverInfo(iface_name) catch |err| {
            try stdout.print("  Driver info: unavailable ({s})\n", .{@errorName(err)});
            return;
        };

        try stdout.print("  Driver: {s}\n", .{drv.getDriver()});
        if (drv.version_len > 0) {
            try stdout.print("  Version: {s}\n", .{drv.getVersion()});
        }
        if (drv.firmware_len > 0) {
            try stdout.print("  Firmware: {s}\n", .{drv.getFirmware()});
        }
        if (drv.bus_len > 0) {
            try stdout.print("  Bus: {s}\n", .{drv.getBus()});
        }

        // Link status
        const link = ethtool.getLinkStatus(iface_name) catch false;
        try stdout.print("  Link detected: {s}\n", .{if (link) "yes" else "no"});

        // Ring buffers
        if (ethtool.getRingParams(iface_name)) |ring| {
            try stdout.print("\n  Ring buffers:\n", .{});
            try stdout.print("    RX: {d}/{d}\n", .{ ring.rx_current, ring.rx_max });
            try stdout.print("    TX: {d}/{d}\n", .{ ring.tx_current, ring.tx_max });
        } else |_| {}

        // Coalesce
        if (ethtool.getCoalesceParams(iface_name)) |coal| {
            try stdout.print("\n  Coalescing:\n", .{});
            try stdout.print("    RX usecs: {d}, frames: {d}\n", .{ coal.rx_usecs, coal.rx_frames });
            try stdout.print("    TX usecs: {d}, frames: {d}\n", .{ coal.tx_usecs, coal.tx_frames });
            try stdout.print("    Adaptive RX: {s}, TX: {s}\n", .{
                if (coal.adaptive_rx) "on" else "off",
                if (coal.adaptive_tx) "on" else "off",
            });
        } else |_| {}
    } else if (std.mem.eql(u8, subcommand, "ring")) {
        // wire hw <interface> ring [set rx <n> tx <n>]
        if (filtered_args.len > 2 and std.mem.eql(u8, filtered_args[2], "set")) {
            // Parse set options
            var rx: ?u32 = null;
            var tx: ?u32 = null;

            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "rx") and i + 1 < filtered_args.len) {
                    rx = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid RX value: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "tx") and i + 1 < filtered_args.len) {
                    tx = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid TX value: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            if (rx == null and tx == null) {
                try stdout.print("No values specified. Usage: wire hw <if> ring set rx <n> tx <n>\n", .{});
                return;
            }

            ethtool.setRingParams(iface_name, rx, tx) catch |err| {
                try stdout.print("Failed to set ring parameters: {s}\n", .{@errorName(err)});
                return;
            };

            try stdout.print("Ring parameters updated:\n", .{});
            if (rx) |r| try stdout.print("  RX: {d}\n", .{r});
            if (tx) |t| try stdout.print("  TX: {d}\n", .{t});
        } else {
            // Show ring params
            const ring = ethtool.getRingParams(iface_name) catch |err| {
                if (use_json) {
                    try stdout.print("{{\"error\": \"{s}\"}}\n", .{@errorName(err)});
                } else {
                    try stdout.print("Failed to get ring parameters: {s}\n", .{@errorName(err)});
                }
                return;
            };

            if (use_json) {
                try stdout.print("{{\n", .{});
                try stdout.print("  \"interface\": \"{s}\",\n", .{iface_name});
                try stdout.print("  \"rx_current\": {d},\n", .{ring.rx_current});
                try stdout.print("  \"rx_max\": {d},\n", .{ring.rx_max});
                try stdout.print("  \"tx_current\": {d},\n", .{ring.tx_current});
                try stdout.print("  \"tx_max\": {d}\n", .{ring.tx_max});
                try stdout.print("}}\n", .{});
            } else {
                try stdout.print("Ring parameters for {s}:\n", .{iface_name});
                try stdout.print("  RX:  current {d}, max {d}\n", .{ ring.rx_current, ring.rx_max });
                try stdout.print("  TX:  current {d}, max {d}\n", .{ ring.tx_current, ring.tx_max });
            }
        }
    } else if (std.mem.eql(u8, subcommand, "coalesce")) {
        // wire hw <interface> coalesce [set rx <usecs> tx <usecs>]
        if (filtered_args.len > 2 and std.mem.eql(u8, filtered_args[2], "set")) {
            // Parse set options
            var rx_usecs: ?u32 = null;
            var tx_usecs: ?u32 = null;

            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "rx") and i + 1 < filtered_args.len) {
                    rx_usecs = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid RX value: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "tx") and i + 1 < filtered_args.len) {
                    tx_usecs = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid TX value: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            if (rx_usecs == null and tx_usecs == null) {
                try stdout.print("No values specified. Usage: wire hw <if> coalesce set rx <usecs> tx <usecs>\n", .{});
                return;
            }

            ethtool.setCoalesceParams(iface_name, rx_usecs, tx_usecs) catch |err| {
                try stdout.print("Failed to set coalesce parameters: {s}\n", .{@errorName(err)});
                return;
            };

            try stdout.print("Coalesce parameters updated:\n", .{});
            if (rx_usecs) |r| try stdout.print("  RX: {d} usecs\n", .{r});
            if (tx_usecs) |t| try stdout.print("  TX: {d} usecs\n", .{t});
        } else {
            // Show coalesce params
            const coal = ethtool.getCoalesceParams(iface_name) catch |err| {
                if (use_json) {
                    try stdout.print("{{\"error\": \"{s}\"}}\n", .{@errorName(err)});
                } else {
                    try stdout.print("Failed to get coalesce parameters: {s}\n", .{@errorName(err)});
                }
                return;
            };

            if (use_json) {
                try stdout.print("{{\n", .{});
                try stdout.print("  \"interface\": \"{s}\",\n", .{iface_name});
                try stdout.print("  \"rx_usecs\": {d},\n", .{coal.rx_usecs});
                try stdout.print("  \"rx_frames\": {d},\n", .{coal.rx_frames});
                try stdout.print("  \"tx_usecs\": {d},\n", .{coal.tx_usecs});
                try stdout.print("  \"tx_frames\": {d},\n", .{coal.tx_frames});
                try stdout.print("  \"adaptive_rx\": {s},\n", .{if (coal.adaptive_rx) "true" else "false"});
                try stdout.print("  \"adaptive_tx\": {s}\n", .{if (coal.adaptive_tx) "true" else "false"});
                try stdout.print("}}\n", .{});
            } else {
                try stdout.print("Coalesce parameters for {s}:\n", .{iface_name});
                try stdout.print("  RX: {d} usecs, {d} frames\n", .{ coal.rx_usecs, coal.rx_frames });
                try stdout.print("  TX: {d} usecs, {d} frames\n", .{ coal.tx_usecs, coal.tx_frames });
                try stdout.print("  Adaptive RX: {s}\n", .{if (coal.adaptive_rx) "on" else "off"});
                try stdout.print("  Adaptive TX: {s}\n", .{if (coal.adaptive_tx) "on" else "off"});
            }
        }
    } else {
        try stdout.print("Unknown hw subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, ring, coalesce\n", .{});
    }
}

