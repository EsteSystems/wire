const std = @import("std");
const probe = @import("probe.zig");
const validate = @import("validate.zig");
const netlink_interface = @import("../netlink/interface.zig");
const posix = std.posix;

/// Watch configuration
pub const WatchConfig = struct {
    target: []const u8,
    port: u16,
    interval_ms: u32 = 1000,
    timeout_ms: u32 = 3000,
    alert_threshold_ms: ?u32 = null, // Alert if latency exceeds this
    alert_on_failure: bool = true,
    max_iterations: ?u32 = null, // null = infinite
};

/// Statistics for watch session
pub const WatchStats = struct {
    total_probes: u64 = 0,
    successful_probes: u64 = 0,
    failed_probes: u64 = 0,
    min_latency_us: ?u64 = null,
    max_latency_us: ?u64 = null,
    total_latency_us: u64 = 0,
    alerts_triggered: u64 = 0,
    start_time: i64,
    last_status: ?probe.ProbeResult.Status = null,

    pub fn init() WatchStats {
        return .{
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn recordProbe(self: *WatchStats, result: *const probe.ProbeResult) void {
        self.total_probes += 1;
        self.last_status = result.status;

        if (result.status == .open) {
            self.successful_probes += 1;
            if (result.latency_us) |lat| {
                self.total_latency_us += lat;
                if (self.min_latency_us == null or lat < self.min_latency_us.?) {
                    self.min_latency_us = lat;
                }
                if (self.max_latency_us == null or lat > self.max_latency_us.?) {
                    self.max_latency_us = lat;
                }
            }
        } else {
            self.failed_probes += 1;
        }
    }

    pub fn successRate(self: *const WatchStats) f64 {
        if (self.total_probes == 0) return 0;
        return @as(f64, @floatFromInt(self.successful_probes)) / @as(f64, @floatFromInt(self.total_probes)) * 100.0;
    }

    pub fn avgLatencyUs(self: *const WatchStats) ?u64 {
        if (self.successful_probes == 0) return null;
        return self.total_latency_us / self.successful_probes;
    }

    pub fn elapsedSecs(self: *const WatchStats) f64 {
        const now = std.time.milliTimestamp();
        return @as(f64, @floatFromInt(now - self.start_time)) / 1000.0;
    }

    pub fn format(self: *const WatchStats, writer: anytype) !void {
        try writer.print("\n--- Watch Statistics ---\n", .{});
        try writer.print("Duration: {d:.1}s\n", .{self.elapsedSecs()});
        try writer.print("Probes: {d} total, {d} successful, {d} failed\n", .{
            self.total_probes,
            self.successful_probes,
            self.failed_probes,
        });
        try writer.print("Success rate: {d:.1}%\n", .{self.successRate()});

        if (self.avgLatencyUs()) |avg| {
            try writer.print("Latency: min={d}us avg={d}us max={d}us\n", .{
                self.min_latency_us orelse 0,
                avg,
                self.max_latency_us orelse 0,
            });
        }

        if (self.alerts_triggered > 0) {
            try writer.print("Alerts triggered: {d}\n", .{self.alerts_triggered});
        }
    }
};

/// Watch result for a single iteration
pub const WatchEvent = struct {
    timestamp: i64,
    probe_result: probe.ProbeResult,
    alert: ?Alert,

    pub const Alert = struct {
        alert_type: AlertType,
        message: []const u8,
    };

    pub const AlertType = enum {
        connection_failed,
        high_latency,
        connection_restored,
    };

    pub fn format(self: *const WatchEvent, writer: anytype, show_timestamp: bool) !void {
        if (show_timestamp) {
            // Format relative timestamp
            const secs = @divFloor(self.timestamp, 1000);
            const ms = @mod(self.timestamp, 1000);
            try writer.print("[{d}.{d:0>3}] ", .{ secs, ms });
        }

        // Status indicator
        const status_char: u8 = switch (self.probe_result.status) {
            .open => '.',
            .closed => 'R', // Refused
            .filtered => 'T', // Timeout
            .host_unreachable => 'U',
            .error_occurred => 'E',
        };
        try writer.print("{c}", .{status_char});

        // Latency for successful probes
        if (self.probe_result.status == .open) {
            if (self.probe_result.latency_us) |lat| {
                if (lat < 1000) {
                    try writer.print(" {d}us", .{lat});
                } else {
                    try writer.print(" {d:.1}ms", .{@as(f64, @floatFromInt(lat)) / 1000.0});
                }
            }
        }

        // Alert
        if (self.alert) |alert| {
            try writer.print(" ALERT: {s}", .{alert.message});
        }

        try writer.print("\n", .{});
    }
};

/// Run watch loop (blocking)
pub fn watch(config: WatchConfig, writer: anytype) !WatchStats {
    var stats = WatchStats.init();
    var was_up = true;
    const base_time = std.time.milliTimestamp();

    try writer.print("Watching {s}:{d} (interval={d}ms, timeout={d}ms)\n", .{
        config.target,
        config.port,
        config.interval_ms,
        config.timeout_ms,
    });
    if (config.alert_threshold_ms) |threshold| {
        try writer.print("Alert threshold: {d}ms\n", .{threshold});
    }
    try writer.print("Press Ctrl+C to stop\n\n", .{});

    var iteration: u32 = 0;
    while (config.max_iterations == null or iteration < config.max_iterations.?) {
        iteration += 1;

        const result = probe.probeTcp(config.target, config.port, config.timeout_ms);
        stats.recordProbe(&result);

        var event = WatchEvent{
            .timestamp = std.time.milliTimestamp() - base_time,
            .probe_result = result,
            .alert = null,
        };

        // Check for alerts
        if (config.alert_on_failure and result.status != .open) {
            if (was_up) {
                event.alert = .{
                    .alert_type = .connection_failed,
                    .message = "Connection lost",
                };
                stats.alerts_triggered += 1;
            }
            was_up = false;
        } else if (result.status == .open) {
            if (!was_up) {
                event.alert = .{
                    .alert_type = .connection_restored,
                    .message = "Connection restored",
                };
                stats.alerts_triggered += 1;
            }
            was_up = true;

            // Check latency threshold
            if (config.alert_threshold_ms) |threshold| {
                if (result.latency_us) |lat| {
                    if (lat > @as(u64, threshold) * 1000) {
                        event.alert = .{
                            .alert_type = .high_latency,
                            .message = "High latency",
                        };
                        stats.alerts_triggered += 1;
                    }
                }
            }
        }

        try event.format(writer, true);

        // Sleep for interval (unless this is the last iteration)
        if (config.max_iterations == null or iteration < config.max_iterations.?) {
            std.time.sleep(@as(u64, config.interval_ms) * std.time.ns_per_ms);
        }
    }

    return stats;
}

/// Watch an interface's link status
pub fn watchInterface(allocator: std.mem.Allocator, iface_name: []const u8, interval_ms: u32, max_iterations: ?u32, writer: anytype) !void {
    try writer.print("Watching interface {s} (interval={d}ms)\n", .{ iface_name, interval_ms });
    try writer.print("Press Ctrl+C to stop\n\n", .{});

    var iteration: u32 = 0;
    var last_state: ?bool = null;
    var last_carrier: ?bool = null;

    while (max_iterations == null or iteration < max_iterations.?) {
        iteration += 1;

        const maybe_iface = netlink_interface.getInterfaceByName(allocator, iface_name) catch null;

        if (maybe_iface) |iface| {
            const is_up = iface.isUp();
            const has_carrier = iface.hasCarrier();

            // Check for state changes
            var changed = false;
            if (last_state != null and last_state.? != is_up) {
                if (is_up) {
                    try writer.print("ALERT: Interface came UP\n", .{});
                } else {
                    try writer.print("ALERT: Interface went DOWN\n", .{});
                }
                changed = true;
            }

            if (last_carrier != null and last_carrier.? != has_carrier) {
                if (has_carrier) {
                    try writer.print("ALERT: Carrier detected\n", .{});
                } else {
                    try writer.print("ALERT: Carrier lost\n", .{});
                }
                changed = true;
            }

            if (!changed) {
                const state = if (is_up) "UP" else "DOWN";
                const carrier = if (has_carrier) "CARRIER" else "NO-CARRIER";
                try writer.print("{s}: <{s},{s}>\n", .{ iface_name, state, carrier });
            }

            last_state = is_up;
            last_carrier = has_carrier;
        } else {
            try writer.print("ALERT: Interface {s} not found!\n", .{iface_name});
        }

        std.time.sleep(@as(u64, interval_ms) * std.time.ns_per_ms);
    }
}

// Tests

test "WatchStats" {
    var stats = WatchStats.init();

    var result1 = probe.ProbeResult{
        .target = "test",
        .port = 22,
        .protocol = .tcp,
        .status = .open,
        .latency_us = 1000,
        .error_msg = null,
    };
    stats.recordProbe(&result1);

    var result2 = probe.ProbeResult{
        .target = "test",
        .port = 22,
        .protocol = .tcp,
        .status = .open,
        .latency_us = 2000,
        .error_msg = null,
    };
    stats.recordProbe(&result2);

    try std.testing.expectEqual(@as(u64, 2), stats.total_probes);
    try std.testing.expectEqual(@as(u64, 2), stats.successful_probes);
    try std.testing.expectEqual(@as(u64, 1000), stats.min_latency_us.?);
    try std.testing.expectEqual(@as(u64, 2000), stats.max_latency_us.?);
    try std.testing.expectEqual(@as(u64, 1500), stats.avgLatencyUs().?);
}
