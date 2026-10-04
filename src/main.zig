//! Read-only CLI orchestration; disk identification belongs to the library.

const std = @import("std");
const Io = std.Io;
const clap = @import("clap");
const diskoff = @import("diskoff");

const params = clap.parseParamsComptime(
    \\-h, --help      Display this help and exit.
    \\<MOUNT_POINT>... Resolve one mounted volume to its external disk and volumes.
    \\
);
const parsers = .{ .MOUNT_POINT = clap.parsers.string };

pub fn main(init: std.process.Init) u8 {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    var stderr: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.debug.print("diskoff: not enough memory to read arguments.\n", .{});
        return 1;
    };
    const status = run(init.gpa, init.io, args[1..], &stdout.interface, &stderr.interface) catch |err| {
        if (err == error.Canceled or writeCanceled(&stdout) or writeCanceled(&stderr)) return 130;
        std.debug.print("diskoff: {s}\n", .{if (err == error.OutOfMemory) "not enough memory." else "unable to write output."});
        return 1;
    };
    stdout.flush() catch |err| return if (err == error.Canceled) 130 else 1;
    stderr.flush() catch |err| return if (err == error.Canceled) 130 else 1;
    return status;
}

fn writeCanceled(writer: *Io.File.Writer) bool {
    const err = writer.err orelse return false;
    return err == error.Canceled;
}

fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    var iter: clap.args.SliceIterator = .{ .args = args };
    var diagnostic: clap.Diagnostic = .{};
    var parsed = clap.parseEx(clap.Help, &params, parsers, &iter, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        try diagnostic.report(stderr, err);
        return 2;
    };
    defer parsed.deinit();

    if (parsed.args.help != 0) {
        try stdout.writeAll("Usage: diskoff [--help] MOUNT_POINT\n\n");
        try clap.help(stdout, clap.Help, &params, .{});
        return 0;
    }
    // clap does not enforce positional arity; retain all values to reject extras.
    if (parsed.positionals[0].len != 1) {
        try stderr.writeAll("diskoff: exactly one mount point is required.\nUsage: diskoff [--help] MOUNT_POINT\n");
        return 2;
    }

    var scope = diskoff.resolveDiskScope(allocator, io, parsed.positionals[0][0]) catch |err| {
        if (err == error.Canceled) return err;
        try stderr.print("diskoff: {s}\n", .{resolveErrorMessage(err)});
        return 1;
    };
    defer scope.deinit(allocator);
    try printScope(stdout, scope);
    return 0;
}

fn resolveErrorMessage(err: (diskoff.ResolveError || std.mem.Allocator.Error)) []const u8 {
    return switch (err) {
        error.InvalidVolumePath => "specify the exact mount point of a mounted volume.",
        error.UnsupportedTarget => "the volume is not on a supported external physical disk.",
        error.AmbiguousPhysicalDisk => "the volume or an associated volume spans multiple physical disks.",
        error.SystemQueryFailed => "unable to query macOS disk information.",
        error.InvalidSystemResponse => "macOS returned invalid or inconsistent disk information.",
        error.OutOfMemory => "not enough memory to resolve the disk.",
        error.Canceled => "disk query canceled.",
    };
}

fn printScope(writer: *Io.Writer, scope: diskoff.DiskScope) Io.Writer.Error!void {
    try writer.print("Disk: {s}\nVolumes:\n", .{scope.disk_bsd_name});
    for (scope.volumes) |volume| {
        try writer.print("  {s}: {s}\n", .{ volume.bsd_name, volume.mount_path orelse "(not mounted)" });
    }
}

test "CLI help succeeds without querying disks" {
    var stdout_buffer: [2048]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: Io.Writer = .fixed(&stdout_buffer);
    var stderr: Io.Writer = .fixed(&stderr_buffer);
    try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, &.{"--help"}, &stdout, &stderr));
    try std.testing.expect(std.mem.startsWith(u8, stdout.buffered(), "Usage: diskoff"));
    try std.testing.expect(std.mem.indexOf(u8, stdout.buffered(), "--help") != null);
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "CLI rejects invalid arguments and reports resolution failures" {
    const cases = [_]struct { args: []const []const u8, status: u8, message: []const u8 }{
        .{ .args = &.{}, .status = 2, .message = "exactly one mount point" },
        .{ .args = &.{ "/Volumes/One", "/Volumes/Two" }, .status = 2, .message = "exactly one mount point" },
        .{ .args = &.{"--unknown"}, .status = 2, .message = "Invalid argument" },
        .{ .args = &.{"--help=value"}, .status = 2, .message = "does not take a value" },
        .{ .args = &.{"relative"}, .status = 1, .message = "exact mount point" },
        .{ .args = &.{""}, .status = 1, .message = "exact mount point" },
    };
    for (cases) |case| {
        var stdout_buffer: [1024]u8 = undefined;
        var stderr_buffer: [1024]u8 = undefined;
        var stdout: Io.Writer = .fixed(&stdout_buffer);
        var stderr: Io.Writer = .fixed(&stderr_buffer);
        try std.testing.expectEqual(case.status, try run(std.testing.allocator, std.testing.io, case.args, &stdout, &stderr));
        try std.testing.expectEqualStrings("", stdout.buffered());
        try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), case.message) != null);
    }
}

test "scope output includes mounted and unmounted volumes and propagates write failure" {
    var volumes = [_]diskoff.Volume{
        .{ .bsd_name = "disk6s1", .mount_path = "/Volumes/A & B" },
        .{ .bsd_name = "disk6s2", .mount_path = null },
    };
    const scope: diskoff.DiskScope = .{ .disk_bsd_name = "disk4", .volumes = &volumes };
    var buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try printScope(&writer, scope);
    try std.testing.expectEqualStrings("Disk: disk4\nVolumes:\n  disk6s1: /Volumes/A & B\n  disk6s2: (not mounted)\n", writer.buffered());
    var full: Io.Writer = .fixed(&.{});
    try std.testing.expectError(error.WriteFailed, printScope(&full, scope));
}
