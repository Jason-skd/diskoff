//! macOS queries and property-list decoding. Foreign handles never escape this file.

const std = @import("std");
const scope = @import("disk_scope.zig");
const Allocator = std.mem.Allocator;
const Error = scope.ResolveError || Allocator.Error;

// The declarations follow the macOS SDK's CoreFoundation and DiskArbitration headers.
const cf = struct {
    const Ref = *const anyopaque;
    const Session = opaque {};
    const Disk = opaque {};
    const utf8: u32 = 0x08000100;

    extern fn CFRelease(Ref) void;
    extern fn CFGetTypeID(Ref) c_ulong;
    extern fn CFStringGetTypeID() c_ulong;
    extern fn CFArrayGetTypeID() c_ulong;
    extern fn CFDictionaryGetTypeID() c_ulong;
    extern fn CFURLGetTypeID() c_ulong;
    extern fn CFStringCreateWithBytes(?Ref, [*]const u8, c_long, u32, u8) ?Ref;
    extern fn CFStringGetLength(Ref) c_long;
    extern fn CFStringGetMaximumSizeForEncoding(c_long, u32) c_long;
    extern fn CFStringGetCString(Ref, [*]u8, c_long, u32) u8;
    extern fn CFDictionaryGetValue(Ref, Ref) ?Ref;
    extern fn CFArrayGetCount(Ref) c_long;
    extern fn CFArrayGetValueAtIndex(Ref, c_long) ?Ref;
    extern fn CFDataCreate(?Ref, [*]const u8, c_long) ?Ref;
    extern fn CFPropertyListCreateWithData(?Ref, Ref, c_ulong, ?*c_long, ?*?Ref) ?Ref;
    extern fn CFURLCreateFromFileSystemRepresentation(?Ref, [*]const u8, c_long, u8) ?Ref;
    extern fn CFURLCopyFileSystemPath(Ref, c_long) ?Ref;
    extern fn DASessionCreate(?Ref) ?*Session;
    extern fn DADiskCreateFromVolumePath(?Ref, *Session, Ref) ?*Disk;
    extern fn DADiskGetBSDName(*Disk) ?[*:0]const u8;
    extern fn DADiskCopyDescription(*Disk) ?Ref;
    extern const kDADiskDescriptionVolumePathKey: Ref;
};

pub fn resolve(allocator: Allocator, io: std.Io, mount_path: []const u8) Error!scope.DiskScope {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    try io.checkCancel();
    const input = try inputVolume(temporary, mount_path);
    try io.checkCancel();

    const physical = try query(temporary, io, &.{ "/usr/sbin/diskutil", "list", "-plist", "physical" });
    defer cf.CFRelease(physical);
    const external = try query(temporary, io, &.{ "/usr/sbin/diskutil", "list", "-plist", "physical", "external" });
    defer cf.CFRelease(external);
    const all = try query(temporary, io, &.{ "/usr/sbin/diskutil", "list", "-plist" });
    defer cf.CFRelease(all);
    const topology = try parseTopology(temporary, physical, external, all);
    const volume = for (topology.volumes) |volume| {
        if (std.mem.eql(u8, input, volume.bsd_name)) break volume;
    } else return error.UnsupportedTarget;
    // A disappeared or remounted input must not yield a stale scope.
    if (volume.mount_path == null or !std.mem.eql(u8, trimPath(mount_path), volume.mount_path.?))
        return error.InvalidVolumePath;
    try io.checkCancel();
    return scope.resolveTopology(allocator, topology, input);
}

fn trimPath(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
    return path[0..end];
}

fn inputVolume(allocator: Allocator, mount_path: []const u8) Error![]const u8 {
    if (mount_path.len == 0 or mount_path[0] != '/' or std.mem.indexOfScalar(u8, mount_path, 0) != null)
        return error.InvalidVolumePath;
    const path = trimPath(mount_path);
    const session = cf.DASessionCreate(null) orelse return error.SystemQueryFailed;
    defer cf.CFRelease(session);
    const url = cf.CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 1) orelse return error.InvalidVolumePath;
    defer cf.CFRelease(url);
    const disk = cf.DADiskCreateFromVolumePath(null, session, url) orelse return error.InvalidVolumePath;
    defer cf.CFRelease(disk);
    const description = cf.DADiskCopyDescription(disk) orelse return error.SystemQueryFailed;
    defer cf.CFRelease(description);
    const volume_url = cf.CFDictionaryGetValue(description, cf.kDADiskDescriptionVolumePathKey) orelse return error.InvalidVolumePath;
    if (cf.CFGetTypeID(volume_url) != cf.CFURLGetTypeID()) return error.InvalidSystemResponse;
    const actual = cf.CFURLCopyFileSystemPath(volume_url, 0) orelse return error.SystemQueryFailed;
    defer cf.CFRelease(actual);
    const actual_path = try string(allocator, actual);
    defer allocator.free(actual_path);
    if (!std.mem.eql(u8, path, actual_path)) return error.InvalidVolumePath;
    const name = cf.DADiskGetBSDName(disk) orelse return error.UnsupportedTarget;
    return allocator.dupe(u8, std.mem.span(name));
}

