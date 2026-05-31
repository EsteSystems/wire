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

const IPWithMask = struct {
    ip: [4]u8,
    mask: [4]u8,
};

const version = "1.0.0";

pub fn handleTc(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    if (filtered_args.len < 1) {
        try stdout.print("Usage: wire tc <interface> [show|add|del|class|filter]\n", .{});
        try stdout.print("\nQdisc Commands:\n", .{});
        try stdout.print("  wire tc <interface>                      Show qdiscs\n", .{});
        try stdout.print("  wire tc <interface> add pfifo [limit <n>]\n", .{});
        try stdout.print("  wire tc <interface> add fq_codel          Fair queuing with CoDel\n", .{});
        try stdout.print("  wire tc <interface> add tbf rate <bps> burst <bytes> [latency <us>]\n", .{});
        try stdout.print("  wire tc <interface> add htb [default <class>]  Hierarchical Token Bucket\n", .{});
        try stdout.print("  wire tc <interface> del                   Delete root qdisc\n", .{});
        try stdout.print("\nClass Commands (for HTB):\n", .{});
        try stdout.print("  wire tc <interface> class                 Show classes\n", .{});
        try stdout.print("  wire tc <interface> class add <id> rate <r> [ceil <r>] [prio <n>]\n", .{});
        try stdout.print("  wire tc <interface> class del <id>        Delete class\n", .{});
        try stdout.print("\nFilter Commands:\n", .{});
        try stdout.print("  wire tc <interface> filter                Show filters\n", .{});
        try stdout.print("  wire tc <interface> filter add u32 match ip dst <ip/mask> flowid <id>\n", .{});
        try stdout.print("  wire tc <interface> filter add fw handle <mark> classid <id>\n", .{});
        try stdout.print("  wire tc <interface> filter del prio <n>   Delete filter\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire tc eth0 add htb default 10           HTB for class-based shaping\n", .{});
        try stdout.print("  wire tc eth0 class add 1:10 rate 10mbit   Add class with 10mbit rate\n", .{});
        try stdout.print("  wire tc eth0 filter add u32 match ip dst 10.0.0.0/8 flowid 1:10\n", .{});
        return;
    }

    const iface_name = filtered_args[0];

    if (std.mem.eql(u8, iface_name, "help")) {
        try stdout.print("Traffic Control (tc) commands:\n", .{});
        try stdout.print("\n  wire tc <interface>                Show qdiscs on interface\n", .{});
        try stdout.print("\n  wire tc <interface> add <type> [options]\n", .{});
        try stdout.print("    Types:\n", .{});
        try stdout.print("      pfifo                          Simple FIFO queue\n", .{});
        try stdout.print("      fq_codel                       Fair queuing + CoDel AQM\n", .{});
        try stdout.print("      tbf rate <r> burst <b>         Token bucket for rate limiting\n", .{});
        try stdout.print("      htb [default <class>]          Hierarchical Token Bucket (for classes)\n", .{});
        try stdout.print("\n  wire tc <interface> del            Delete root qdisc\n", .{});
        try stdout.print("\n  wire tc <interface> class          Show classes on interface\n", .{});
        try stdout.print("  wire tc <interface> class add <classid> rate <r> [ceil <r>] [prio <n>]\n", .{});
        try stdout.print("  wire tc <interface> class del <classid>\n", .{});
        try stdout.print("\n  wire tc <interface> filter         Show filters on interface\n", .{});
        try stdout.print("  wire tc <interface> filter add u32 match ip dst <ip/mask> flowid <classid>\n", .{});
        try stdout.print("  wire tc <interface> filter add fw handle <mark> classid <classid>\n", .{});
        try stdout.print("  wire tc <interface> filter del prio <n>\n", .{});
        try stdout.print("\nClass/filter IDs: format is major:minor (e.g., 1:10, 1:20)\n", .{});
        try stdout.print("Rate units: bps, kbit, mbit, gbit\n", .{});
        return;
    }

    // Get interface index
    const maybe_iface = netlink_interface.getInterfaceByName(allocator, iface_name) catch |err| {
        try stdout.print("Failed to find interface: {}\n", .{err});
        return;
    };

    if (maybe_iface == null) {
        try stdout.print("Interface not found: {s}\n", .{iface_name});
        return;
    }

    const if_index = maybe_iface.?.index;

    // Default to show
    var subcommand: []const u8 = "show";
    if (filtered_args.len > 1) {
        subcommand = filtered_args[1];
    }

    if (std.mem.eql(u8, subcommand, "show")) {
        // wire tc <interface> show
        const qdiscs = qdisc.getQdiscs(allocator, if_index) catch |err| {
            try stdout.print("Failed to get qdiscs: {}\n", .{err});
            return;
        };
        defer allocator.free(qdiscs);

        if (use_json) {
            var json = json_output.JsonOutput.init(allocator, stdout);
            try json.writeQdiscs(qdiscs);
            return;
        }

        if (qdiscs.len == 0) {
            try stdout.print("No qdiscs found on {s}\n", .{iface_name});
            return;
        }

        try stdout.print("Qdiscs on {s}:\n", .{iface_name});
        try stdout.print("{s:<12} {s:<12} {s:<12}\n", .{ "Handle", "Parent", "Type" });
        try stdout.print("{s:-<12} {s:-<12} {s:-<12}\n", .{ "", "", "" });

        for (qdiscs) |*q| {
            var handle_buf: [16]u8 = undefined;
            var parent_buf: [16]u8 = undefined;
            const handle_str = q.formatHandle(&handle_buf) catch "?";
            const parent_str = q.formatParent(&parent_buf) catch "?";

            try stdout.print("{s:<12} {s:<12} {s:<12}\n", .{
                handle_str,
                parent_str,
                q.getKind(),
            });
        }
    } else if (std.mem.eql(u8, subcommand, "add")) {
        // wire tc <interface> add <type> [options]
        if (filtered_args.len < 3) {
            try stdout.print("Usage: wire tc <interface> add <type> [options]\n", .{});
            try stdout.print("Types: pfifo, fq_codel, tbf, htb\n", .{});
            return;
        }

        const qdisc_type = filtered_args[2];

        if (std.mem.eql(u8, qdisc_type, "pfifo")) {
            // wire tc <interface> add pfifo [limit <n>]
            var limit: ?u32 = null;
            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "limit") and i + 1 < filtered_args.len) {
                    limit = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid limit: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            qdisc.addPfifoQdisc(if_index, qdisc.TC_H.make(1, 0), qdisc.TC_H.ROOT, limit) catch |err| {
                try stdout.print("Failed to add pfifo qdisc: {}\n", .{err});
                return;
            };

            try stdout.print("Added pfifo qdisc to {s}\n", .{iface_name});
        } else if (std.mem.eql(u8, qdisc_type, "fq_codel")) {
            // wire tc <interface> add fq_codel
            qdisc.addFqCodelQdisc(if_index, qdisc.TC_H.make(1, 0), qdisc.TC_H.ROOT) catch |err| {
                try stdout.print("Failed to add fq_codel qdisc: {}\n", .{err});
                return;
            };

            try stdout.print("Added fq_codel qdisc to {s}\n", .{iface_name});
        } else if (std.mem.eql(u8, qdisc_type, "tbf")) {
            // wire tc <interface> add tbf rate <bps> burst <bytes> [latency <us>]
            var rate_bps: ?u64 = null;
            var burst: ?u32 = null;
            var latency_us: u32 = 50000; // 50ms default

            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "rate") and i + 1 < filtered_args.len) {
                    rate_bps = parseRate(filtered_args[i + 1]) orelse {
                        try stdout.print("Invalid rate: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "burst") and i + 1 < filtered_args.len) {
                    burst = parseSize(filtered_args[i + 1]) orelse {
                        try stdout.print("Invalid burst: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "latency") and i + 1 < filtered_args.len) {
                    latency_us = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid latency: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            if (rate_bps == null or burst == null) {
                try stdout.print("Both rate and burst are required for tbf.\n", .{});
                try stdout.print("Example: wire tc eth0 add tbf rate 10mbit burst 32k\n", .{});
                return;
            }

            qdisc.addTbfQdisc(if_index, qdisc.TC_H.make(1, 0), qdisc.TC_H.ROOT, rate_bps.?, burst.?, latency_us) catch |err| {
                try stdout.print("Failed to add tbf qdisc: {}\n", .{err});
                return;
            };

            try stdout.print("Added tbf qdisc to {s} (rate {d} bps, burst {d} bytes)\n", .{ iface_name, rate_bps.?, burst.? });
        } else if (std.mem.eql(u8, qdisc_type, "htb")) {
            // wire tc <interface> add htb [default <classid>]
            var default_class: ?u32 = null;

            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "default") and i + 1 < filtered_args.len) {
                    default_class = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid default class: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            qdisc.addHtbQdisc(if_index, qdisc.TC_H.make(1, 0), qdisc.TC_H.ROOT, default_class) catch |err| {
                try stdout.print("Failed to add htb qdisc: {}\n", .{err});
                return;
            };

            if (default_class) |dc| {
                try stdout.print("Added htb qdisc to {s} (default class 1:{d})\n", .{ iface_name, dc });
            } else {
                try stdout.print("Added htb qdisc to {s}\n", .{iface_name});
            }
        } else {
            try stdout.print("Unknown qdisc type: {s}\n", .{qdisc_type});
            try stdout.print("Available: pfifo, fq_codel, tbf, htb\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "del") or std.mem.eql(u8, subcommand, "delete")) {
        // wire tc <interface> del
        qdisc.deleteQdisc(if_index, qdisc.TC_H.make(1, 0), qdisc.TC_H.ROOT) catch |err| {
            try stdout.print("Failed to delete qdisc: {}\n", .{err});
            return;
        };

        try stdout.print("Deleted root qdisc from {s}\n", .{iface_name});
    } else if (std.mem.eql(u8, subcommand, "class")) {
        // wire tc <interface> class [show|add|del]
        var class_cmd: []const u8 = "show";
        if (filtered_args.len > 2) {
            class_cmd = filtered_args[2];
        }

        if (std.mem.eql(u8, class_cmd, "show")) {
            // wire tc <interface> class show
            const classes = qdisc.getClasses(allocator, if_index) catch |err| {
                try stdout.print("Failed to get classes: {}\n", .{err});
                return;
            };
            defer allocator.free(classes);

            if (classes.len == 0) {
                try stdout.print("No classes found on {s}\n", .{iface_name});
                return;
            }

            try stdout.print("Classes on {s}:\n", .{iface_name});
            try stdout.print("{s:<12} {s:<12} {s:<12}\n", .{ "Class ID", "Parent", "Type" });
            try stdout.print("{s:-<12} {s:-<12} {s:-<12}\n", .{ "", "", "" });

            for (classes) |*c| {
                var handle_buf: [16]u8 = undefined;
                var parent_buf: [16]u8 = undefined;
                const handle_str = c.formatHandle(&handle_buf) catch "?";
                const parent_str = c.formatParent(&parent_buf) catch "?";

                try stdout.print("{s:<12} {s:<12} {s:<12}\n", .{
                    handle_str,
                    parent_str,
                    c.getKind(),
                });
            }
        } else if (std.mem.eql(u8, class_cmd, "add")) {
            // wire tc <interface> class add <classid> rate <rate> [ceil <rate>] [prio <n>]
            if (filtered_args.len < 6) {
                try stdout.print("Usage: wire tc <interface> class add <classid> rate <rate> [ceil <rate>] [prio <n>]\n", .{});
                try stdout.print("\nOptions:\n", .{});
                try stdout.print("  classid   Class ID in format major:minor (e.g., 1:10)\n", .{});
                try stdout.print("  rate      Guaranteed rate (e.g., 10mbit, 1gbit)\n", .{});
                try stdout.print("  ceil      Maximum rate (defaults to rate)\n", .{});
                try stdout.print("  prio      Priority 0-7 (lower = higher priority)\n", .{});
                try stdout.print("\nExample:\n", .{});
                try stdout.print("  wire tc eth0 class add 1:10 rate 10mbit ceil 100mbit prio 1\n", .{});
                return;
            }

            const classid_str = filtered_args[3];
            const classid = parseClassId(classid_str) orelse {
                try stdout.print("Invalid class ID: {s}\n", .{classid_str});
                try stdout.print("Expected format: major:minor (e.g., 1:10)\n", .{});
                return;
            };

            var rate_bps: ?u64 = null;
            var ceil_bps: u64 = 0;
            var prio: u32 = 0;
            var parent = qdisc.TC_H.make(1, 0); // Default parent is root qdisc 1:0

            var i: usize = 4;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "rate") and i + 1 < filtered_args.len) {
                    rate_bps = parseRate(filtered_args[i + 1]) orelse {
                        try stdout.print("Invalid rate: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "ceil") and i + 1 < filtered_args.len) {
                    ceil_bps = parseRate(filtered_args[i + 1]) orelse {
                        try stdout.print("Invalid ceil: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "prio") and i + 1 < filtered_args.len) {
                    prio = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid priority: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "parent") and i + 1 < filtered_args.len) {
                    parent = parseClassId(filtered_args[i + 1]) orelse {
                        try stdout.print("Invalid parent: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            if (rate_bps == null) {
                try stdout.print("Rate is required for class.\n", .{});
                try stdout.print("Example: wire tc eth0 class add 1:10 rate 10mbit\n", .{});
                return;
            }

            qdisc.addHtbClass(if_index, classid, parent, rate_bps.?, ceil_bps, prio) catch |err| {
                try stdout.print("Failed to add class: {}\n", .{err});
                return;
            };

            const major = qdisc.TC_H.getMajor(classid);
            const minor = qdisc.TC_H.getMinor(classid);
            try stdout.print("Added HTB class {d}:{d} on {s} (rate {d} bps)\n", .{ major, minor, iface_name, rate_bps.? });
        } else if (std.mem.eql(u8, class_cmd, "del") or std.mem.eql(u8, class_cmd, "delete")) {
            // wire tc <interface> class del <classid>
            if (filtered_args.len < 4) {
                try stdout.print("Usage: wire tc <interface> class del <classid>\n", .{});
                try stdout.print("Example: wire tc eth0 class del 1:10\n", .{});
                return;
            }

            const classid_str = filtered_args[3];
            const classid = parseClassId(classid_str) orelse {
                try stdout.print("Invalid class ID: {s}\n", .{classid_str});
                try stdout.print("Expected format: major:minor (e.g., 1:10)\n", .{});
                return;
            };

            qdisc.deleteClass(if_index, classid) catch |err| {
                try stdout.print("Failed to delete class: {}\n", .{err});
                return;
            };

            const major = qdisc.TC_H.getMajor(classid);
            const minor = qdisc.TC_H.getMinor(classid);
            try stdout.print("Deleted class {d}:{d} from {s}\n", .{ major, minor, iface_name });
        } else {
            try stdout.print("Unknown class subcommand: {s}\n", .{class_cmd});
            try stdout.print("Available: show, add, del\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "filter")) {
        // wire tc <interface> filter [show|add|del]
        var filter_cmd: []const u8 = "show";
        if (filtered_args.len > 2) {
            filter_cmd = filtered_args[2];
        }

        if (std.mem.eql(u8, filter_cmd, "show")) {
            // wire tc <interface> filter show
            const filters = qdisc.getFilters(allocator, if_index, qdisc.TC_H.make(1, 0)) catch |err| {
                try stdout.print("Failed to get filters: {}\n", .{err});
                return;
            };
            defer allocator.free(filters);

            if (filters.len == 0) {
                try stdout.print("No filters found on {s}\n", .{iface_name});
                return;
            }

            try stdout.print("Filters on {s}:\n", .{iface_name});
            try stdout.print("{s:<12} {s:<12} {s:<8} {s:<8} {s:<8}\n", .{ "Handle", "Parent", "Prio", "Proto", "Type" });
            try stdout.print("{s:-<12} {s:-<12} {s:-<8} {s:-<8} {s:-<8}\n", .{ "", "", "", "", "" });

            for (filters) |*f| {
                var handle_buf: [16]u8 = undefined;
                var parent_buf: [16]u8 = undefined;
                const handle_str = f.formatHandle(&handle_buf) catch "?";
                const parent_str = f.formatParent(&parent_buf) catch "?";

                const proto_str = switch (std.mem.bigToNative(u16, f.protocol)) {
                    qdisc.ETH_P.IP => "ip",
                    qdisc.ETH_P.IPV6 => "ipv6",
                    qdisc.ETH_P.ARP => "arp",
                    qdisc.ETH_P.ALL => "all",
                    else => "?",
                };

                try stdout.print("{s:<12} {s:<12} {d:<8} {s:<8} {s:<8}\n", .{
                    handle_str,
                    parent_str,
                    f.priority,
                    proto_str,
                    f.getKind(),
                });
            }
        } else if (std.mem.eql(u8, filter_cmd, "add")) {
            // wire tc <interface> filter add <type> ...
            if (filtered_args.len < 4) {
                try stdout.print("Usage: wire tc <interface> filter add <type> [options]\n", .{});
                try stdout.print("\nFilter types:\n", .{});
                try stdout.print("  u32 match ip dst <ip/mask> flowid <classid> [prio <n>]\n", .{});
                try stdout.print("  fw handle <mark> classid <classid> [prio <n>]\n", .{});
                try stdout.print("\nExamples:\n", .{});
                try stdout.print("  wire tc eth0 filter add u32 match ip dst 10.0.0.0/8 flowid 1:10\n", .{});
                try stdout.print("  wire tc eth0 filter add fw handle 1 classid 1:20 prio 1\n", .{});
                return;
            }

            const filter_type = filtered_args[3];

            if (std.mem.eql(u8, filter_type, "u32")) {
                // wire tc <interface> filter add u32 match ip dst <ip/mask> flowid <classid>
                var dst_ip: ?[4]u8 = null;
                var dst_mask: [4]u8 = .{ 255, 255, 255, 255 };
                var flowid: ?u32 = null;
                var prio: u16 = 1;

                var i: usize = 4;
                while (i < filtered_args.len) : (i += 1) {
                    if (std.mem.eql(u8, filtered_args[i], "match") and i + 4 < filtered_args.len) {
                        if (std.mem.eql(u8, filtered_args[i + 1], "ip") and std.mem.eql(u8, filtered_args[i + 2], "dst")) {
                            const ip_mask = parseIPWithMask(filtered_args[i + 3]);
                            if (ip_mask) |im| {
                                dst_ip = im.ip;
                                dst_mask = im.mask;
                            } else {
                                try stdout.print("Invalid IP/mask: {s}\n", .{filtered_args[i + 3]});
                                return;
                            }
                            i += 3;
                        }
                    } else if (std.mem.eql(u8, filtered_args[i], "flowid") and i + 1 < filtered_args.len) {
                        flowid = parseClassId(filtered_args[i + 1]) orelse {
                            try stdout.print("Invalid flowid: {s}\n", .{filtered_args[i + 1]});
                            return;
                        };
                        i += 1;
                    } else if (std.mem.eql(u8, filtered_args[i], "prio") and i + 1 < filtered_args.len) {
                        prio = std.fmt.parseInt(u16, filtered_args[i + 1], 10) catch {
                            try stdout.print("Invalid priority: {s}\n", .{filtered_args[i + 1]});
                            return;
                        };
                        i += 1;
                    }
                }

                if (dst_ip == null or flowid == null) {
                    try stdout.print("Missing required options.\n", .{});
                    try stdout.print("Example: wire tc eth0 filter add u32 match ip dst 10.0.0.0/8 flowid 1:10\n", .{});
                    return;
                }

                qdisc.addU32FilterDstIP(if_index, qdisc.TC_H.make(1, 0), prio, dst_ip.?, dst_mask, flowid.?) catch |err| {
                    try stdout.print("Failed to add filter: {}\n", .{err});
                    return;
                };

                const major = qdisc.TC_H.getMajor(flowid.?);
                const minor = qdisc.TC_H.getMinor(flowid.?);
                try stdout.print("Added u32 filter on {s} -> class {d}:{d}\n", .{ iface_name, major, minor });
            } else if (std.mem.eql(u8, filter_type, "fw")) {
                // wire tc <interface> filter add fw handle <mark> classid <classid>
                var fwmark: ?u32 = null;
                var classid: ?u32 = null;
                var prio: u16 = 1;

                var i: usize = 4;
                while (i < filtered_args.len) : (i += 1) {
                    if (std.mem.eql(u8, filtered_args[i], "handle") and i + 1 < filtered_args.len) {
                        const mark_str = filtered_args[i + 1];
                        fwmark = if (mark_str.len > 2 and std.mem.eql(u8, mark_str[0..2], "0x"))
                            std.fmt.parseInt(u32, mark_str[2..], 16) catch {
                                try stdout.print("Invalid handle: {s}\n", .{mark_str});
                                return;
                            }
                        else
                            std.fmt.parseInt(u32, mark_str, 10) catch {
                                try stdout.print("Invalid handle: {s}\n", .{mark_str});
                                return;
                            };
                        i += 1;
                    } else if (std.mem.eql(u8, filtered_args[i], "classid") and i + 1 < filtered_args.len) {
                        classid = parseClassId(filtered_args[i + 1]) orelse {
                            try stdout.print("Invalid classid: {s}\n", .{filtered_args[i + 1]});
                            return;
                        };
                        i += 1;
                    } else if (std.mem.eql(u8, filtered_args[i], "prio") and i + 1 < filtered_args.len) {
                        prio = std.fmt.parseInt(u16, filtered_args[i + 1], 10) catch {
                            try stdout.print("Invalid priority: {s}\n", .{filtered_args[i + 1]});
                            return;
                        };
                        i += 1;
                    }
                }

                if (fwmark == null or classid == null) {
                    try stdout.print("Missing required options.\n", .{});
                    try stdout.print("Example: wire tc eth0 filter add fw handle 1 classid 1:20\n", .{});
                    return;
                }

                qdisc.addFwFilter(if_index, qdisc.TC_H.make(1, 0), prio, fwmark.?, classid.?) catch |err| {
                    try stdout.print("Failed to add filter: {}\n", .{err});
                    return;
                };

                const major = qdisc.TC_H.getMajor(classid.?);
                const minor = qdisc.TC_H.getMinor(classid.?);
                try stdout.print("Added fw filter on {s}: mark {d} -> class {d}:{d}\n", .{ iface_name, fwmark.?, major, minor });
            } else {
                try stdout.print("Unknown filter type: {s}\n", .{filter_type});
                try stdout.print("Available: u32, fw\n", .{});
            }
        } else if (std.mem.eql(u8, filter_cmd, "del") or std.mem.eql(u8, filter_cmd, "delete")) {
            // wire tc <interface> filter del prio <n> [handle <h>]
            if (filtered_args.len < 5) {
                try stdout.print("Usage: wire tc <interface> filter del prio <n> [handle <h>]\n", .{});
                try stdout.print("Example: wire tc eth0 filter del prio 1\n", .{});
                return;
            }

            var prio: ?u16 = null;
            var handle: u32 = 0;

            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "prio") and i + 1 < filtered_args.len) {
                    prio = std.fmt.parseInt(u16, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid priority: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "handle") and i + 1 < filtered_args.len) {
                    const h_str = filtered_args[i + 1];
                    handle = if (h_str.len > 2 and std.mem.eql(u8, h_str[0..2], "0x"))
                        std.fmt.parseInt(u32, h_str[2..], 16) catch {
                            try stdout.print("Invalid handle: {s}\n", .{h_str});
                            return;
                        }
                    else
                        std.fmt.parseInt(u32, h_str, 10) catch {
                            try stdout.print("Invalid handle: {s}\n", .{h_str});
                            return;
                        };
                    i += 1;
                }
            }

            if (prio == null) {
                try stdout.print("Priority is required.\n", .{});
                try stdout.print("Example: wire tc eth0 filter del prio 1\n", .{});
                return;
            }

            qdisc.deleteFilter(if_index, qdisc.TC_H.make(1, 0), prio.?, handle, qdisc.ETH_P.IP) catch |err| {
                try stdout.print("Failed to delete filter: {}\n", .{err});
                return;
            };

            try stdout.print("Deleted filter with priority {d} from {s}\n", .{ prio.?, iface_name });
        } else {
            try stdout.print("Unknown filter subcommand: {s}\n", .{filter_cmd});
            try stdout.print("Available: show, add, del\n", .{});
        }
    } else {
        try stdout.print("Unknown tc subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, add, del, class, filter\n", .{});
    }
}

fn parseRate(s: []const u8) ?u64 {
    // Try to find unit suffix
    var num_end: usize = s.len;
    var multiplier: u64 = 1;

    for (s, 0..) |c, i| {
        if ((c < '0' or c > '9') and c != '.') {
            num_end = i;
            break;
        }
    }

    const num_str = s[0..num_end];
    const unit = s[num_end..];

    // Parse number
    const num = std.fmt.parseFloat(f64, num_str) catch return null;

    // Parse unit
    if (unit.len == 0 or std.mem.eql(u8, unit, "bps")) {
        multiplier = 1;
    } else if (std.mem.eql(u8, unit, "kbit") or std.mem.eql(u8, unit, "kbps")) {
        multiplier = 1000;
    } else if (std.mem.eql(u8, unit, "mbit") or std.mem.eql(u8, unit, "mbps")) {
        multiplier = 1_000_000;
    } else if (std.mem.eql(u8, unit, "gbit") or std.mem.eql(u8, unit, "gbps")) {
        multiplier = 1_000_000_000;
    } else {
        return null;
    }

    return @intFromFloat(num * @as(f64, @floatFromInt(multiplier)));
}
fn parseSize(s: []const u8) ?u32 {
    var num_end: usize = s.len;
    var multiplier: u32 = 1;

    for (s, 0..) |c, i| {
        if (c < '0' or c > '9') {
            num_end = i;
            break;
        }
    }

    const num_str = s[0..num_end];
    const unit = s[num_end..];

    const num = std.fmt.parseInt(u32, num_str, 10) catch return null;

    if (unit.len == 0) {
        multiplier = 1;
    } else if (std.mem.eql(u8, unit, "k") or std.mem.eql(u8, unit, "K")) {
        multiplier = 1024;
    } else if (std.mem.eql(u8, unit, "m") or std.mem.eql(u8, unit, "M")) {
        multiplier = 1024 * 1024;
    } else {
        return null;
    }

    return num * multiplier;
}
fn parseClassId(s: []const u8) ?u32 {
    // Find the colon
    var colon_pos: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == ':') {
            colon_pos = i;
            break;
        }
    }

    if (colon_pos) |pos| {
        const major_str = s[0..pos];
        const minor_str = s[pos + 1 ..];

        const major = std.fmt.parseInt(u16, major_str, 10) catch return null;
        const minor = if (minor_str.len > 0)
            std.fmt.parseInt(u16, minor_str, 10) catch return null
        else
            0;

        return qdisc.TC_H.make(major, minor);
    } else {
        // No colon, try parsing as a simple number (minor only, major 1)
        const minor = std.fmt.parseInt(u16, s, 10) catch return null;
        return qdisc.TC_H.make(1, minor);
    }
}

/// Parse IP address with optional CIDR mask (e.g., "10.0.0.0/8" or "192.168.1.1")
fn parseIPWithMask(s: []const u8) ?IPWithMask {
    // Find slash for CIDR notation
    var slash_pos: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == '/') {
            slash_pos = i;
            break;
        }
    }

    const ip_str = if (slash_pos) |pos| s[0..pos] else s;
    const mask_len: u8 = if (slash_pos) |pos|
        std.fmt.parseInt(u8, s[pos + 1 ..], 10) catch return null
    else
        32;

    // Parse IP address
    var ip: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var octet_start: usize = 0;

    for (ip_str, 0..) |c, i| {
        if (c == '.') {
            if (octet_idx >= 3) return null;
            ip[octet_idx] = std.fmt.parseInt(u8, ip_str[octet_start..i], 10) catch return null;
            octet_idx += 1;
            octet_start = i + 1;
        }
    }

    if (octet_idx != 3) return null;
    ip[3] = std.fmt.parseInt(u8, ip_str[octet_start..], 10) catch return null;

    // Calculate mask from CIDR length
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    var remaining = mask_len;
    for (0..4) |i| {
        if (remaining >= 8) {
            mask[i] = 255;
            remaining -= 8;
        } else if (remaining > 0) {
            mask[i] = @as(u8, 0xFF) << @intCast(8 - remaining);
            remaining = 0;
        }
    }

    return IPWithMask{ .ip = ip, .mask = mask };
}
