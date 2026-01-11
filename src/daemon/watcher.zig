const std = @import("std");
const linux = std.os.linux;

/// Inotify event masks
pub const IN = struct {
    pub const ACCESS: u32 = 0x00000001;
    pub const MODIFY: u32 = 0x00000002;
    pub const ATTRIB: u32 = 0x00000004;
    pub const CLOSE_WRITE: u32 = 0x00000008;
    pub const CLOSE_NOWRITE: u32 = 0x00000010;
    pub const CLOSE: u32 = CLOSE_WRITE | CLOSE_NOWRITE;
    pub const OPEN: u32 = 0x00000020;
    pub const MOVED_FROM: u32 = 0x00000040;
    pub const MOVED_TO: u32 = 0x00000080;
    pub const MOVE: u32 = MOVED_FROM | MOVED_TO;
    pub const CREATE: u32 = 0x00000100;
    pub const DELETE: u32 = 0x00000200;
    pub const DELETE_SELF: u32 = 0x00000400;
    pub const MOVE_SELF: u32 = 0x00000800;
    pub const UNMOUNT: u32 = 0x00002000;
    pub const Q_OVERFLOW: u32 = 0x00004000;
    pub const IGNORED: u32 = 0x00008000;
    pub const ONLYDIR: u32 = 0x01000000;
    pub const DONT_FOLLOW: u32 = 0x02000000;
    pub const EXCL_UNLINK: u32 = 0x04000000;
    pub const MASK_CREATE: u32 = 0x10000000;
    pub const MASK_ADD: u32 = 0x20000000;
    pub const ISDIR: u32 = 0x40000000;
    pub const ONESHOT: u32 = 0x80000000;
};

/// Inotify event structure
pub const InotifyEvent = extern struct {
    wd: i32, // Watch descriptor
    mask: u32, // Event mask
    cookie: u32, // Cookie for rename events
    len: u32, // Length of name field

    pub fn getName(self: *const InotifyEvent) ?[]const u8 {
        if (self.len == 0) return null;
        const name_ptr: [*]const u8 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(self)) + @sizeOf(InotifyEvent)));
        // Find null terminator
        var len: usize = 0;
        while (len < self.len and name_ptr[len] != 0) : (len += 1) {}
        return name_ptr[0..len];
    }
};

/// File watcher event type
pub const WatchEvent = enum {
    modified,
    deleted,
    created,
    moved,
    attrib_changed,
};

/// Callback function type
pub const WatchCallback = *const fn (event: WatchEvent, path: []const u8, userdata: ?*anyopaque) void;

