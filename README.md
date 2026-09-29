# diskoff

diskoff 正在开发 macOS 外接硬盘的只读识别、占用诊断和弹出能力。当前库已提供从挂载卷路径解析单块外接物理硬盘及关联卷的入口；CLI 尚未接入该入口。

```zig
var disk = try diskoff.resolveDiskScope(allocator, io, "/Volumes/My Drive");
defer disk.deinit(allocator);

// disk.disk_bsd_name 是物理硬盘的 BSD 名称，例如 "disk4"。
// disk.volumes 含关联卷的 BSD 名称；mount_path 为 null 表示未挂载。
```

调用方只应对 `mount_path != null` 的卷做路径占用查询。入口只接受已挂载卷的准确挂载点，支持路径中的空格和特殊字符。当前只支持能唯一归属一块外接物理硬盘的拓扑；内置盘、磁盘映像、无法识别的存储关系及多物理盘 APFS 组合会返回错误。`DiskScope` 拥有返回的字符串和卷列表，调用方须使用同一 allocator 调用 `deinit`。

实现全部为 Zig，通过 `extern` 调用 Disk Arbitration 和 CoreFoundation，并启动 `diskutil list -plist` 获取只读拓扑。查询不设固定超时；Zig I/O 取消会清理正在运行的 `diskutil` 子进程。同步的 Disk Arbitration 调用本身没有可用的即时取消点，取消会在调用返回后被观察到。

本机验证使用 Zig 0.17.0-dev.2326+f94185e67、macOS SDK 27.0，已测试 Disk Arbitration 路径解析和模拟 plist 的普通分区、APFS 映射及未挂载卷。验证时 `diskutil list -plist physical external` 为空，没有外接硬盘，因此尚未完成 Issue #1 要求的外接设备实机核对。

项目阶段和后续交付见 [ROADMAP.md](ROADMAP.md)。
