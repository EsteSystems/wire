const std = @import("std");
const process = @import("../process.zig");
const adapter = @import("../adapter.zig");

/// Ping result with parsed statistics
pub const PingResult = struct {
    status: adapter.ResultStatus,
    target: []const u8,
    // Statistics
    packets_sent: u32,
    packets_received: u32,
    packet_loss_percent: f64,
    // RTT in milliseconds
    rtt_min: ?f64,
    rtt_avg: ?f64,
    rtt_max: ?f64,
    rtt_mdev: ?f64,
    // Raw output for debugging
    raw_output: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.target.len > 0) allocator.free(self.target);
        if (self.raw_output.len > 0) allocator.free(self.raw_output);
    }

    pub fn isReachable(self: *const Self) bool {
        return self.packets_received > 0;
    }

    pub fn format(self: *const Self, writer: anytype) !void {
        if (self.status == .tool_not_found) {
            try writer.print("ping: tool not found\n", .{});
            try writer.print("{s}\n", .{process.getInstallHint("ping")});
            return;
        }

        if (self.status == .timeout) {
            try writer.print("ping {s}: timed out\n", .{self.target});
            return;
        }

        try writer.print("PING {s}\n", .{self.target});

        if (self.isReachable()) {
            try writer.print("  Status: REACHABLE\n", .{});
        } else {
            try writer.print("  Status: UNREACHABLE\n", .{});
        }

        try writer.print("  Packets: {d} sent, {d} received, {d:.1}% loss\n", .{
            self.packets_sent,
            self.packets_received,
            self.packet_loss_percent,
        });

        if (self.rtt_avg) |avg| {
            try writer.print("  RTT: ", .{});
            if (self.rtt_min) |min| {
                try writer.print("min={d:.2}ms ", .{min});
            }
            try writer.print("avg={d:.2}ms ", .{avg});
            if (self.rtt_max) |max| {
                try writer.print("max={d:.2}ms ", .{max});
            }
            try writer.print("\n", .{});
        }
    }
};

/// Ping adapter options
pub const PingOptions = struct {
    count: u32 = 4,
    timeout_secs: u32 = 5,
    interval_ms: ?u32 = null,
    interface: ?[]const u8 = null,
    ttl: ?u8 = null,
    packet_size: ?u16 = null,
};

/// Run ping and return parsed results
pub fn ping(allocator: std.mem.Allocator, target: []const u8, options: PingOptions) !PingResult {
    // Check if ping exists
    if (!process.programExists("ping")) {
        return PingResult{
            .status = .tool_not_found,
            .target = try allocator.dupe(u8, target),
            .packets_sent = 0,
            .packets_received = 0,
            .packet_loss_percent = 100.0,
            .rtt_min = null,
            .rtt_avg = null,
            .rtt_max = null,
            .rtt_mdev = null,
            .raw_output = &[_]u8{},
        };
    }

    // Build ping command arguments
    var args = std.array_list.Managed([]const u8).init(allocator);
    defer args.deinit();

    // Count
    var count_buf: [16]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{options.count}) catch "4";
    try args.append("-c");
    try args.append(count_str);

    // Timeout (deadline)
    var timeout_buf: [16]u8 = undefined;
    const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{options.timeout_secs}) catch "5";
    try args.append("-W");
    try args.append(timeout_str);

    // Interface binding
    if (options.interface) |iface| {
        try args.append("-I");
        try args.append(iface);
    }

    // TTL
    if (options.ttl) |ttl| {
        var ttl_buf: [8]u8 = undefined;
        const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl}) catch "64";
        try args.append("-t");
        try args.append(ttl_str);
    }

    // Packet size
    if (options.packet_size) |size| {
        var size_buf: [8]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{size}) catch "56";
        try args.append("-s");
        try args.append(size_str);
    }

    // Target
    try args.append(target);

    // Run ping
    var pm = process.ProcessManager.init(allocator);
    const timeout_ms = (options.timeout_secs + options.count) * 1000 + 5000; // Extra buffer

    var proc_result = try pm.runWithTimeout("ping", args.items, timeout_ms);
    defer proc_result.deinit(allocator);

    // Handle timeout
    if (proc_result.timed_out) {
        return PingResult{
            .status = .timeout,
            .target = try allocator.dupe(u8, target),
            .packets_sent = options.count,
            .packets_received = 0,
            .packet_loss_percent = 100.0,
            .rtt_min = null,
            .rtt_avg = null,
            .rtt_max = null,
            .rtt_mdev = null,
            .raw_output = try allocator.dupe(u8, proc_result.stdout),
        };
    }

    // Parse output
    return parsePingOutput(allocator, target, proc_result.stdout, proc_result.exit_code);
}