fn query(allocator: Allocator, io: std.Io, argv: []const []const u8) Error!cf.Ref {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .none,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SystemQueryFailed,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SystemQueryFailed,
        else => return error.SystemQueryFailed,
    }
    return parsePlist(result.stdout);
}

fn parsePlist(bytes: []const u8) Error!cf.Ref {
    const data = cf.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
    defer cf.CFRelease(data);
    const value = cf.CFPropertyListCreateWithData(null, data, 0, null, null) orelse return error.InvalidSystemResponse;
    errdefer cf.CFRelease(value);
    if (cf.CFGetTypeID(value) != cf.CFDictionaryGetTypeID()) return error.InvalidSystemResponse;
    return value;
}

fn field(dict: cf.Ref, key: []const u8) Error!?cf.Ref {
    if (cf.CFGetTypeID(dict) != cf.CFDictionaryGetTypeID()) return error.InvalidSystemResponse;
    const name = cf.CFStringCreateWithBytes(null, key.ptr, @intCast(key.len), cf.utf8, 0) orelse return error.OutOfMemory;
    defer cf.CFRelease(name);
    return cf.CFDictionaryGetValue(dict, name);
}

fn required(dict: cf.Ref, key: []const u8) Error!cf.Ref {
    return try field(dict, key) orelse error.InvalidSystemResponse;
}

fn string(allocator: Allocator, value: cf.Ref) Error![]const u8 {
    if (cf.CFGetTypeID(value) != cf.CFStringGetTypeID()) return error.InvalidSystemResponse;
    const max = cf.CFStringGetMaximumSizeForEncoding(cf.CFStringGetLength(value), cf.utf8);
    if (max < 0 or max == std.math.maxInt(c_long)) return error.InvalidSystemResponse;
    const buffer = try allocator.alloc(u8, @intCast(max + 1));
    defer allocator.free(buffer);
    if (cf.CFStringGetCString(value, buffer.ptr, @intCast(buffer.len), cf.utf8) == 0) return error.InvalidSystemResponse;
    return allocator.dupe(u8, std.mem.sliceTo(buffer, 0));
}

fn textField(allocator: Allocator, dict: cf.Ref, key: []const u8) Error![]const u8 {
    return string(allocator, try required(dict, key));
}

const Array = struct {
    value: cf.Ref,
    len: usize,

    fn init(value: cf.Ref) Error!Array {
        if (cf.CFGetTypeID(value) != cf.CFArrayGetTypeID()) return error.InvalidSystemResponse;
        const count = cf.CFArrayGetCount(value);
        if (count < 0) return error.InvalidSystemResponse;
        return .{ .value = value, .len = @intCast(count) };
    }

    fn at(self: Array, index: usize) Error!cf.Ref {
        return cf.CFArrayGetValueAtIndex(self.value, @intCast(index)) orelse error.InvalidSystemResponse;
    }
};

const Owner = struct { device: []const u8, disk: []const u8 };

// All allocations belong to the query arena; the resolver copies the final result.
fn parseTopology(arena: Allocator, physical: cf.Ref, external: cf.Ref, all: cf.Ref) Error!scope.Topology {
    const external_names = try Array.init(try required(external, "WholeDisks"));
    const physical_entries = try Array.init(try required(physical, "AllDisksAndPartitions"));
    var disks: std.ArrayList(scope.PhysicalDisk) = .empty;
    var owners: std.ArrayList(Owner) = .empty;
    var volumes: std.ArrayList(scope.TopologyVolume) = .empty;
    for (0..physical_entries.len) |i| {
        const entry = try physical_entries.at(i);
        const name = try textField(arena, entry, "DeviceIdentifier");
        var is_external = false;
        for (0..external_names.len) |j| {
            if (std.mem.eql(u8, name, try string(arena, try external_names.at(j)))) is_external = true;
        }
        for (disks.items) |disk| if (std.mem.eql(u8, name, disk.bsd_name)) return error.InvalidSystemResponse;
        try disks.append(arena, .{ .bsd_name = name, .external = is_external });
        try addOwner(arena, &owners, name, name);
        const disk_names = try arena.alloc([]const u8, 1);
        disk_names[0] = name;
        try appendVolume(arena, &volumes, entry, disk_names, false);
        if (try field(entry, "Partitions")) |parts_value| {
            const parts = try Array.init(parts_value);
            for (0..parts.len) |j| {
                const part = try parts.at(j);
                try addOwner(arena, &owners, try textField(arena, part, "DeviceIdentifier"), name);
                try appendVolume(arena, &volumes, part, disk_names, false);
            }
        }
    }
    // The separately filtered query must agree with the physical inventory.
    for (0..external_names.len) |i| {
        const name = try string(arena, try external_names.at(i));
        if (findOwner(owners.items, name) == null) return error.InvalidSystemResponse;
    }
    const entries = try Array.init(try required(all, "AllDisksAndPartitions"));
    for (0..entries.len) |i| {
        const entry = try entries.at(i);
        const apfs_value = try field(entry, "APFSVolumes") orelse continue;
        const stores = try Array.init(try required(entry, "APFSPhysicalStores"));
        if (stores.len == 0) return error.InvalidSystemResponse;
        var backing: std.ArrayList([]const u8) = .empty;
        var supported = true;
        for (0..stores.len) |j| {
            const store = try textField(arena, try stores.at(j), "DeviceIdentifier");
            if (findOwner(owners.items, store)) |disk| {
                try backing.append(arena, disk);
            } else supported = false;
        }
        const apfs = try Array.init(apfs_value);
        for (0..apfs.len) |j| {
            try appendVolume(arena, &volumes, try apfs.at(j), if (supported) backing.items else &.{}, true);
        }
    }
    return .{ .physical_disks = disks.items, .volumes = volumes.items };
}

