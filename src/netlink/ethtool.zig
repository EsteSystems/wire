const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

/// Ethtool IOCTL command codes
pub const ETHTOOL = struct {
    pub const GDRVINFO: u32 = 0x00000003;
    pub const GRINGPARAM: u32 = 0x00000010;
    pub const SRINGPARAM: u32 = 0x00000011;
    pub const GCOALESCE: u32 = 0x0000000e;
    pub const SCOALESCE: u32 = 0x0000000f;
    pub const GFEATURES: u32 = 0x0000003a;
    pub const SFEATURES: u32 = 0x0000003b;
    pub const GSTRINGS: u32 = 0x0000001b;
    pub const GSSET_INFO: u32 = 0x00000037;
    pub const GLINK: u32 = 0x0000000a;

    // String set IDs
    pub const SS_FEATURES: u32 = 4;
};

/// Interface flags (for getting interface index)
pub const SIOCGIFINDEX: u32 = 0x8933;
pub const SIOCETHTOOL: u32 = 0x8946;

/// Interface request structure
pub const IfReq = extern struct {
    name: [16]u8 = [_]u8{0} ** 16,
    data: extern union {
        ifindex: i32,
        data_ptr: usize,
    } = .{ .ifindex = 0 },
};

/// Driver info
pub const EthtoolDrvInfo = extern struct {
    cmd: u32 = ETHTOOL.GDRVINFO,
    driver: [32]u8 = [_]u8{0} ** 32,
    version: [32]u8 = [_]u8{0} ** 32,
    fw_version: [32]u8 = [_]u8{0} ** 32,
    bus_info: [32]u8 = [_]u8{0} ** 32,
    erom_version: [32]u8 = [_]u8{0} ** 32,
    reserved2: [12]u8 = [_]u8{0} ** 12,
    n_priv_flags: u32 = 0,
    n_stats: u32 = 0,
    testinfo_len: u32 = 0,
    eedump_len: u32 = 0,
    regdump_len: u32 = 0,
};

/// Ring parameters
pub const EthtoolRingParam = extern struct {
    cmd: u32 = ETHTOOL.GRINGPARAM,
    rx_max_pending: u32 = 0,
    rx_mini_max_pending: u32 = 0,
    rx_jumbo_max_pending: u32 = 0,
    tx_max_pending: u32 = 0,
    rx_pending: u32 = 0,
    rx_mini_pending: u32 = 0,
    rx_jumbo_pending: u32 = 0,
    tx_pending: u32 = 0,
};

/// Coalesce parameters
pub const EthtoolCoalesce = extern struct {
    cmd: u32 = ETHTOOL.GCOALESCE,
    rx_coalesce_usecs: u32 = 0,
    rx_max_coalesced_frames: u32 = 0,
    rx_coalesce_usecs_irq: u32 = 0,
    rx_max_coalesced_frames_irq: u32 = 0,
    tx_coalesce_usecs: u32 = 0,
    tx_max_coalesced_frames: u32 = 0,
    tx_coalesce_usecs_irq: u32 = 0,
    tx_max_coalesced_frames_irq: u32 = 0,
    stats_block_coalesce_usecs: u32 = 0,
    use_adaptive_rx_coalesce: u32 = 0,
    use_adaptive_tx_coalesce: u32 = 0,
    pkt_rate_low: u32 = 0,
    rx_coalesce_usecs_low: u32 = 0,
    rx_max_coalesced_frames_low: u32 = 0,
    tx_coalesce_usecs_low: u32 = 0,
    tx_max_coalesced_frames_low: u32 = 0,
    pkt_rate_high: u32 = 0,
    rx_coalesce_usecs_high: u32 = 0,
    rx_max_coalesced_frames_high: u32 = 0,
    tx_coalesce_usecs_high: u32 = 0,
    tx_max_coalesced_frames_high: u32 = 0,
    rate_sample_interval: u32 = 0,
};

/// Link status
pub const EthtoolValue = extern struct {
    cmd: u32 = 0,
    data: u32 = 0,
};

