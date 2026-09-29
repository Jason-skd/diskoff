//! Resolves parsed storage relationships into an owned disk scope.

const std = @import("std");

pub const ResolveError = error{
    InvalidVolumePath,
    UnsupportedTarget,
    AmbiguousPhysicalDisk,
    SystemQueryFailed,
    InvalidSystemResponse,
    Canceled,
};

pub const Volume = struct {
    bsd_name: []const u8,
    mount_path: ?[]const u8,
};

pub const DiskScope = struct {
    disk_bsd_name: []const u8,
    volumes: []Volume,

    /// Releases the strings and volume list owned by this result.
    pub fn deinit(self: *DiskScope, allocator: std.mem.Allocator) void {
        allocator.free(self.disk_bsd_name);
        for (self.volumes) |volume| {
            allocator.free(volume.bsd_name);
            if (volume.mount_path) |mount_path| allocator.free(mount_path);
        }
        allocator.free(self.volumes);
        self.* = undefined;
    }
};

pub const PhysicalDisk = struct {
    bsd_name: []const u8,
    external: bool,
};

pub const TopologyVolume = struct {
    bsd_name: []const u8,
    mount_path: ?[]const u8,
    physical_disks: []const []const u8,
};

pub const Topology = struct {
    physical_disks: []const PhysicalDisk,
    volumes: []const TopologyVolume,
};

/// Resolves `input_bsd_name` to one external physical disk and its volumes.
///
/// The topology is borrowed for the duration of the call. The returned scope
/// owns independent copies and must be released with `DiskScope.deinit`.
pub fn resolveTopology(allocator: std.mem.Allocator, topology: Topology, input_bsd_name: []const u8) (ResolveError || std.mem.Allocator.Error)!DiskScope {
    const input = findVolume(topology.volumes, input_bsd_name) orelse return error.InvalidVolumePath;
    if (input.physical_disks.len == 0) return error.UnsupportedTarget;

    var physical_name: ?[]const u8 = null;
    for (input.physical_disks) |candidate_name| {
        const disk = findDisk(topology.physical_disks, candidate_name) orelse return error.InvalidSystemResponse;
        if (!disk.external) return error.UnsupportedTarget;
        if (physical_name != null and !std.mem.eql(u8, physical_name.?, disk.bsd_name)) {
            return error.AmbiguousPhysicalDisk;
        }
        physical_name = disk.bsd_name;
    }

    const disk_name = physical_name orelse return error.UnsupportedTarget;
    const disk = findDisk(topology.physical_disks, disk_name) orelse return error.InvalidSystemResponse;
    var volumes: std.ArrayList(Volume) = .empty;
    errdefer {
        for (volumes.items) |volume| {
            allocator.free(volume.bsd_name);
            if (volume.mount_path) |mount_path| allocator.free(mount_path);
        }
        volumes.deinit(allocator);
    }

    for (topology.volumes) |volume| {
        if (!volumeBelongsToDisk(volume, disk)) continue;
        if (volume.physical_disks.len != 1) return error.AmbiguousPhysicalDisk;
        if (containsVolume(volumes.items, volume.bsd_name)) continue;
        {
            const bsd_name = try allocator.dupe(u8, volume.bsd_name);
            errdefer allocator.free(bsd_name);
            const mount_path = if (volume.mount_path) |path| try allocator.dupe(u8, path) else null;
            errdefer if (mount_path) |path| allocator.free(path);
            try volumes.append(allocator, .{ .bsd_name = bsd_name, .mount_path = mount_path });
        }
    }

    if (volumes.items.len == 0) return error.InvalidSystemResponse;
    const disk_bsd_name = try allocator.dupe(u8, disk.bsd_name);
    errdefer allocator.free(disk_bsd_name);
    return .{
        .disk_bsd_name = disk_bsd_name,
        .volumes = try volumes.toOwnedSlice(allocator),
    };
}

fn findVolume(volumes: []const TopologyVolume, bsd_name: []const u8) ?TopologyVolume {
    for (volumes) |volume| if (std.mem.eql(u8, volume.bsd_name, bsd_name)) return volume;
    return null;
}

fn findDisk(disks: []const PhysicalDisk, bsd_name: []const u8) ?PhysicalDisk {
    for (disks) |disk| if (std.mem.eql(u8, disk.bsd_name, bsd_name)) return disk;
    return null;
}