/// Parse ping output to extract statistics
fn parsePingOutput(allocator: std.mem.Allocator, target: []const u8, output: []const u8, exit_code: i32) !PingResult {
    var result = PingResult{
        .status = if (exit_code == 0) .success else .failure,
        .target = try allocator.dupe(u8, target),
        .packets_sent = 0,
        .packets_received = 0,
        .packet_loss_percent = 100.0,
        .rtt_min = null,
        .rtt_avg = null,
        .rtt_max = null,
        .rtt_mdev = null,
        .raw_output = try allocator.dupe(u8, output),
    };

    // Parse line by line
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        // Look for statistics line: "X packets transmitted, Y received, Z% packet loss"
        if (std.mem.indexOf(u8, line, "packets transmitted")) |_| {
            parsePacketStats(line, &result);
        }
        // Look for RTT line: "rtt min/avg/max/mdev = X/Y/Z/W ms"
        else if (std.mem.indexOf(u8, line, "rtt min/avg/max")) |_| {
            parseRttStats(line, &result);
        }
        // Alternative format: "round-trip min/avg/max/stddev"
        else if (std.mem.indexOf(u8, line, "round-trip")) |_| {
            parseRttStats(line, &result);
        }
    }

    // Update status based on received packets
    if (result.packets_received > 0) {
        result.status = .success;
    }

    return result;
}

/// Parse "X packets transmitted, Y received, Z% packet loss" line
fn parsePacketStats(line: []const u8, result: *PingResult) void {
    // Find "X packets transmitted"
    var iter = std.mem.splitSequence(u8, line, " ");
    while (iter.next()) |word| {
        if (std.mem.eql(u8, word, "packets")) {
            // Previous word was the count
            break;
        }
        result.packets_sent = std.fmt.parseInt(u32, word, 10) catch continue;
    }

    // Find "Y received"
    if (std.mem.indexOf(u8, line, " received")) |idx| {
        // Walk backwards to find the number
        const end = idx;
        var start = idx;
        while (start > 0) {
            start -= 1;
            if (line[start] == ' ' or line[start] == ',') {
                start += 1;
                break;
            }
        }
        if (start < end) {
            result.packets_received = std.fmt.parseInt(u32, line[start..end], 10) catch 0;
        }
    }

    // Find "Z% packet loss"
    if (std.mem.indexOf(u8, line, "% packet loss")) |idx| {
        // Walk backwards to find the number
        const end = idx;
        var start = idx;
        while (start > 0) {
            start -= 1;
            const c = line[start];
            if (c == ' ' or c == ',') {
                start += 1;
                break;
            }
        }
        if (start < end) {
            result.packet_loss_percent = std.fmt.parseFloat(f64, line[start..end]) catch 100.0;
        }
    }
}

/// Parse "rtt min/avg/max/mdev = X/Y/Z/W ms" line
fn parseRttStats(line: []const u8, result: *PingResult) void {
    // Find the "=" and parse values after it
    if (std.mem.indexOf(u8, line, "=")) |eq_idx| {
        const values_part = std.mem.trimLeft(u8, line[eq_idx + 1 ..], " ");

        // Split by "/" to get min/avg/max/mdev
        var parts = std.mem.splitScalar(u8, values_part, '/');

        if (parts.next()) |min_str| {
            result.rtt_min = std.fmt.parseFloat(f64, std.mem.trim(u8, min_str, " ")) catch null;
        }
        if (parts.next()) |avg_str| {
            result.rtt_avg = std.fmt.parseFloat(f64, std.mem.trim(u8, avg_str, " ")) catch null;
        }
        if (parts.next()) |max_str| {
            result.rtt_max = std.fmt.parseFloat(f64, std.mem.trim(u8, max_str, " ")) catch null;
        }
        if (parts.next()) |mdev_str| {
            // mdev may have " ms" suffix
            const mdev_clean = std.mem.trimRight(u8, std.mem.trim(u8, mdev_str, " "), " ms");
            result.rtt_mdev = std.fmt.parseFloat(f64, mdev_clean) catch null;
        }
    }
}

/// Quick connectivity check - returns true if target is reachable
pub fn isReachable(allocator: std.mem.Allocator, target: []const u8) !bool {
    var result = try ping(allocator, target, .{ .count = 1, .timeout_secs = 3 });
    defer result.deinit(allocator);
    return result.isReachable();
}

// Tests

test "parsePacketStats" {
    var result = PingResult{
        .status = .success,
        .target = "",
        .packets_sent = 0,
        .packets_received = 0,
        .packet_loss_percent = 100.0,
        .rtt_min = null,
        .rtt_avg = null,
        .rtt_max = null,
        .rtt_mdev = null,
        .raw_output = "",
    };

    parsePacketStats("4 packets transmitted, 4 received, 0% packet loss, time 3003ms", &result);

    try std.testing.expectEqual(@as(u32, 4), result.packets_sent);
    try std.testing.expectEqual(@as(u32, 4), result.packets_received);
    try std.testing.expectEqual(@as(f64, 0.0), result.packet_loss_percent);
}

test "parseRttStats" {
    var result = PingResult{
        .status = .success,
        .target = "",
        .packets_sent = 0,
        .packets_received = 0,
        .packet_loss_percent = 100.0,
        .rtt_min = null,
        .rtt_avg = null,
        .rtt_max = null,
        .rtt_mdev = null,
        .raw_output = "",
    };

    parseRttStats("rtt min/avg/max/mdev = 0.123/0.456/0.789/0.111 ms", &result);

    try std.testing.expect(result.rtt_min != null);
    try std.testing.expect(result.rtt_avg != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.123), result.rtt_min.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.456), result.rtt_avg.?, 0.001);
}
