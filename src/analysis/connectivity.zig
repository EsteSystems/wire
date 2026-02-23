const std = @import("std");
const state_types = @import("../state/types.zig");

/// Connectivity check result
pub const CheckResult = struct {
    status: Status,
    message: [128]u8,
    message_len: usize,
    detail: [256]u8,
    detail_len: usize,

    pub const Status = enum {
        ok,
        warning,
        err,
        unknown,

        pub fn symbol(self: Status) []const u8 {
            return switch (self) {
                .ok => "[ok]",
                .warning => "[warn]",
                .err => "[err]",
                .unknown => "[?]",
            };
        }
    };

    pub fn getMessage(self: *const CheckResult) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn getDetail(self: *const CheckResult) ?[]const u8 {
        if (self.detail_len == 0) return null;
        return self.detail[0..self.detail_len];
    }

    pub fn format(self: *const CheckResult, writer: anytype) !void {
        try writer.print("{s} {s}", .{ self.status.symbol(), self.getMessage() });
        if (self.getDetail()) |detail| {
            try writer.print(" ({s})", .{detail});
        }
        try writer.print("\n", .{});
    }
};

/// Connectivity analyzer
pub const ConnectivityAnalyzer = struct {
    allocator: std.mem.Allocator,
    results: std.array_list.Managed(CheckResult),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .results = std.array_list.Managed(CheckResult).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.results.deinit();
    }

    /// Analyze connectivity based on network state
    pub fn analyze(self: *Self, state: *const state_types.NetworkState) ![]const CheckResult {
        self.results.clearRetainingCapacity();

        // Check for default gateway
        try self.checkDefaultGateway(state);

        // Check for DNS configuration
        try self.checkDnsConfig();

        // Check interface link status
        try self.checkInterfaceLinks(state);

        // Check for active addresses
        try self.checkActiveAddresses(state);

        return self.results.items;
    }

    /// Check for default gateway
    fn checkDefaultGateway(self: *Self, state: *const state_types.NetworkState) !void {
        var has_default = false;
        var gateway_str: [16]u8 = undefined;
        var gateway_len: usize = 0;

        for (state.routes.items) |*route| {
            if (route.dst_len == 0 and route.route_type == 1 and route.family == 2) {
                has_default = true;
                if (route.has_gateway) {
                    gateway_len = (std.fmt.bufPrint(&gateway_str, "{d}.{d}.{d}.{d}", .{
                        route.gateway[0],
                        route.gateway[1],
                        route.gateway[2],
                        route.gateway[3],
                    }) catch "?").len;
                }
                break;
            }
        }

        if (has_default) {
            try self.addResult(.ok, "Default gateway configured", gateway_str[0..gateway_len]);
        } else {
            try self.addResult(.warning, "No default gateway configured", "External connectivity may be unavailable");
        }
    }

    /// Check DNS configuration
    fn checkDnsConfig(self: *Self) !void {
        const file = std.fs.openFileAbsolute("/etc/resolv.conf", .{}) catch {
            try self.addResult(.warning, "Could not read /etc/resolv.conf", "DNS resolution may not work");
            return;
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        const content = file.readAll(&buf) catch {
            try self.addResult(.warning, "Could not read /etc/resolv.conf", null);
            return;
        };

        var nameserver_count: usize = 0;
        var lines = std.mem.splitScalar(u8, buf[0..content], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "nameserver")) {
                nameserver_count += 1;
            }
        }

        if (nameserver_count == 0) {
            try self.addResult(.warning, "No DNS nameservers configured", "Check /etc/resolv.conf");
        } else if (nameserver_count == 1) {
            try self.addResult(.ok, "DNS nameserver configured", "1 server (consider adding backup)");
        } else {
            var detail_buf: [32]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "{d} servers", .{nameserver_count}) catch "multiple";
            try self.addResult(.ok, "DNS nameservers configured", detail);
        }
    }

    /// Check interface link status
    fn checkInterfaceLinks(self: *Self, state: *const state_types.NetworkState) !void {
        var up_count: usize = 0;
        var carrier_count: usize = 0;
        var no_carrier_list: [256]u8 = undefined;
        var no_carrier_len: usize = 0;

        for (state.interfaces.items) |*iface| {
            // Skip loopback
            if (iface.link_type == .loopback) continue;

            if (iface.isUp()) {
                up_count += 1;
                if (iface.hasCarrier()) {
                    carrier_count += 1;
                } else {
                    // Add to no-carrier list
                    if (no_carrier_len > 0) {
                        if (no_carrier_len < no_carrier_list.len - 2) {
                            no_carrier_list[no_carrier_len] = ',';
                            no_carrier_list[no_carrier_len + 1] = ' ';
                            no_carrier_len += 2;
                        }
                    }
                    const name = iface.getName();
                    const copy_len = @min(name.len, no_carrier_list.len - no_carrier_len);
                    @memcpy(no_carrier_list[no_carrier_len .. no_carrier_len + copy_len], name[0..copy_len]);
                    no_carrier_len += copy_len;
                }
            }
        }

        if (up_count == 0) {
            try self.addResult(.err, "No interfaces are up", "Bring up at least one interface");
        } else if (carrier_count == 0) {
            try self.addResult(.err, "No interfaces have link carrier", "Check cable connections");
        } else if (carrier_count < up_count) {
            try self.addResult(.warning, "Some interfaces up without carrier", no_carrier_list[0..no_carrier_len]);
        } else {
            var detail_buf: [32]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "{d} up with carrier", .{carrier_count}) catch "ok";
            try self.addResult(.ok, "Interface links active", detail);
        }
    }

    /// Check for active addresses
    fn checkActiveAddresses(self: *Self, state: *const state_types.NetworkState) !void {
        var ipv4_count: usize = 0;
        var ipv6_count: usize = 0;

        for (state.addresses.items) |*addr| {
            // Skip loopback addresses
            if (addr.scope == 254) continue; // host scope

            if (addr.family == 2) {
                // Skip link-local (169.254.x.x)
                if (addr.address[0] == 169 and addr.address[1] == 254) continue;
                ipv4_count += 1;
            } else if (addr.family == 10) {
                // Skip link-local (fe80::)
                if (addr.address[0] == 0xfe and (addr.address[1] & 0xc0) == 0x80) continue;
                ipv6_count += 1;
            }
        }

        if (ipv4_count == 0 and ipv6_count == 0) {
            try self.addResult(.warning, "No routable IP addresses configured", "Add an address to an interface");
        } else {
            var detail_buf: [64]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "{d} IPv4, {d} IPv6", .{ ipv4_count, ipv6_count }) catch "configured";
            try self.addResult(.ok, "IP addresses configured", detail);
        }
    }

    /// Add a check result
    fn addResult(self: *Self, status: CheckResult.Status, message: []const u8, detail: ?[]const u8) !void {
        var result = CheckResult{
            .status = status,
            .message = undefined,
            .message_len = 0,
            .detail = undefined,
            .detail_len = 0,
        };

        const msg_len = @min(message.len, result.message.len);
        @memcpy(result.message[0..msg_len], message[0..msg_len]);
        result.message_len = msg_len;

        if (detail) |d| {
            const detail_len = @min(d.len, result.detail.len);
            @memcpy(result.detail[0..detail_len], d[0..detail_len]);
            result.detail_len = detail_len;
        }

        try self.results.append(result);
    }

    /// Format all results
    pub fn format(self: *const Self, writer: anytype) !void {
        try writer.print("Connectivity\n", .{});
        try writer.print("------------\n", .{});

        for (self.results.items) |*result| {
            try result.format(writer);
        }
    }

    /// Status counts
    pub const StatusCounts = struct {
        ok: usize,
        warning: usize,
        err: usize,
    };

    /// Count results by status
    pub fn countByStatus(self: *const Self) StatusCounts {
        var counts = StatusCounts{ .ok = 0, .warning = 0, .err = 0 };

        for (self.results.items) |*result| {
            switch (result.status) {
                .ok => counts.ok += 1,
                .warning => counts.warning += 1,
                .err => counts.err += 1,
                .unknown => {},
            }
        }

        return counts;
    }
};

// Tests

test "ConnectivityAnalyzer init" {
    const allocator = std.testing.allocator;
    var analyzer = ConnectivityAnalyzer.init(allocator);
    defer analyzer.deinit();

    try std.testing.expect(analyzer.results.items.len == 0);
}
