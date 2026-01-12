const std = @import("std");
const socket = @import("socket.zig");
const linux = std.os.linux;
const posix = std.posix;

/// Network namespace directory
pub const NETNS_PATH = "/var/run/netns";

/// Clone flags
pub const CLONE = struct {
    pub const NEWNET: u32 = 0x40000000;
};

/// Namespace info
pub const Namespace = struct {
    name: [64]u8,
    name_len: usize,

    pub fn getName(self: *const Namespace) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// List all named network namespaces
pub fn listNamespaces(allocator: std.mem.Allocator) ![]Namespace {
    var namespaces = std.ArrayList(Namespace).init(allocator);
    errdefer namespaces.deinit();

    // Open /var/run/netns directory
    var dir = std.fs.openDirAbsolute(NETNS_PATH, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            // Directory doesn't exist, no namespaces
            return namespaces.toOwnedSlice();
        }
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file or entry.kind == .sym_link) {
            var ns = Namespace{
                .name = undefined,
                .name_len = 0,
            };
            @memset(&ns.name, 0);
            const copy_len = @min(entry.name.len, ns.name.len);
            @memcpy(ns.name[0..copy_len], entry.name[0..copy_len]);
            ns.name_len = copy_len;
            try namespaces.append(ns);
        }
    }

    return namespaces.toOwnedSlice();
}

/// Create a new named network namespace
pub fn createNamespace(name: []const u8) !void {
    // Ensure /var/run/netns exists
    std.fs.makeDirAbsolute(NETNS_PATH) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    // Build path
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ NETNS_PATH, name }) catch {
        return error.NameTooLong;
    };

    // Create the namespace file (will be used as mount point)
    const file = std.fs.createFileAbsolute(path, .{}) catch |err| {
        return err;
    };
    file.close();

    // Fork a child to create the namespace
    const fork_rc = linux.fork();
    const pid: isize = @bitCast(fork_rc);

    if (pid == 0) {
        // Child process
        // Create new network namespace
        const rc = linux.unshare(CLONE.NEWNET);
        if (rc != 0) {
            linux.exit(1);
        }

        // Mount the namespace to the file
        // mount("/proc/self/ns/net", path, NULL, MS_BIND, NULL)
        const src = "/proc/self/ns/net";
        var src_buf: [32]u8 = undefined;
        @memcpy(src_buf[0..src.len], src);
        src_buf[src.len] = 0;

        var dst_buf: [128]u8 = undefined;
        @memcpy(dst_buf[0..path.len], path);
        dst_buf[path.len] = 0;

        const mount_rc = linux.mount(
            @ptrCast(&src_buf),
            @ptrCast(&dst_buf),
            null,
            linux.MS.BIND,
            0,
        );

        if (mount_rc != 0) {
            linux.exit(2);
        }

        linux.exit(0);
    } else if (pid < 0) {
        // Fork failed
        // Clean up the file we created
        std.fs.deleteFileAbsolute(path) catch {};
        return error.ForkFailed;
    } else {
        // Parent process - wait for child
        var status: u32 = 0;
        _ = linux.waitpid(@intCast(pid), &status, 0);

        // Check if child succeeded
        if (linux.W.IFEXITED(status)) {
            const exit_code = linux.W.EXITSTATUS(status);
            if (exit_code != 0) {
                std.fs.deleteFileAbsolute(path) catch {};
                return if (exit_code == 1) error.UnshareFailedChild else error.MountFailed;
            }
        } else {
            std.fs.deleteFileAbsolute(path) catch {};
            return error.ChildFailed;
        }
    }
}

/// Delete a named network namespace
pub fn deleteNamespace(name: []const u8) !void {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ NETNS_PATH, name }) catch {
        return error.NameTooLong;
    };

    // Unmount the namespace
    var path_z: [128]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    // Try to unmount (may fail if not mounted, that's ok)
    _ = linux.umount(@ptrCast(&path_z));

    // Delete the file
    std.fs.deleteFileAbsolute(path) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };
}

