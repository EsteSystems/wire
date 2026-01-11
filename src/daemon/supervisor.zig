const std = @import("std");
const linux = std.os.linux;
const netlink_events = @import("../netlink/events.zig");
const state_types = @import("../state/types.zig");
const state_live = @import("../state/live.zig");
const state_desired = @import("../state/desired.zig");
const state_diff = @import("../state/diff.zig");
const reconciler = @import("reconciler.zig");
const config_loader = @import("../config/loader.zig");
const ipc = @import("ipc.zig");
const watcher = @import("watcher.zig");
const snapshots = @import("../history/snapshots.zig");
const changelog = @import("../history/changelog.zig");

/// Daemon configuration
pub const DaemonConfig = struct {
    /// Path to configuration file
    config_path: []const u8 = "/etc/wire/network.conf",
    /// Path to PID file
    pid_file: []const u8 = "/run/wire.pid",
    /// Path to IPC socket
    socket_path: []const u8 = "/run/wire.sock",
    /// Reconciliation interval in seconds (0 = event-driven only)
    reconcile_interval: u32 = 60,
    /// Enable verbose logging
    verbose: bool = false,
    /// Dry run mode (don't actually apply changes)
    dry_run: bool = false,
    /// Watch config file for changes
    watch_config: bool = true,
};

/// Daemon state
pub const DaemonState = enum {
    stopped,
    starting,
    running,
    stopping,
    reloading,
};

