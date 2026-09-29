//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

const disk_scope = @import("disk_scope.zig");
pub const DiskScope = disk_scope.DiskScope;
pub const ResolveError = disk_scope.ResolveError;
pub const Volume = disk_scope.Volume;

/// Resolves a mounted volume path to its external physical disk and volumes.
/// The caller owns the returned scope and releases it with `DiskScope.deinit`.
pub fn resolveDiskScope(allocator: std.mem.Allocator, io: Io, mount_path: []const u8) (ResolveError || std.mem.Allocator.Error)!DiskScope {
    return @import("macos_disk.zig").resolve(allocator, io, mount_path);
}

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test {
    _ = @import("disk_scope.zig");
    _ = @import("macos_disk.zig");
}