/// Check if a namespace exists
pub fn namespaceExists(name: []const u8) bool {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ NETNS_PATH, name }) catch {
        return false;
    };

    std.fs.accessAbsolute(path, .{}) catch {
        return false;
    };
    return true;
}

/// Open a namespace file descriptor
pub fn openNamespace(name: []const u8) !posix.fd_t {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ NETNS_PATH, name }) catch {
        return error.NameTooLong;
    };

    const file = try std.fs.openFileAbsolute(path, .{});
    return file.handle;
}

/// Enter a network namespace (affects current process)
pub fn enterNamespace(name: []const u8) !void {
    const fd = try openNamespace(name);
    defer posix.close(fd);

    // setns(fd, CLONE_NEWNET)
    const rc = linux.syscall2(.setns, @intCast(fd), CLONE.NEWNET);
    if (@as(isize, @bitCast(rc)) < 0) {
        return error.SetnsFailedEnterNs;
    }
}

/// Move an interface to another namespace
pub fn moveInterfaceToNamespace(if_index: i32, ns_name: []const u8) !void {
    const ns_fd = try openNamespace(ns_name);
    defer posix.close(ns_fd);

    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = if_index,
    });

    // Add IFLA_NET_NS_FD attribute
    try builder.addAttrU32(socket.IFLA.NET_NS_FD, @intCast(ns_fd));

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Move an interface to a namespace by PID
pub fn moveInterfaceToPid(if_index: i32, pid: i32) !void {
    var nl = try socket.NetlinkSocket.open();
    defer nl.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [256]u8 = undefined;
    var builder = socket.MessageBuilder.init(&buf, nl.nextSeq(), nl.pid);

    const hdr = try builder.addHeader(socket.RTM.SETLINK, socket.NLM_F.REQUEST | socket.NLM_F.ACK);
    try builder.addData(socket.IfInfoMsg, socket.IfInfoMsg{
        .index = if_index,
    });

    // Add IFLA_NET_NS_PID attribute
    try builder.addAttrU32(socket.IFLA.NET_NS_PID, @intCast(pid));

    const msg = builder.finalize(hdr);
    const response = try nl.request(msg, allocator);
    allocator.free(response);
}

/// Execute a command in a namespace
pub fn execInNamespace(allocator: std.mem.Allocator, ns_name: []const u8, argv: []const []const u8) !std.process.Child.Term {
    // We need to fork, enter namespace, then exec
    const fork_rc = linux.fork();
    const pid: isize = @bitCast(fork_rc);

    if (pid == 0) {
        // Child process - enter namespace and exec
        enterNamespace(ns_name) catch {
            linux.exit(126);
        };

        // Build null-terminated argv
        var args = allocator.alloc(?[*:0]const u8, argv.len + 1) catch {
            linux.exit(127);
        };
        defer allocator.free(args);

        for (argv, 0..) |arg, i| {
            args[i] = allocator.dupeZ(u8, arg) catch {
                linux.exit(127);
            };
        }
        args[argv.len] = null;

        // Exec
        const err = linux.execve(
            args[0].?,
            @ptrCast(args.ptr),
            @ptrCast(std.os.environ.ptr),
        );
        _ = err;
        linux.exit(127);
    } else if (pid < 0) {
        return error.ForkFailed;
    } else {
        // Parent - wait for child
        var status: u32 = 0;
        _ = linux.waitpid(@intCast(pid), &status, 0);

        if (linux.W.IFEXITED(status)) {
            return .{ .Exited = linux.W.EXITSTATUS(status) };
        } else if (linux.W.IFSIGNALED(status)) {
            return .{ .Signal = linux.W.TERMSIG(status) };
        } else {
            return .{ .Exited = 1 };
        }
    }
}

// Tests

test "NETNS_PATH" {
    try std.testing.expectEqualStrings("/var/run/netns", NETNS_PATH);
}
