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

pub fn handleRule(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    var subcommand: []const u8 = "show";
    if (filtered_args.len > 0) {
        subcommand = filtered_args[0];
    }

    if (std.mem.eql(u8, subcommand, "show") or std.mem.eql(u8, subcommand, "list")) {
        // wire rule show
        const rules = ip_rule.getRules(allocator, linux.AF.INET) catch |err| {
            try stdout.print("Failed to query IP rules: {}\n", .{err});
            return;
        };
        defer allocator.free(rules);

        if (use_json) {
            var json = json_output.JsonOutput.init(allocator, stdout);
            try json.writeRules(rules);
            return;
        }

        if (rules.len == 0) {
            try stdout.print("No IP rules found.\n", .{});
            return;
        }

        try stdout.print("IP Rules ({d} entries)\n", .{rules.len});
        try stdout.print("{s:<8} {s:<20} {s:<10} {s:<10}\n", .{ "Prio", "From", "Action", "Table" });
        try stdout.print("{s:-<8} {s:-<20} {s:-<10} {s:-<10}\n", .{ "", "", "", "" });

        for (rules) |*r| {
            var src_buf: [32]u8 = undefined;
            const src_str = r.formatSrc(&src_buf) catch "?";

            // Table name or number
            var table_str: [16]u8 = undefined;
            const table_display = if (r.table == ip_rule.RT_TABLE.LOCAL)
                "local"
            else if (r.table == ip_rule.RT_TABLE.MAIN)
                "main"
            else if (r.table == ip_rule.RT_TABLE.DEFAULT)
                "default"
            else blk: {
                break :blk std.fmt.bufPrint(&table_str, "{d}", .{r.table}) catch "?";
            };

            try stdout.print("{d:<8} {s:<20} {s:<10} {s:<10}", .{
                r.priority,
                src_str,
                r.actionName(),
                table_display,
            });

            // Show fwmark if set
            if (r.fwmark > 0) {
                try stdout.print(" fwmark 0x{x}", .{r.fwmark});
            }

            // Show iif if set
            if (r.getIifname()) |iif| {
                try stdout.print(" iif {s}", .{iif});
            }

            // Show oif if set
            if (r.getOifname()) |oif| {
                try stdout.print(" oif {s}", .{oif});
            }

            try stdout.print("\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "add")) {
        // wire rule add from <prefix> table <table> [prio <priority>]
        // wire rule add fwmark <mark> table <table> [prio <priority>]
        if (filtered_args.len < 4) {
            try stdout.print("Usage:\n", .{});
            try stdout.print("  wire rule add from <prefix> table <table> [prio <n>]\n", .{});
            try stdout.print("  wire rule add fwmark <mark> table <table> [prio <n>]\n", .{});
            try stdout.print("  wire rule add to <prefix> table <table> [prio <n>]\n", .{});
            try stdout.print("\nExamples:\n", .{});
            try stdout.print("  wire rule add from 10.0.0.0/8 table 100 prio 100\n", .{});
            try stdout.print("  wire rule add fwmark 0x1 table 100\n", .{});
            return;
        }

        var options = ip_rule.RuleOptions.init();
        var table: u32 = ip_rule.RT_TABLE.MAIN;
        var priority: u32 = 32766; // Default priority

        // Parse arguments
        var i: usize = 1;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "from") and i + 1 < filtered_args.len) {
                const prefix = ip_rule.parsePrefix(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid source prefix: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                @memcpy(options.src[0..4], &prefix.addr);
                options.src_len = prefix.len;
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "to") and i + 1 < filtered_args.len) {
                const prefix = ip_rule.parsePrefix(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid destination prefix: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                @memcpy(options.dst[0..4], &prefix.addr);
                options.dst_len = prefix.len;
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "table") and i + 1 < filtered_args.len) {
                // Check for named tables
                const table_arg = filtered_args[i + 1];
                table = if (std.mem.eql(u8, table_arg, "main"))
                    ip_rule.RT_TABLE.MAIN
                else if (std.mem.eql(u8, table_arg, "local"))
                    ip_rule.RT_TABLE.LOCAL
                else if (std.mem.eql(u8, table_arg, "default"))
                    ip_rule.RT_TABLE.DEFAULT
                else
                    std.fmt.parseInt(u32, table_arg, 10) catch {
                        try stdout.print("Invalid table: {s}\n", .{table_arg});
                        return;
                    };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "prio") and i + 1 < filtered_args.len) {
                priority = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid priority: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "fwmark") and i + 1 < filtered_args.len) {
                const mark_str = filtered_args[i + 1];
                // Support hex (0x...) or decimal
                options.fwmark = if (mark_str.len > 2 and std.mem.eql(u8, mark_str[0..2], "0x"))
                    std.fmt.parseInt(u32, mark_str[2..], 16) catch {
                        try stdout.print("Invalid fwmark: {s}\n", .{mark_str});
                        return;
                    }
                else
                    std.fmt.parseInt(u32, mark_str, 10) catch {
                        try stdout.print("Invalid fwmark: {s}\n", .{mark_str});
                        return;
                    };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "iif") and i + 1 < filtered_args.len) {
                const name = filtered_args[i + 1];
                const copy_len = @min(name.len, options.iifname.len);
                @memcpy(options.iifname[0..copy_len], name[0..copy_len]);
                options.iifname_len = copy_len;
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "oif") and i + 1 < filtered_args.len) {
                const name = filtered_args[i + 1];
                const copy_len = @min(name.len, options.oifname.len);
                @memcpy(options.oifname[0..copy_len], name[0..copy_len]);
                options.oifname_len = copy_len;
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "blackhole")) {
                options.action = ip_rule.FR_ACT.BLACKHOLE;
            } else if (std.mem.eql(u8, filtered_args[i], "unreachable")) {
                options.action = ip_rule.FR_ACT.UNREACHABLE;
            } else if (std.mem.eql(u8, filtered_args[i], "prohibit")) {
                options.action = ip_rule.FR_ACT.PROHIBIT;
            }
        }

        ip_rule.addRule(linux.AF.INET, priority, table, options) catch |err| {
            try stdout.print("Failed to add rule: {}\n", .{err});
            return;
        };

        try stdout.print("Added rule: prio {d} table {d}\n", .{ priority, table });
    } else if (std.mem.eql(u8, subcommand, "del") or std.mem.eql(u8, subcommand, "delete")) {
        // wire rule del <priority>
        if (filtered_args.len < 2) {
            try stdout.print("Usage: wire rule del <priority>\n", .{});
            try stdout.print("Example: wire rule del 100\n", .{});
            return;
        }

        const priority = std.fmt.parseInt(u32, filtered_args[1], 10) catch {
            try stdout.print("Invalid priority: {s}\n", .{filtered_args[1]});
            return;
        };

        ip_rule.deleteRule(linux.AF.INET, priority) catch |err| {
            try stdout.print("Failed to delete rule: {}\n", .{err});
            return;
        };

        try stdout.print("Deleted rule with priority {d}\n", .{priority});
    } else if (std.mem.eql(u8, subcommand, "help")) {
        try stdout.print("IP Rule commands (policy routing):\n", .{});
        try stdout.print("  rule                         Show all IP rules\n", .{});
        try stdout.print("  rule show                    Show all IP rules\n", .{});
        try stdout.print("  rule add from <prefix> ...   Add rule based on source\n", .{});
        try stdout.print("  rule add to <prefix> ...     Add rule based on destination\n", .{});
        try stdout.print("  rule add fwmark <mark> ...   Add rule based on firewall mark\n", .{});
        try stdout.print("  rule del <priority>          Delete rule by priority\n", .{});
        try stdout.print("\nOptions for add:\n", .{});
        try stdout.print("  table <name|id>    Routing table (main, local, default, or 1-252)\n", .{});
        try stdout.print("  prio <n>           Rule priority (lower = higher priority)\n", .{});
        try stdout.print("  iif <interface>    Match incoming interface\n", .{});
        try stdout.print("  oif <interface>    Match outgoing interface\n", .{});
        try stdout.print("  blackhole          Drop packets (no table lookup)\n", .{});
        try stdout.print("  unreachable        Return ICMP unreachable\n", .{});
        try stdout.print("  prohibit           Return ICMP prohibited\n", .{});
    } else {
        try stdout.print("Unknown rule subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, add, del, help\n", .{});
    }
}