/// Supervisor - the main daemon controller
pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    config: DaemonConfig,
    state: DaemonState,
    event_monitor: ?netlink_events.EventMonitor,
    ipc_server: ?ipc.IpcServer,
    config_watcher: ?watcher.ConfigWatcher,
    desired_state: ?state_types.NetworkState,
    pid: linux.pid_t,
    should_reload: bool,
    should_stop: bool,

    // History tracking
    snapshot_mgr: snapshots.SnapshotManager,
    change_logger: changelog.ChangeLogger,
    last_snapshot: i64,

    // Statistics
    reconcile_count: u64,
    event_count: u64,
    last_reconcile: i64,
    start_time: i64,

    const Self = @This();
    const snapshot_interval: i64 = 60; // Minimum seconds between snapshots

    pub fn init(allocator: std.mem.Allocator, config: DaemonConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .state = .stopped,
            .event_monitor = null,
            .ipc_server = null,
            .config_watcher = null,
            .desired_state = null,
            .pid = 0,
            .should_reload = false,
            .should_stop = false,
            .snapshot_mgr = snapshots.SnapshotManager.init(allocator, null),
            .change_logger = changelog.ChangeLogger.init(allocator, null),
            .last_snapshot = 0,
            .reconcile_count = 0,
            .event_count = 0,
            .last_reconcile = 0,
            .start_time = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.config_watcher) |*cw| {
            cw.deinit();
        }
        if (self.ipc_server) |*server| {
            server.deinit();
        }
        if (self.event_monitor) |*monitor| {
            monitor.deinit();
        }
        if (self.desired_state) |*ds| {
            ds.deinit();
        }
    }

    /// Start the daemon (foreground mode for now)
    pub fn start(self: *Self) !void {
        if (self.state != .stopped) {
            return error.AlreadyRunning;
        }

        self.state = .starting;
        self.start_time = std.time.timestamp();
        self.pid = linux.getpid();

        // Write PID file
        try self.writePidFile();
        errdefer self.removePidFile();

        // Load initial configuration
        try self.loadConfig();

        // Create event monitor
        self.event_monitor = try netlink_events.EventMonitor.initDefault();

        // Create and start IPC server
        self.ipc_server = ipc.IpcServer.init(self.allocator, self.config.socket_path);
        if (self.ipc_server) |*server| {
            server.start() catch |err| {
                const stdout = std.io.getStdOut().writer();
                stdout.print("Warning: Failed to start IPC server: {}\n", .{err}) catch {};
                self.ipc_server = null;
            };
        }

        // Create config file watcher
        if (self.config.watch_config) {
            self.config_watcher = watcher.ConfigWatcher.init(self.allocator, self.config.config_path) catch |err| blk: {
                const stdout = std.io.getStdOut().writer();
                stdout.print("Warning: Failed to start config watcher: {}\n", .{err}) catch {};
                break :blk null;
            };
            if (self.config_watcher != null) {
                const stdout = std.io.getStdOut().writer();
                stdout.print("Watching config file for changes: {s}\n", .{self.config.config_path}) catch {};
            }
        }

        self.state = .running;

        // Create initial snapshot
        try self.createInitialSnapshot();

        // Main loop
        try self.runLoop();

        // Cleanup
        self.state = .stopping;
        self.removePidFile();
        self.state = .stopped;
    }

    /// Main event loop
    fn runLoop(self: *Self) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("wire daemon started (pid: {d})\n", .{self.pid});

        var last_reconcile = std.time.timestamp();

        while (!self.should_stop) {
            // Check for reload request
            if (self.should_reload) {
                try stdout.print("Reloading configuration...\n", .{});
                self.loadConfig() catch |err| {
                    try stdout.print("Failed to reload config: {}\n", .{err});
                };
                self.should_reload = false;
            }

            // Poll for netlink events
            if (self.event_monitor) |*monitor| {
                const events = monitor.poll(100); // 100ms timeout for responsive IPC
                if (events > 0) {
                    self.event_count += @intCast(events);
                    if (self.config.verbose) {
                        try stdout.print("Processed {d} netlink events\n", .{events});
                    }
                    // Trigger reconciliation after events
                    try self.reconcile();
                }
            }

            // Poll for IPC messages
            if (self.ipc_server) |*server| {
                _ = server.poll(self);
            }

            // Poll for config file changes
            if (self.config_watcher) |*cw| {
                if (cw.poll()) {
                    try stdout.print("Config file changed, reloading...\n", .{});
                    self.loadConfig() catch |err| {
                        try stdout.print("Failed to reload config: {}\n", .{err});
                    };
                    // Trigger reconciliation after config reload
                    try self.reconcile();
                }
            }

            // Periodic reconciliation
            const now = std.time.timestamp();
            if (self.config.reconcile_interval > 0 and
                now - last_reconcile >= self.config.reconcile_interval)
            {
                try self.reconcile();
                last_reconcile = now;
            }
        }

        try stdout.print("wire daemon stopping...\n", .{});
    }

    /// Perform reconciliation
    fn reconcile(self: *Self) !void {
        const stdout = std.io.getStdOut().writer();

        if (self.desired_state == null) {
            return;
        }

        // Query live state
        var live = state_live.queryLiveState(self.allocator) catch |err| {
            try stdout.print("Failed to query live state: {}\n", .{err});
            return;
        };
        defer live.deinit();

        // Compute diff
        var diff = state_diff.compare(&self.desired_state.?, &live, self.allocator) catch |err| {
            try stdout.print("Failed to compute diff: {}\n", .{err});
            return;
        };
        defer diff.deinit();

        if (!diff.isEmpty()) {
            try stdout.print("Drift detected: {d} changes needed\n", .{diff.changes.items.len});

            if (!self.config.dry_run) {
                // Apply corrections
                const policy = reconciler.ReconcilePolicy{
                    .dry_run = false,
                    .verbose = self.config.verbose,
                    .stop_on_error = false,
                };

                var recon = reconciler.Reconciler.init(self.allocator, policy);
                defer recon.deinit();

                const stats = recon.reconcile(&diff) catch |err| {
                    try stdout.print("Reconciliation failed: {}\n", .{err});
                    return;
                };

                try stdout.print("Reconciled: {d} applied, {d} failed\n", .{ stats.applied, stats.failed });

                // Log changes to history
                if (stats.applied > 0) {
                    self.logChanges(&diff);
                    self.maybeCreateSnapshot();
                }
            }
        }

        self.reconcile_count += 1;
        self.last_reconcile = std.time.timestamp();
    }

    /// Create initial snapshot at daemon start
    fn createInitialSnapshot(self: *Self) !void {
        const stdout = std.io.getStdOut().writer();

        // Query live state
        var live = state_live.queryLiveState(self.allocator) catch |err| {
            stdout.print("Warning: Could not create initial snapshot: {}\n", .{err}) catch {};
            return;
        };
        defer live.deinit();

        // Create snapshot
        const snapshot = self.snapshot_mgr.createSnapshot(&live) catch |err| {
            stdout.print("Warning: Failed to create initial snapshot: {}\n", .{err}) catch {};
            return;
        };

        self.last_snapshot = snapshot.timestamp;
        stdout.print("Created initial snapshot at {d}\n", .{snapshot.timestamp}) catch {};
    }

    /// Log changes from a diff to the changelog
    fn logChanges(self: *Self, diff: *const state_types.StateDiff) void {
        for (diff.changes.items) |change| {
            self.change_logger.logStateChange(change) catch {};
        }
    }

    /// Create a snapshot if enough time has passed
    fn maybeCreateSnapshot(self: *Self) void {
        const now = std.time.timestamp();
        if (now - self.last_snapshot < snapshot_interval) {
            return;
        }

        // Query live state
        var live = state_live.queryLiveState(self.allocator) catch return;
        defer live.deinit();

        // Create snapshot
        const snapshot = self.snapshot_mgr.createSnapshot(&live) catch return;
        self.last_snapshot = snapshot.timestamp;

        if (self.config.verbose) {
            const stdout = std.io.getStdOut().writer();
            stdout.print("Created snapshot at {d}\n", .{snapshot.timestamp}) catch {};
        }
    }

    /// Load configuration from file
    fn loadConfig(self: *Self) !void {
        // Free existing desired state
        if (self.desired_state) |*ds| {
            ds.deinit();
            self.desired_state = null;
        }

        // Load config file
        var loader = config_loader.ConfigLoader.init(self.allocator);
        defer loader.deinit();

        var loaded = try loader.loadFile(self.config.config_path);
        defer loaded.deinit(self.allocator);

        // Build desired state
        self.desired_state = try state_desired.buildDesiredState(loaded.commands, self.allocator);
    }

    /// Request configuration reload
    pub fn requestReload(self: *Self) void {
        self.should_reload = true;
    }

    /// Request daemon stop
    pub fn requestStop(self: *Self) void {
        self.should_stop = true;
        if (self.event_monitor) |*monitor| {
            monitor.stop();
        }
        if (self.ipc_server) |*server| {
            server.stop();
        }
        if (self.config_watcher) |*cw| {
            cw.stop();
        }
    }

    /// Write PID file
    fn writePidFile(self: *Self) !void {
        const file = std.fs.cwd().createFile(self.config.pid_file, .{}) catch |err| {
            switch (err) {
                error.AccessDenied => return error.PermissionDenied,
                else => return err,
            }
        };
        defer file.close();

        var buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&buf, "{d}\n", .{self.pid}) catch unreachable;
        try file.writeAll(pid_str);
    }

    /// Remove PID file
    fn removePidFile(self: *Self) void {
        std.fs.cwd().deleteFile(self.config.pid_file) catch {};
    }

    /// Get daemon status
    pub fn getStatus(self: *const Self) DaemonStatus {
        return DaemonStatus{
            .state = self.state,
            .pid = self.pid,
            .uptime = if (self.start_time > 0) std.time.timestamp() - self.start_time else 0,
            .reconcile_count = self.reconcile_count,
            .event_count = self.event_count,
            .last_reconcile = self.last_reconcile,
            .config_path = self.config.config_path,
        };
    }
};

