const std = @import("std");

/// Global single-threaded Io for modules that don't have io threaded through.
pub fn globalIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Dir = std.Io.Dir;

/// openFileAbsolute wrapper using global Io.
pub fn openFileAbsolute(absolute_path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
    return std.Io.Dir.openFileAbsolute(globalIo(), absolute_path, options);
}

/// openDirAbsolute wrapper using global Io.
pub fn openDirAbsolute(absolute_path: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(globalIo(), absolute_path, options);
}

/// createFileAbsolute wrapper using global Io.
pub fn createFileAbsolute(absolute_path: []const u8, flags: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
    return std.Io.Dir.createFileAbsolute(globalIo(), absolute_path, flags);
}

/// deleteFileAbsolute wrapper using global Io.
pub fn deleteFileAbsolute(absolute_path: []const u8) std.Io.Dir.DeleteFileError!void {
    return std.Io.Dir.deleteFileAbsolute(globalIo(), absolute_path);
}

/// makeDirAbsolute wrapper using global Io.
pub fn makeDirAbsolute(absolute_path: []const u8) std.Io.Dir.MakeDirError!void {
    return std.Io.Dir.makeDirAbsolute(globalIo(), absolute_path);
}

/// accessAbsolute wrapper using global Io.
pub fn accessAbsolute(absolute_path: []const u8, options: std.Io.Dir.AccessOptions) std.Io.Dir.AccessError!void {
    return std.Io.Dir.accessAbsolute(globalIo(), absolute_path, options);
}

/// cwd wrapper.
pub fn cwd() Dir {
    return Dir.cwd();
}

// Re-export path utilities
pub const path = Dir.path;
pub const max_path_bytes = std.Io.Dir.max_path_bytes;

/// Compatibility wrapper: returns Unix epoch seconds (i64).
/// Replaces the removed std.time.timestamp().
pub fn timestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// Compatibility wrapper: returns milliseconds since epoch (i64).
/// Replaces the removed std.time.milliTimestamp().
pub fn milliTimestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Compatibility wrapper: returns microseconds since epoch (i64).
/// Replaces the removed std.time.microTimestamp().
pub fn microTimestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000);
}
