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

pub fn handleTunnel(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    // Filter out --json flag (JSON output not yet implemented for tunnel commands)
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    if (filtered_args.len < 1) {
        try stdout.print("Usage: wire tunnel <type> <name> [options...]\n", .{});
        try stdout.print("\nOverlay Tunnels:\n", .{});
        try stdout.print("  vxlan <name> vni <id> [local <ip>] [group <ip>] [port <port>]\n", .{});
        try stdout.print("  geneve <name> vni <id> [remote <ip>] [port <port>]\n", .{});
        try stdout.print("\nPoint-to-Point Tunnels:\n", .{});
        try stdout.print("  gre <name> local <ip> remote <ip> [key <n>] [ttl <n>]\n", .{});
        try stdout.print("  gretap <name> local <ip> remote <ip> [key <n>]\n", .{});
        try stdout.print("  ipip <name> local <ip> remote <ip> [ttl <n>]\n", .{});
        try stdout.print("  sit <name> local <ip> remote <ip> [ttl <n>]    (IPv6-in-IPv4)\n", .{});
        try stdout.print("\nEncrypted Tunnels:\n", .{});
        try stdout.print("  wireguard <name>                  Create WireGuard interface\n", .{});
        try stdout.print("\nManagement:\n", .{});
        try stdout.print("  delete <name>                     Delete tunnel interface\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire tunnel vxlan vxlan100 vni 100 local 10.0.0.1\n", .{});
        try stdout.print("  wire tunnel geneve geneve1 vni 100 remote 10.0.0.2\n", .{});
        try stdout.print("  wire tunnel ipip tun0 local 10.0.0.1 remote 10.0.0.2\n", .{});
        try stdout.print("  wire tunnel wireguard wg0\n", .{});
        return;
    }

    const tunnel_type = filtered_args[0];

    if (std.mem.eql(u8, tunnel_type, "help")) {
        try stdout.print("Tunnel commands:\n", .{});
        try stdout.print("\n  wire tunnel vxlan <name> vni <id> [options...]\n", .{});
        try stdout.print("    VXLAN overlay network. Options: local <ip>, group <ip>, port <port>\n", .{});
        try stdout.print("\n  wire tunnel geneve <name> vni <id> [options...]\n", .{});
        try stdout.print("    GENEVE overlay network. Options: remote <ip>, port <port>, ttl <n>\n", .{});
        try stdout.print("\n  wire tunnel gre <name> local <ip> remote <ip> [options...]\n", .{});
        try stdout.print("    GRE tunnel (Layer 3). Options: key <n>, ttl <n>\n", .{});
        try stdout.print("\n  wire tunnel gretap <name> local <ip> remote <ip> [options...]\n", .{});
        try stdout.print("    GRE TAP (Layer 2 over GRE). Options: key <n>, ttl <n>\n", .{});
        try stdout.print("\n  wire tunnel ipip <name> local <ip> remote <ip> [ttl <n>]\n", .{});
        try stdout.print("    IP-in-IP tunnel (IPv4 over IPv4)\n", .{});
        try stdout.print("\n  wire tunnel sit <name> local <ip> remote <ip> [ttl <n>]\n", .{});
        try stdout.print("    SIT tunnel (IPv6 over IPv4, for 6in4 tunneling)\n", .{});
        try stdout.print("\n  wire tunnel wireguard <name>\n", .{});
        try stdout.print("    WireGuard interface (use 'wg' tool for key/peer config)\n", .{});
        try stdout.print("\n  wire tunnel delete <name>\n", .{});
        try stdout.print("    Delete a tunnel interface\n", .{});
        return;
    }

    if (std.mem.eql(u8, tunnel_type, "vxlan")) {
        // wire tunnel vxlan <name> vni <id> [local <ip>] [group <ip>] [port <port>]
        if (args.len < 4) {
            try stdout.print("Usage: wire tunnel vxlan <name> vni <id> [options...]\n", .{});
            try stdout.print("Options: local <ip>, group <ip>, port <port>, learning, nolearning\n", .{});
            return;
        }

        const name = filtered_args[1];
        var options = tunnel.VxlanOptions{};

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "vni") and i + 1 < filtered_args.len) {
                options.vni = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid VNI: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "local") and i + 1 < filtered_args.len) {
                options.local = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid local IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "group") and i + 1 < filtered_args.len) {
                options.group = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid group IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "port") and i + 1 < filtered_args.len) {
                options.port = std.fmt.parseInt(u16, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid port: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "learning")) {
                options.learning = true;
            } else if (std.mem.eql(u8, filtered_args[i], "nolearning")) {
                options.learning = false;
            }
        }

        tunnel.createVxlan(name, options) catch |err| {
            try stdout.print("Failed to create VXLAN: {s}\n", .{@errorName(err)});
            return;
        };

        try stdout.print("Created VXLAN interface: {s} (VNI {d})\n", .{ name, options.vni });
    } else if (std.mem.eql(u8, tunnel_type, "gre")) {
        // wire tunnel gre <name> local <ip> remote <ip> [key <n>]
        if (filtered_args.len < 6) {
            try stdout.print("Usage: wire tunnel gre <name> local <ip> remote <ip> [key <n>] [ttl <n>]\n", .{});
            return;
        }

        const name = filtered_args[1];
        var local_ip: ?[4]u8 = null;
        var remote_ip: ?[4]u8 = null;
        var key: ?u32 = null;
        var ttl: u8 = 64;

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "local") and i + 1 < filtered_args.len) {
                local_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid local IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "remote") and i + 1 < filtered_args.len) {
                remote_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid remote IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "key") and i + 1 < filtered_args.len) {
                key = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid key: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "ttl") and i + 1 < filtered_args.len) {
                ttl = std.fmt.parseInt(u8, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid TTL: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        if (local_ip == null or remote_ip == null) {
            try stdout.print("Both local and remote IP addresses are required.\n", .{});
            return;
        }

        const options = tunnel.GreOptions{
            .local = local_ip.?,
            .remote = remote_ip.?,
            .key = key,
            .ttl = ttl,
        };

        tunnel.createGre(name, options) catch |err| {
            try stdout.print("Failed to create GRE tunnel: {s}\n", .{@errorName(err)});
            return;
        };

        var local_buf: [16]u8 = undefined;
        var remote_buf: [16]u8 = undefined;
        const local_str = tunnel.formatIPv4(local_ip.?, &local_buf) catch "?";
        const remote_str = tunnel.formatIPv4(remote_ip.?, &remote_buf) catch "?";
        try stdout.print("Created GRE tunnel: {s} ({s} -> {s})\n", .{ name, local_str, remote_str });
    } else if (std.mem.eql(u8, tunnel_type, "gretap")) {
        // wire tunnel gretap <name> local <ip> remote <ip> [key <n>]
        if (filtered_args.len < 6) {
            try stdout.print("Usage: wire tunnel gretap <name> local <ip> remote <ip> [key <n>]\n", .{});
            return;
        }

        const name = filtered_args[1];
        var local_ip: ?[4]u8 = null;
        var remote_ip: ?[4]u8 = null;
        var key: ?u32 = null;

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "local") and i + 1 < filtered_args.len) {
                local_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid local IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "remote") and i + 1 < filtered_args.len) {
                remote_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid remote IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "key") and i + 1 < filtered_args.len) {
                key = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid key: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        if (local_ip == null or remote_ip == null) {
            try stdout.print("Both local and remote IP addresses are required.\n", .{});
            return;
        }

        const options = tunnel.GreOptions{
            .local = local_ip.?,
            .remote = remote_ip.?,
            .key = key,
        };

        tunnel.createGretap(name, options) catch |err| {
            try stdout.print("Failed to create GRE TAP: {s}\n", .{@errorName(err)});
            return;
        };

        var local_buf: [16]u8 = undefined;
        var remote_buf: [16]u8 = undefined;
        const local_str = tunnel.formatIPv4(local_ip.?, &local_buf) catch "?";
        const remote_str = tunnel.formatIPv4(remote_ip.?, &remote_buf) catch "?";
        try stdout.print("Created GRE TAP: {s} ({s} -> {s})\n", .{ name, local_str, remote_str });
    } else if (std.mem.eql(u8, tunnel_type, "geneve")) {
        // wire tunnel geneve <name> vni <id> [remote <ip>] [port <port>]
        if (filtered_args.len < 4) {
            try stdout.print("Usage: wire tunnel geneve <name> vni <id> [remote <ip>] [port <port>]\n", .{});
            return;
        }

        const name = filtered_args[1];
        var options = tunnel.GeneveOptions{};

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "vni") and i + 1 < filtered_args.len) {
                options.vni = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid VNI: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "remote") and i + 1 < filtered_args.len) {
                options.remote = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid remote IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "port") and i + 1 < filtered_args.len) {
                options.port = std.fmt.parseInt(u16, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid port: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "ttl") and i + 1 < filtered_args.len) {
                options.ttl = std.fmt.parseInt(u8, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid TTL: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        tunnel.createGeneve(name, options) catch |err| {
            try stdout.print("Failed to create GENEVE tunnel: {s}\n", .{@errorName(err)});
            return;
        };

        try stdout.print("Created GENEVE tunnel: {s} (VNI {d}, port {d})\n", .{ name, options.vni, options.port });
    } else if (std.mem.eql(u8, tunnel_type, "ipip")) {
        // wire tunnel ipip <name> local <ip> remote <ip>
        if (filtered_args.len < 6) {
            try stdout.print("Usage: wire tunnel ipip <name> local <ip> remote <ip> [ttl <n>]\n", .{});
            return;
        }

        const name = filtered_args[1];
        var local_ip: ?[4]u8 = null;
        var remote_ip: ?[4]u8 = null;
        var ttl: u8 = 64;

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "local") and i + 1 < filtered_args.len) {
                local_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid local IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "remote") and i + 1 < filtered_args.len) {
                remote_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid remote IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "ttl") and i + 1 < filtered_args.len) {
                ttl = std.fmt.parseInt(u8, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid TTL: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        if (local_ip == null or remote_ip == null) {
            try stdout.print("Both local and remote IP addresses are required.\n", .{});
            return;
        }

        const options = tunnel.IpipOptions{
            .local = local_ip.?,
            .remote = remote_ip.?,
            .ttl = ttl,
        };

        tunnel.createIpip(name, options) catch |err| {
            try stdout.print("Failed to create IP-in-IP tunnel: {s}\n", .{@errorName(err)});
            return;
        };

        var local_buf: [16]u8 = undefined;
        var remote_buf: [16]u8 = undefined;
        const local_str = tunnel.formatIPv4(local_ip.?, &local_buf) catch "?";
        const remote_str = tunnel.formatIPv4(remote_ip.?, &remote_buf) catch "?";
        try stdout.print("Created IP-in-IP tunnel: {s} ({s} -> {s})\n", .{ name, local_str, remote_str });
    } else if (std.mem.eql(u8, tunnel_type, "sit")) {
        // wire tunnel sit <name> local <ip> remote <ip>
        if (filtered_args.len < 6) {
            try stdout.print("Usage: wire tunnel sit <name> local <ip> remote <ip> [ttl <n>]\n", .{});
            return;
        }

        const name = filtered_args[1];
        var local_ip: ?[4]u8 = null;
        var remote_ip: ?[4]u8 = null;
        var ttl: u8 = 64;

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "local") and i + 1 < filtered_args.len) {
                local_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid local IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "remote") and i + 1 < filtered_args.len) {
                remote_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid remote IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "ttl") and i + 1 < args.len) {
                ttl = std.fmt.parseInt(u8, args[i + 1], 10) catch {
                    try stdout.print("Invalid TTL: {s}\n", .{args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        if (local_ip == null or remote_ip == null) {
            try stdout.print("Both local and remote IP addresses are required.\n", .{});
            return;
        }

        const options = tunnel.IpipOptions{
            .local = local_ip.?,
            .remote = remote_ip.?,
            .ttl = ttl,
        };

        tunnel.createSit(name, options) catch |err| {
            try stdout.print("Failed to create SIT tunnel: {s}\n", .{@errorName(err)});
            return;
        };

        var local_buf: [16]u8 = undefined;
        var remote_buf: [16]u8 = undefined;
        const local_str = tunnel.formatIPv4(local_ip.?, &local_buf) catch "?";
        const remote_str = tunnel.formatIPv4(remote_ip.?, &remote_buf) catch "?";
        try stdout.print("Created SIT tunnel: {s} ({s} -> {s})\n", .{ name, local_str, remote_str });
    } else if (std.mem.eql(u8, tunnel_type, "wireguard") or std.mem.eql(u8, tunnel_type, "wg")) {
        // wire tunnel wireguard <name>
        if (args.len < 2) {
            try stdout.print("Usage: wire tunnel wireguard <name>\n", .{});
            try stdout.print("\nNote: This creates the interface only. Use 'wg' tool for peer configuration.\n", .{});
            return;
        }

        const name = args[1];

        tunnel.createWireguard(name) catch |err| {
            try stdout.print("Failed to create WireGuard interface: {s}\n", .{@errorName(err)});
            return;
        };

        try stdout.print("Created WireGuard interface: {s}\n", .{name});
        try stdout.print("Use 'wg set {s} ...' to configure keys and peers\n", .{name});
    } else if (std.mem.eql(u8, tunnel_type, "delete") or std.mem.eql(u8, tunnel_type, "del")) {
        // wire tunnel delete <name>
        if (args.len < 2) {
            try stdout.print("Usage: wire tunnel delete <name>\n", .{});
            return;
        }

        const name = args[1];
        tunnel.deleteTunnel(name) catch |err| {
            try stdout.print("Failed to delete tunnel: {s}\n", .{@errorName(err)});
            return;
        };

        try stdout.print("Deleted tunnel: {s}\n", .{name});
    } else {
        try stdout.print("Unknown tunnel type: {s}\n", .{tunnel_type});
        try stdout.print("Available: vxlan, gre, gretap, geneve, ipip, sit, wireguard, delete\n", .{});
    }
}