/// Status information
pub const DaemonStatus = struct {
    state: DaemonState,
    pid: linux.pid_t,
    uptime: i64,
    reconcile_count: u64,
    event_count: u64,
    last_reconcile: i64,
    config_path: []const u8,
};

/// Read PID from PID file
pub fn readPidFile(path: []const u8) !linux.pid_t {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return error.NotRunning,
            else => return err,
        }
    };
    defer file.close();

    var buf: [32]u8 = undefined;
    const bytes_read = try file.read(&buf);
    if (bytes_read == 0) return error.InvalidPidFile;

    // Parse PID
    const pid_str = std.mem.trimRight(u8, buf[0..bytes_read], "\n\r\t ");
    const pid = std.fmt.parseInt(linux.pid_t, pid_str, 10) catch return error.InvalidPidFile;

    // Check if process is running
    const result = linux.kill(pid, 0);
    if (@as(isize, @bitCast(result)) < 0) {
        const errno = linux.E.init(result);
        if (errno == .SRCH) return error.NotRunning; // No such process
        if (errno == .PERM) return pid; // Process exists, we just can't signal it
    }

    return pid;
}

/// Send signal to daemon
pub fn sendSignal(pid_file: []const u8, signal: i32) !void {
    const pid = try readPidFile(pid_file);
    const result = linux.kill(pid, signal);
    if (@as(isize, @bitCast(result)) < 0) {
        return error.SignalFailed;
    }
}

/// Check if daemon is running
pub fn isRunning(pid_file: []const u8) bool {
    _ = readPidFile(pid_file) catch return false;
    return true;
}

// Tests

test "DaemonConfig defaults" {
    const config = DaemonConfig{};
    try std.testing.expectEqualStrings("/etc/wire/network.conf", config.config_path);
    try std.testing.expectEqual(@as(u32, 60), config.reconcile_interval);
}

test "DaemonState values" {
    try std.testing.expect(@intFromEnum(DaemonState.stopped) != @intFromEnum(DaemonState.running));
}