/// File watcher for monitoring configuration file changes
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    inotify_fd: i32,
    watch_descriptors: std.ArrayList(WatchInfo),
    callback: ?WatchCallback,
    userdata: ?*anyopaque,
    running: bool,

    const WatchInfo = struct {
        wd: i32,
        path: []const u8,
    };

    const Self = @This();

    /// Initialize file watcher
    pub fn init(allocator: std.mem.Allocator) !Self {
        const fd = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (@as(isize, @bitCast(fd)) < 0) {
            return error.InotifyInitFailed;
        }

        return Self{
            .allocator = allocator,
            .inotify_fd = @intCast(fd),
            .watch_descriptors = std.ArrayList(WatchInfo).init(allocator),
            .callback = null,
            .userdata = null,
            .running = true,
        };
    }

    /// Deinitialize and clean up
    pub fn deinit(self: *Self) void {
        self.running = false;

        // Remove all watches
        for (self.watch_descriptors.items) |info| {
            _ = linux.inotify_rm_watch(@intCast(self.inotify_fd), info.wd);
            self.allocator.free(info.path);
        }
        self.watch_descriptors.deinit();

        // Close inotify fd
        _ = linux.close(@intCast(self.inotify_fd));
    }

    /// Set callback for file events
    pub fn setCallback(self: *Self, callback: WatchCallback, userdata: ?*anyopaque) void {
        self.callback = callback;
        self.userdata = userdata;
    }

    /// Add a file to watch
    pub fn addWatch(self: *Self, path: []const u8) !void {
        // We need to watch the directory containing the file, not the file itself
        // This is because editors often create a new file and rename it
        const dir_path = std.fs.path.dirname(path) orelse ".";
        const file_name = std.fs.path.basename(path);

        // Check if we're already watching this directory
        for (self.watch_descriptors.items) |info| {
            if (std.mem.eql(u8, info.path, path)) {
                return; // Already watching
            }
        }

        // Create null-terminated path for syscall
        var path_buf: [4096:0]u8 = undefined;
        if (path.len >= path_buf.len) {
            return error.PathTooLong;
        }
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        // Watch for modifications, deletions, and moves
        const mask: u32 = IN.MODIFY | IN.DELETE_SELF | IN.MOVE_SELF | IN.ATTRIB | IN.CLOSE_WRITE;

        const wd = linux.inotify_add_watch(@intCast(self.inotify_fd), @ptrCast(&path_buf), mask);
        if (@as(isize, @bitCast(wd)) < 0) {
            // File might not exist yet, watch the directory instead
            const dir_buf_len = dir_path.len;
            @memcpy(path_buf[0..dir_buf_len], dir_path);
            path_buf[dir_buf_len] = 0;

            const dir_mask: u32 = IN.CREATE | IN.MOVED_TO | IN.DELETE | IN.MOVED_FROM;
            const dir_wd = linux.inotify_add_watch(@intCast(self.inotify_fd), @ptrCast(&path_buf), dir_mask);
            if (@as(isize, @bitCast(dir_wd)) < 0) {
                return error.WatchFailed;
            }

            // Store with file name for filtering
            const path_copy = try self.allocator.dupe(u8, path);
            try self.watch_descriptors.append(.{
                .wd = @intCast(dir_wd),
                .path = path_copy,
            });
        } else {
            const path_copy = try self.allocator.dupe(u8, path);
            try self.watch_descriptors.append(.{
                .wd = @intCast(wd),
                .path = path_copy,
            });
        }

        _ = file_name;
    }

    /// Remove a watch
    pub fn removeWatch(self: *Self, path: []const u8) void {
        var i: usize = 0;
        while (i < self.watch_descriptors.items.len) {
            if (std.mem.eql(u8, self.watch_descriptors.items[i].path, path)) {
                const info = self.watch_descriptors.orderedRemove(i);
                _ = linux.inotify_rm_watch(@intCast(self.inotify_fd), info.wd);
                self.allocator.free(info.path);
            } else {
                i += 1;
            }
        }
    }

    /// Poll for file events (non-blocking)
    /// Returns number of events processed
    pub fn poll(self: *Self) i32 {
        if (!self.running) return 0;

        var event_buf: [4096]u8 align(@alignOf(InotifyEvent)) = undefined;
        const bytes_read = linux.read(@intCast(self.inotify_fd), &event_buf, event_buf.len);

        if (@as(isize, @bitCast(bytes_read)) <= 0) {
            return 0;
        }

        var events_processed: i32 = 0;
        var offset: usize = 0;

        while (offset < bytes_read) {
            const event: *const InotifyEvent = @ptrCast(@alignCast(&event_buf[offset]));

            // Find matching watch
            for (self.watch_descriptors.items) |info| {
                if (info.wd == event.wd) {
                    const watch_event = self.maskToEvent(event.mask);
                    if (watch_event != null and self.callback != null) {
                        self.callback.?(watch_event.?, info.path, self.userdata);
                        events_processed += 1;
                    }
                    break;
                }
            }

            offset += @sizeOf(InotifyEvent) + event.len;
        }

        return events_processed;
    }

    /// Convert inotify mask to WatchEvent
    fn maskToEvent(self: *Self, mask: u32) ?WatchEvent {
        _ = self;
        if ((mask & IN.MODIFY) != 0 or (mask & IN.CLOSE_WRITE) != 0) {
            return .modified;
        } else if ((mask & IN.DELETE_SELF) != 0 or (mask & IN.DELETE) != 0) {
            return .deleted;
        } else if ((mask & IN.CREATE) != 0) {
            return .created;
        } else if ((mask & IN.MOVE_SELF) != 0 or (mask & IN.MOVED_TO) != 0 or (mask & IN.MOVED_FROM) != 0) {
            return .moved;
        } else if ((mask & IN.ATTRIB) != 0) {
            return .attrib_changed;
        }
        return null;
    }

    /// Get file descriptor for polling
    pub fn getFd(self: *const Self) i32 {
        return self.inotify_fd;
    }

    /// Stop watching
    pub fn stop(self: *Self) void {
        self.running = false;
    }
};

/// Simple config file watcher that triggers reload on changes
pub const ConfigWatcher = struct {
    watcher: FileWatcher,
    config_path: []const u8,
    last_event_time: i64,
    debounce_ms: i64,
    reload_pending: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config_path: []const u8) !Self {
        var watcher = try FileWatcher.init(allocator);
        errdefer watcher.deinit();

        try watcher.addWatch(config_path);

        return Self{
            .watcher = watcher,
            .config_path = config_path,
            .last_event_time = 0,
            .debounce_ms = 500, // 500ms debounce
            .reload_pending = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.watcher.deinit();
    }

    /// Poll for config changes
    /// Returns true if config was modified and reload is needed
    pub fn poll(self: *Self) bool {
        const events = self.watcher.poll();
        if (events > 0) {
            const now = std.time.milliTimestamp();
            // Debounce: only mark as pending if enough time has passed
            if (now - self.last_event_time > self.debounce_ms) {
                self.reload_pending = true;
            }
            self.last_event_time = now;
        }

        // Check if we should trigger reload
        if (self.reload_pending) {
            const now = std.time.milliTimestamp();
            if (now - self.last_event_time >= self.debounce_ms) {
                self.reload_pending = false;
                return true;
            }
        }

        return false;
    }

    /// Stop watching
    pub fn stop(self: *Self) void {
        self.watcher.stop();
    }
};

// Tests

test "IN constants" {
    try std.testing.expect(IN.MODIFY == 0x00000002);
    try std.testing.expect(IN.DELETE == 0x00000200);
}

test "InotifyEvent size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(InotifyEvent));
}