/// Feature flags (get)
pub const EthtoolGfeatures = extern struct {
    cmd: u32 = ETHTOOL.GFEATURES,
    size: u32 = 0,
    // Followed by size * EthtoolGetFeaturesBlock
};

/// Feature block
pub const EthtoolGetFeaturesBlock = extern struct {
    available: u32 = 0,
    requested: u32 = 0,
    active: u32 = 0,
    never_changed: u32 = 0,
};

/// Driver info result (copies data so it's safe to use after function returns)
pub const DriverInfo = struct {
    driver: [32]u8,
    driver_len: usize,
    version: [32]u8,
    version_len: usize,
    firmware: [32]u8,
    firmware_len: usize,
    bus: [32]u8,
    bus_len: usize,

    pub fn getDriver(self: *const DriverInfo) []const u8 {
        return self.driver[0..self.driver_len];
    }

    pub fn getVersion(self: *const DriverInfo) []const u8 {
        return self.version[0..self.version_len];
    }

    pub fn getFirmware(self: *const DriverInfo) []const u8 {
        return self.firmware[0..self.firmware_len];
    }

    pub fn getBus(self: *const DriverInfo) []const u8 {
        return self.bus[0..self.bus_len];
    }
};

/// Ring parameters result
pub const RingParams = struct {
    rx_max: u32,
    rx_current: u32,
    tx_max: u32,
    tx_current: u32,
};

/// Coalesce parameters result
pub const CoalesceParams = struct {
    rx_usecs: u32,
    rx_frames: u32,
    tx_usecs: u32,
    tx_frames: u32,
    adaptive_rx: bool,
    adaptive_tx: bool,
};

/// Offload features
pub const OffloadFeatures = struct {
    rx_checksumming: bool = false,
    tx_checksumming: bool = false,
    scatter_gather: bool = false,
    tcp_segmentation: bool = false, // TSO
    udp_fragmentation: bool = false, // UFO
    generic_segmentation: bool = false, // GSO
    generic_receive: bool = false, // GRO
    large_receive: bool = false, // LRO
    rx_vlan: bool = false,
    tx_vlan: bool = false,
    ntuple_filters: bool = false,
    receive_hashing: bool = false,
};

/// Open a socket for ethtool ioctls
fn openSocket() !posix.fd_t {
    const fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (@as(isize, @bitCast(fd)) < 0) {
        return error.SocketFailed;
    }
    return @intCast(fd);
}

/// Get interface index by name
fn getIfIndex(fd: posix.fd_t, name: []const u8) !i32 {
    var ifr = IfReq{};
    const copy_len = @min(name.len, 15);
    @memcpy(ifr.name[0..copy_len], name[0..copy_len]);

    const rc = linux.ioctl(fd, SIOCGIFINDEX, @intFromPtr(&ifr));
    if (@as(isize, @bitCast(rc)) < 0) {
        return error.InterfaceNotFound;
    }
    return ifr.data.ifindex;
}

/// Execute ethtool ioctl
fn ethtoolIoctl(fd: posix.fd_t, name: []const u8, data: *anyopaque) !void {
    var ifr = IfReq{};
    const copy_len = @min(name.len, 15);
    @memcpy(ifr.name[0..copy_len], name[0..copy_len]);
    ifr.data.data_ptr = @intFromPtr(data);

    const rc = linux.ioctl(fd, SIOCETHTOOL, @intFromPtr(&ifr));
    if (@as(isize, @bitCast(rc)) < 0) {
        return error.EthtoolFailed;
    }
}

/// Get driver info for an interface
pub fn getDriverInfo(name: []const u8) !DriverInfo {
    const fd = try openSocket();
    defer posix.close(fd);

    var info = EthtoolDrvInfo{};
    ethtoolIoctl(fd, name, @ptrCast(&info)) catch {
        return error.GetDriverInfoFailed;
    };

    // Find null terminators
    var driver_len: usize = 0;
    for (info.driver) |c| {
        if (c == 0) break;
        driver_len += 1;
    }

    var version_len: usize = 0;
    for (info.version) |c| {
        if (c == 0) break;
        version_len += 1;
    }

    var fw_len: usize = 0;
    for (info.fw_version) |c| {
        if (c == 0) break;
        fw_len += 1;
    }

    var bus_len: usize = 0;
    for (info.bus_info) |c| {
        if (c == 0) break;
        bus_len += 1;
    }

    // Copy data to result struct
    var result = DriverInfo{
        .driver = undefined,
        .driver_len = driver_len,
        .version = undefined,
        .version_len = version_len,
        .firmware = undefined,
        .firmware_len = fw_len,
        .bus = undefined,
        .bus_len = bus_len,
    };

    @memcpy(&result.driver, &info.driver);
    @memcpy(&result.version, &info.version);
    @memcpy(&result.firmware, &info.fw_version);
    @memcpy(&result.bus, &info.bus_info);

    return result;
}

