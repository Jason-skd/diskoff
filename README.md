# diskoff

macOS 外接物理硬盘的只读识别库与 CLI。占用诊断和整盘弹出属于后续交付。

## 常用指令

需要 macOS，以及 [build.zig.zon](build.zig.zon) 声明的 Zig 工具链。

```sh
zig build
zig build run -- --help
zig build run -- "/Volumes/My Drive"
zig build test
zig fmt --check build.zig build.zig.zon src
```

`zig build` 安装 CLI 到 `zig-out/bin/diskoff`。构建和测试支持 `-Doptimize=safe`；首次构建通过 Zig 包管理器获取锁定的 zig-clap 依赖。系统集成测试需要访问 macOS Disk Arbitration 服务。

库的最小调用：

```zig
var disk = try diskoff.resolveDiskScope(allocator, io, "/Volumes/My Drive");
defer disk.deinit(allocator);
```

## 项目架构

- [src/main.zig](src/main.zig)：zig-clap 参数解析、只读查询编排、输出和退出状态。
- [src/root.zig](src/root.zig)：库公共入口及调用契约。
- [src/disk_scope.zig](src/disk_scope.zig)：磁盘与卷模型、拓扑范围解析规则。
- [src/macos_disk.zig](src/macos_disk.zig)：Disk Arbitration 查询、diskutil 子进程和 plist 转换；系统句柄限定在此文件内。
- [build.zig](build.zig)：库模块、CLI、构建与测试入口。

## 文档索引

- [路线图与支持范围](ROADMAP.md)
- [变更记录](CHANGELOG.md)
- [仓库 AI 治理](AGENTS.md)

## 权威来源

- 库 API 与资源所有权：[src/root.zig](src/root.zig)、[src/disk_scope.zig](src/disk_scope.zig) 的声明、注释与行为测试。
- CLI 参数：[src/main.zig](src/main.zig) 的 zig-clap 参数声明。
- 工具链要求与锁定依赖：[build.zig.zon](build.zig.zon)。
- 平台接口：macOS SDK 的 DiskArbitration、CoreFoundation 头文件，以及系统 `diskutil` 的 plist 输出；转换与验证见 [src/macos_disk.zig](src/macos_disk.zig)。