fn volumeBelongsToDisk(volume: TopologyVolume, disk: PhysicalDisk) bool {
    for (volume.physical_disks) |name| if (std.mem.eql(u8, name, disk.bsd_name)) return true;
    return false;
}

fn containsVolume(volumes: []const Volume, bsd_name: []const u8) bool {
    for (volumes) |volume| if (std.mem.eql(u8, volume.bsd_name, bsd_name)) return true;
    return false;
}

test "resolveTopology returns one external disk and deduplicated volumes" {
    const disks = [_]PhysicalDisk{.{ .bsd_name = "disk0", .external = true }};
    const stores = [_][]const u8{"disk0"};
    const volumes = [_]TopologyVolume{
        .{ .bsd_name = "disk0s1", .mount_path = "/Volumes/Apps", .physical_disks = &stores },
        .{ .bsd_name = "disk0s2", .mount_path = null, .physical_disks = &stores },
        .{ .bsd_name = "disk0s1", .mount_path = "/Volumes/Apps", .physical_disks = &stores },
    };
    const scope = try resolveTopology(std.testing.allocator, .{ .physical_disks = &disks, .volumes = &volumes }, "disk0s1");
    var owned = scope;
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("disk0", owned.disk_bsd_name);
    try std.testing.expectEqual(@as(usize, 2), owned.volumes.len);
    try std.testing.expectEqualStrings("/Volumes/Apps", owned.volumes[0].mount_path.?);
    try std.testing.expect(owned.volumes[1].mount_path == null);
}

test "resolveTopology rejects multiple physical disks" {
    const disks = [_]PhysicalDisk{
        .{ .bsd_name = "disk0", .external = true },
        .{ .bsd_name = "disk1", .external = true },
    };
    const stores = [_][]const u8{ "disk0", "disk1" };
    const volumes = [_]TopologyVolume{.{ .bsd_name = "disk2", .mount_path = "/Volumes/Union", .physical_disks = &stores }};
    try std.testing.expectError(error.AmbiguousPhysicalDisk, resolveTopology(std.testing.allocator, .{ .physical_disks = &disks, .volumes = &volumes }, "disk2"));
}

test "resolveTopology rejects internal disks" {
    const disks = [_]PhysicalDisk{.{ .bsd_name = "disk0", .external = false }};
    const stores = [_][]const u8{"disk0"};
    const volumes = [_]TopologyVolume{.{ .bsd_name = "disk0s1", .mount_path = "/", .physical_disks = &stores }};
    try std.testing.expectError(error.UnsupportedTarget, resolveTopology(std.testing.allocator, .{ .physical_disks = &disks, .volumes = &volumes }, "disk0s1"));
}

test "resolveTopology rejects a sibling volume spanning another disk" {
    const disks = [_]PhysicalDisk{
        .{ .bsd_name = "disk0", .external = true },
        .{ .bsd_name = "disk1", .external = true },
    };
    const one = [_][]const u8{"disk0"};
    const two = [_][]const u8{ "disk0", "disk1" };
    const volumes = [_]TopologyVolume{
        .{ .bsd_name = "disk0s1", .mount_path = "/Volumes/One", .physical_disks = &one },
        .{ .bsd_name = "disk2s1", .mount_path = "/Volumes/Union", .physical_disks = &two },
    };
    try std.testing.expectError(error.AmbiguousPhysicalDisk, resolveTopology(std.testing.allocator, .{ .physical_disks = &disks, .volumes = &volumes }, "disk0s1"));
}

test "resolveTopology cleans partial result on allocation failure" {
    const disks = [_]PhysicalDisk{.{ .bsd_name = "disk0", .external = true }};
    const names = [_][]const u8{"disk0"};
    const volumes = [_]TopologyVolume{
        .{ .bsd_name = "disk0s1", .mount_path = "/Volumes/One", .physical_disks = &names },
        .{ .bsd_name = "disk0s2", .mount_path = null, .physical_disks = &names },
    };
    const context = struct {
        fn run(allocator: std.mem.Allocator, topology: Topology) !void {
            var result = try resolveTopology(allocator, topology, "disk0s1");
            defer result.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 2), result.volumes.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, context.run, .{Topology{ .physical_disks = &disks, .volumes = &volumes }});
}
