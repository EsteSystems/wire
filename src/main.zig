const std = @import("std");
const netlink_interface = @import("netlink/interface.zig");
const netlink_address = @import("netlink/address.zig");
const netlink_route = @import("netlink/route.zig");
const linux = std.os.linux;

const version = "0.1.0-dev";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try printVersion();
        return;
    }

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
        return;
    }

    // Execute command
    executeCommand(allocator, args[1..]) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: {}\n", .{err});
        std.process.exit(1);
    };
}

fn executeCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printUsage();
        return;
    }

    const subject = args[0];

    if (std.mem.eql(u8, subject, "interface")) {
        try handleInterface(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "route")) {
        try handleRoute(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "analyze")) {
        try handleAnalyze(allocator);
    } else {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Unknown command: {s}\n", .{subject});
        try stderr.print("Run 'wire --help' for usage.\n", .{});
    }
}

fn handleInterface(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // wire interface (list all)
    if (args.len == 0) {
        const interfaces = try netlink_interface.getInterfaces(allocator);
        defer allocator.free(interfaces);

        for (interfaces) |iface| {
            const state = if (iface.isUp()) "UP" else "DOWN";
            const carrier = if (iface.hasCarrier()) "CARRIER" else "NO-CARRIER";

            try stdout.print("{d}: {s}: <{s},{s}> mtu {d}\n", .{
                iface.index,
                iface.getName(),
                state,
                carrier,
                iface.mtu,
            });

            if (iface.has_mac) {
                const mac = iface.formatMac();
                try stdout.print("    link/ether {s}\n", .{mac});
            }

            // Get addresses for this interface
            const addrs = try netlink_address.getAddressesForInterface(allocator, @intCast(iface.index));
            defer allocator.free(addrs);

            for (addrs) |addr| {
                var addr_buf: [64]u8 = undefined;
                const addr_str = try addr.formatAddress(&addr_buf);
                const family = if (addr.isIPv4()) "inet" else "inet6";
                try stdout.print("    {s} {s} scope {s}\n", .{ family, addr_str, addr.scopeString() });
            }
        }
        return;
    }

    const iface_name = args[0];

    // wire interface <name> show
    if (args.len == 1 or std.mem.eql(u8, args[1], "show")) {
        const maybe_iface = try netlink_interface.getInterfaceByName(allocator, iface_name);

        if (maybe_iface) |iface| {
            const state = if (iface.isUp()) "UP" else "DOWN";
            const carrier = if (iface.hasCarrier()) "CARRIER" else "NO-CARRIER";

            try stdout.print("{d}: {s}: <{s},{s}> mtu {d}\n", .{
                iface.index,
                iface.getName(),
                state,
                carrier,
                iface.mtu,
            });

            if (iface.has_mac) {
                const mac = iface.formatMac();
                try stdout.print("    link/ether {s}\n", .{mac});
            }

            try stdout.print("    operstate: {s}\n", .{iface.operstateString()});

            // Get addresses
            const addrs = try netlink_address.getAddressesForInterface(allocator, @intCast(iface.index));
            defer allocator.free(addrs);

            for (addrs) |addr| {
                var addr_buf: [64]u8 = undefined;
                const addr_str = try addr.formatAddress(&addr_buf);
                const family = if (addr.isIPv4()) "inet" else "inet6";
                try stdout.print("    {s} {s} scope {s}\n", .{ family, addr_str, addr.scopeString() });
            }
        } else {
            try stdout.print("Interface {s} not found\n", .{iface_name});
        }
        return;
    }

    const action = args[1];

    // wire interface <name> set state up|down
    if (std.mem.eql(u8, action, "set") and args.len >= 4) {
        const attr = args[2];

        if (std.mem.eql(u8, attr, "state")) {
            const state_val = args[3];
            if (std.mem.eql(u8, state_val, "up")) {
                try netlink_interface.setInterfaceState(iface_name, true);
                try stdout.print("Interface {s} set to UP\n", .{iface_name});
            } else if (std.mem.eql(u8, state_val, "down")) {
                try netlink_interface.setInterfaceState(iface_name, false);
                try stdout.print("Interface {s} set to DOWN\n", .{iface_name});
            } else {
                try stdout.print("Invalid state: {s} (use 'up' or 'down')\n", .{state_val});
            }
        } else if (std.mem.eql(u8, attr, "mtu")) {
            const mtu_val = std.fmt.parseInt(u32, args[3], 10) catch {
                try stdout.print("Invalid MTU value: {s}\n", .{args[3]});
                return;
            };
            try netlink_interface.setInterfaceMtu(iface_name, mtu_val);
            try stdout.print("Interface {s} MTU set to {d}\n", .{ iface_name, mtu_val });
        } else {
            try stdout.print("Unknown attribute: {s}\n", .{attr});
        }
        return;
    }

    // wire interface <name> address <ip/prefix>
    if (std.mem.eql(u8, action, "address") and args.len >= 3) {
        const addr_str = args[2];

        // Get interface index
        const maybe_iface = try netlink_interface.getInterfaceByName(allocator, iface_name);
        if (maybe_iface == null) {
            try stdout.print("Interface {s} not found\n", .{iface_name});
            return;
        }
        const iface = maybe_iface.?;

        // Check if this is a delete operation
        if (std.mem.eql(u8, addr_str, "del") and args.len >= 4) {
            const del_addr = args[3];
            const parsed = netlink_address.parseIPv4(del_addr) catch {
                try stdout.print("Invalid address: {s}\n", .{del_addr});
                return;
            };
            try netlink_address.deleteAddress(@intCast(iface.index), linux.AF.INET, &parsed.addr, parsed.prefix);
            try stdout.print("Deleted {s} from {s}\n", .{ del_addr, iface_name });
            return;
        }

        // Add address
        const parsed = netlink_address.parseIPv4(addr_str) catch {
            try stdout.print("Invalid address: {s}\n", .{addr_str});
            return;
        };

        try netlink_address.addAddress(@intCast(iface.index), linux.AF.INET, &parsed.addr, parsed.prefix);
        try stdout.print("Added {s} to {s}\n", .{ addr_str, iface_name });
        return;
    }

    try stdout.print("Unknown action: {s}\n", .{action});
}

