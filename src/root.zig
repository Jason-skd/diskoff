//! Read-only identification of macOS external physical disks and their volumes.

const std = @import("std");
const Io = std.Io;

const disk_scope = @import("disk_scope.zig");
pub const DiskScope = disk_scope.DiskScope;
pub const ResolveError = disk_scope.ResolveError;
pub const Volume = disk_scope.Volume;

/// Resolves a mounted volume path to its external physical disk and volumes.
/// Accepts an exact mount point (trailing slashes are allowed), not a subpath.
/// Rejects unsupported targets or associated backing, and scopes spanning multiple physical disks.
/// The result includes unmounted volumes and does not lock the device topology.
/// The caller owns the returned scope and releases it with `DiskScope.deinit`.
pub fn resolveDiskScope(allocator: std.mem.Allocator, io: Io, mount_path: []const u8) (ResolveError || std.mem.Allocator.Error)!DiskScope {
    return @import("macos_disk.zig").resolve(allocator, io, mount_path);
}

test {
    _ = @import("disk_scope.zig");
    _ = @import("macos_disk.zig");
}