fn addOwner(arena: Allocator, owners: *std.ArrayList(Owner), device: []const u8, disk: []const u8) Error!void {
    if (findOwner(owners.items, device) != null) return error.InvalidSystemResponse;
    try owners.append(arena, .{ .device = device, .disk = disk });
}

fn findOwner(owners: []const Owner, device: []const u8) ?[]const u8 {
    for (owners) |owner| if (std.mem.eql(u8, owner.device, device)) return owner.disk;
    return null;
}

fn appendVolume(arena: Allocator, volumes: *std.ArrayList(scope.TopologyVolume), entry: cf.Ref, disks: []const []const u8, apfs: bool) Error!void {
    const mount = if (try field(entry, "MountPoint")) |value| try string(arena, value) else null;
    // Partition-map entries and APFS physical stores are not filesystem volumes.
    if (!apfs and mount == null and try field(entry, "VolumeName") == null) return;
    const name = try textField(arena, entry, "DeviceIdentifier");
    try volumes.append(arena, .{ .bsd_name = name, .mount_path = mount, .physical_disks = disks });
}

test "invalid paths are rejected before system queries" {
    try std.testing.expectError(error.InvalidVolumePath, resolve(std.testing.allocator, std.testing.io, ""));
    try std.testing.expectError(error.InvalidVolumePath, resolve(std.testing.allocator, std.testing.io, "relative"));
    try std.testing.expectError(error.InvalidVolumePath, resolve(std.testing.allocator, std.testing.io, "/Volumes/a\x00b"));
}

test "plist rejects malformed input and non-dictionary roots" {
    try std.testing.expectError(error.InvalidSystemResponse, parsePlist("not a plist"));
    try std.testing.expectError(error.InvalidSystemResponse, parsePlist("<plist version=\"1.0\"><array/></plist>"));
}

test "plist topology follows APFS stores and distinguishes mounted volumes" {
    const physical = try parsePlist(
        \\<plist version="1.0"><dict><key>AllDisksAndPartitions</key><array>
        \\<dict><key>DeviceIdentifier</key><string>disk4</string><key>Partitions</key><array>
        \\<dict><key>DeviceIdentifier</key><string>disk4s1</string></dict></array></dict>
        \\<dict><key>DeviceIdentifier</key><string>disk5</string></dict>
        \\</array></dict></plist>
    );
    defer cf.CFRelease(physical);
    const external = try parsePlist(
        \\<plist version="1.0"><dict><key>WholeDisks</key><array>
        \\<string>disk4</string></array></dict></plist>
    );
    defer cf.CFRelease(external);
    const all = try parsePlist(
        \\<plist version="1.0"><dict><key>AllDisksAndPartitions</key><array>
        \\<dict><key>DeviceIdentifier</key><string>disk6</string>
        \\<key>APFSPhysicalStores</key><array><dict><key>DeviceIdentifier</key><string>disk4s1</string></dict></array>
        \\<key>APFSVolumes</key><array>
        \\<dict><key>DeviceIdentifier</key><string>disk6s1</string><key>MountPoint</key><string>/Volumes/A &amp; B</string></dict>
        \\<dict><key>DeviceIdentifier</key><string>disk6s2</string></dict>
        \\</array></dict></array></dict></plist>
    );
    defer cf.CFRelease(all);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const topology = try parseTopology(arena.allocator(), physical, external, all);
    var result = try scope.resolveTopology(std.testing.allocator, topology, "disk6s1");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("disk4", result.disk_bsd_name);
    try std.testing.expectEqual(@as(usize, 2), result.volumes.len);
    try std.testing.expectEqualStrings("/Volumes/A & B", result.volumes[0].mount_path.?);
    try std.testing.expect(result.volumes[1].mount_path == null);
}

test "input path maps through Disk Arbitration on macOS" {
    const name = try inputVolume(std.testing.allocator, "/");
    defer std.testing.allocator.free(name);
    try std.testing.expect(std.mem.startsWith(u8, name, "disk"));
    try std.testing.expectError(error.InvalidVolumePath, inputVolume(std.testing.allocator, "/tmp"));
}