fn handleRoute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // wire route show (or just 'wire route')
    if (args.len == 0 or std.mem.eql(u8, args[0], "show")) {
        const routes = try netlink_route.getRoutes(allocator);
        defer allocator.free(routes);

        // Get interfaces for name lookup
        const interfaces = try netlink_interface.getInterfaces(allocator);
        defer allocator.free(interfaces);

        for (routes) |route| {
            // Skip local/broadcast routes
            if (route.route_type != 1) continue; // Only unicast

            var dst_buf: [64]u8 = undefined;
            const dst = try route.formatDst(&dst_buf);

            try stdout.print("{s}", .{dst});

            if (route.has_gateway) {
                var gw_buf: [64]u8 = undefined;
                const gw = try route.formatGateway(&gw_buf);
                try stdout.print(" via {s}", .{gw});
            }

            // Find interface name
            if (route.oif != 0) {
                for (interfaces) |iface| {
                    if (@as(u32, @intCast(iface.index)) == route.oif) {
                        try stdout.print(" dev {s}", .{iface.getName()});
                        break;
                    }
                }
            }

            try stdout.print(" proto {s}", .{route.protocolString()});

            if (route.priority != 0) {
                try stdout.print(" metric {d}", .{route.priority});
            }

            try stdout.print("\n", .{});
        }
        return;
    }

    const action = args[0];

    // wire route add <dst> via <gateway>
    // wire route add <dst> dev <interface>
    // wire route add default via <gateway>
    if (std.mem.eql(u8, action, "add") and args.len >= 2) {
        const dst_str = args[1];
        var gateway: ?[4]u8 = null;
        var dst: ?[4]u8 = null;
        var dst_len: u8 = 0;
        var oif: ?u32 = null;

        // Parse destination
        if (std.mem.eql(u8, dst_str, "default")) {
            dst_len = 0; // default route
        } else {
            const parsed = netlink_address.parseIPv4(dst_str) catch {
                try stdout.print("Invalid destination: {s}\n", .{dst_str});
                return;
            };
            dst = parsed.addr;
            dst_len = parsed.prefix;
        }

        // Look for 'via' and 'dev'
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "via") and i + 1 < args.len) {
                const gw_parsed = netlink_address.parseIPv4(args[i + 1]) catch {
                    try stdout.print("Invalid gateway: {s}\n", .{args[i + 1]});
                    return;
                };
                gateway = gw_parsed.addr;
                i += 1;
            } else if (std.mem.eql(u8, args[i], "dev") and i + 1 < args.len) {
                const iface_name = args[i + 1];
                const maybe_iface = try netlink_interface.getInterfaceByName(allocator, iface_name);
                if (maybe_iface == null) {
                    try stdout.print("Interface {s} not found\n", .{iface_name});
                    return;
                }
                oif = @intCast(maybe_iface.?.index);
                i += 1;
            }
        }

        // Must have either gateway or device
        if (gateway == null and oif == null) {
            try stdout.print("Route requires either 'via <gateway>' or 'dev <interface>'\n", .{});
            return;
        }

        const dst_slice: ?[]const u8 = if (dst) |*d| d[0..4] else null;
        const gw_slice: ?[]const u8 = if (gateway) |*g| g[0..4] else null;

        try netlink_route.addRoute(linux.AF.INET, dst_slice, dst_len, gw_slice, oif);
        try stdout.print("Route added\n", .{});
        return;
    }

    // wire route del <dst>
    if (std.mem.eql(u8, action, "del") and args.len >= 2) {
        const dst_str = args[1];
        var dst: ?[4]u8 = null;
        var dst_len: u8 = 0;

        if (std.mem.eql(u8, dst_str, "default")) {
            dst_len = 0;
        } else {
            const parsed = netlink_address.parseIPv4(dst_str) catch {
                try stdout.print("Invalid destination: {s}\n", .{dst_str});
                return;
            };
            dst = parsed.addr;
            dst_len = parsed.prefix;
        }

        const dst_slice: ?[]const u8 = if (dst) |*d| d[0..4] else null;

        try netlink_route.deleteRoute(linux.AF.INET, dst_slice, dst_len);
        try stdout.print("Route deleted\n", .{});
        return;
    }

    try stdout.print("Unknown action: {s}\n", .{action});
}