/// Get ring buffer parameters
pub fn getRingParams(name: []const u8) !RingParams {
    const fd = try openSocket();
    defer posix.close(fd);

    var ring = EthtoolRingParam{};
    ethtoolIoctl(fd, name, @ptrCast(&ring)) catch {
        return error.GetRingParamsFailed;
    };

    return RingParams{
        .rx_max = ring.rx_max_pending,
        .rx_current = ring.rx_pending,
        .tx_max = ring.tx_max_pending,
        .tx_current = ring.tx_pending,
    };
}

/// Set ring buffer parameters
pub fn setRingParams(name: []const u8, rx: ?u32, tx: ?u32) !void {
    const fd = try openSocket();
    defer posix.close(fd);

    // First get current params
    var ring = EthtoolRingParam{};
    ethtoolIoctl(fd, name, @ptrCast(&ring)) catch {
        return error.GetRingParamsFailed;
    };

    // Update with new values
    ring.cmd = ETHTOOL.SRINGPARAM;
    if (rx) |r| ring.rx_pending = r;
    if (tx) |t| ring.tx_pending = t;

    ethtoolIoctl(fd, name, @ptrCast(&ring)) catch {
        return error.SetRingParamsFailed;
    };
}

/// Get coalesce parameters
pub fn getCoalesceParams(name: []const u8) !CoalesceParams {
    const fd = try openSocket();
    defer posix.close(fd);

    var coal = EthtoolCoalesce{};
    ethtoolIoctl(fd, name, @ptrCast(&coal)) catch {
        return error.GetCoalesceFailed;
    };

    return CoalesceParams{
        .rx_usecs = coal.rx_coalesce_usecs,
        .rx_frames = coal.rx_max_coalesced_frames,
        .tx_usecs = coal.tx_coalesce_usecs,
        .tx_frames = coal.tx_max_coalesced_frames,
        .adaptive_rx = coal.use_adaptive_rx_coalesce != 0,
        .adaptive_tx = coal.use_adaptive_tx_coalesce != 0,
    };
}

/// Set coalesce parameters
pub fn setCoalesceParams(name: []const u8, rx_usecs: ?u32, tx_usecs: ?u32) !void {
    const fd = try openSocket();
    defer posix.close(fd);

    // First get current params
    var coal = EthtoolCoalesce{};
    ethtoolIoctl(fd, name, @ptrCast(&coal)) catch {
        return error.GetCoalesceFailed;
    };

    // Update with new values
    coal.cmd = ETHTOOL.SCOALESCE;
    if (rx_usecs) |r| coal.rx_coalesce_usecs = r;
    if (tx_usecs) |t| coal.tx_coalesce_usecs = t;

    ethtoolIoctl(fd, name, @ptrCast(&coal)) catch {
        return error.SetCoalesceFailed;
    };
}

/// Check if link is up (carrier)
pub fn getLinkStatus(name: []const u8) !bool {
    const fd = try openSocket();
    defer posix.close(fd);

    var link = EthtoolValue{ .cmd = ETHTOOL.GLINK };
    ethtoolIoctl(fd, name, @ptrCast(&link)) catch {
        return error.GetLinkFailed;
    };

    return link.data != 0;
}

// Tests

test "EthtoolDrvInfo size" {
    try std.testing.expectEqual(@as(usize, 196), @sizeOf(EthtoolDrvInfo));
}

test "EthtoolRingParam size" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(EthtoolRingParam));
}