fn handleAnalyze(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\nNetwork Analysis Report\n", .{});
    try stdout.print("=======================\n\n", .{});

    // Get interfaces
    const interfaces = try netlink_interface.getInterfaces(allocator);
    defer allocator.free(interfaces);

    try stdout.print("Interfaces ({d} total)\n", .{interfaces.len});
    try stdout.print("--------------------\n", .{});

    for (interfaces) |iface| {
        const status = if (iface.isUp() and iface.hasCarrier())
            "✓"
        else if (iface.isUp())
            "⚠"
        else
            "✗";

        const addrs = try netlink_address.getAddressesForInterface(allocator, @intCast(iface.index));
        defer allocator.free(addrs);

        var addr_info: [64]u8 = undefined;
        var addr_len: usize = 0;

        if (addrs.len > 0) {
            var tmp_buf: [64]u8 = undefined;
            const addr_str = try addrs[0].formatAddress(&tmp_buf);
            @memcpy(addr_info[0..addr_str.len], addr_str);
            addr_len = addr_str.len;
        }

        const state = if (iface.isUp()) "up" else "down";
        const carrier = if (iface.hasCarrier()) "carrier" else "no-carrier";

        if (addr_len > 0) {
            try stdout.print("{s} {s}: {s}, {s}, {s}\n", .{ status, iface.getName(), state, carrier, addr_info[0..addr_len] });
        } else if (!iface.isLoopback()) {
            try stdout.print("{s} {s}: {s}, {s}, no address\n", .{ status, iface.getName(), state, carrier });
        } else {
            try stdout.print("{s} {s}: {s}, loopback\n", .{ status, iface.getName(), state });
        }
    }

    // Get routes
    const routes = try netlink_route.getRoutes(allocator);
    defer allocator.free(routes);

    try stdout.print("\nRouting\n", .{});
    try stdout.print("-------\n", .{});

    var has_default = false;
    for (routes) |route| {
        if (route.route_type != 1) continue; // Only unicast

        if (route.isDefault()) {
            has_default = true;
            var gw_buf: [64]u8 = undefined;
            const gw = try route.formatGateway(&gw_buf);
            try stdout.print("✓ default via {s}\n", .{gw});
        }
    }

    if (!has_default) {
        try stdout.print("⚠ No default route configured\n", .{});
    }

    try stdout.print("\n", .{});
}

fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("wire {s}\n", .{version});
    try stdout.print("Low-level, declarative, continuously-supervised network configuration for Linux\n", .{});
}

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\wire - Network configuration tool for Linux
        \\
        \\Usage: wire <command> [options]
        \\
        \\Commands:
        \\  interface                      List all interfaces
        \\  interface <name> show          Show interface details
        \\  interface <name> set state up  Bring interface up
        \\  interface <name> set state down Bring interface down
        \\  interface <name> set mtu <n>   Set interface MTU
        \\  interface <name> address <ip>  Add IP address (e.g., 10.0.0.1/24)
        \\  interface <name> address del <ip>  Delete IP address
        \\
        \\  route                          Show routing table
        \\  route show                     Show routing table
        \\  route add <dst> via <gw>       Add route via gateway
        \\  route add <dst> dev <iface>    Add route via interface
        \\  route add default via <gw>     Add default route
        \\  route del <dst>                Delete route
        \\
        \\  analyze                        Analyze network configuration
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\  -v, --version    Show version information
        \\
        \\Examples:
        \\  wire interface
        \\  wire interface eth0 show
        \\  wire interface eth0 set state up
        \\  wire interface eth0 set mtu 9000
        \\  wire interface eth0 address 10.0.0.1/24
        \\  wire route add default via 10.0.0.254
        \\  wire analyze
        \\
    , .{});
}

test "version string" {
    try std.testing.expect(version.len > 0);
}
