# 开发与验证

## 构建

Mac + 提供 Swift 5.9+ 与 macOS SDK 的开发工具：

```sh
swift test --cache-path "$PWD/.build/cache" --scratch-path "$PWD/.build"
./scripts/build.sh
```

应用位于 `dist/MacStatus.app`。脚本生成本机架构构建并临时签名，不下载第三方运行依赖，不做 Developer ID 签名、公证或发布。请勿在现有应用仍运行时覆盖其可执行文件。

## 源码入口

| 文件 | 职责 |
| --- | --- |
| `MacStatusApp.swift` | AppKit 生命周期、菜单栏、浮层、设置 / 引导窗口和实例复用 |
| `MonitorStore.swift` | 单队列采样、定时器、偏好操作、有界历史、查询取消和缓存 |
| `SystemCollector.swift` / `DetailCollector.swift` | 系统指标与按需详情采集 |
| `NetworkInfo.swift` | 本地连接信息、出口地址与国别结果校验 |
| `AppPreferences.swift` | 卡片偏好迁移、完整 / 仅网络采样策略和本地反馈报告 |
| `DashboardView.swift` / `SettingsView.swift` | 原生概览、详情、设置和引导 |
| `StatusContentView.swift` / `StatusGlyph.swift` | 固定菜单栏几何与图标绘制 |

以上文件位于 `Sources/MacStatus/`。

## 预览参数

先退出已有实例，再按需要启动一个开发窗口；新版本会复用已运行的实例。

```sh
open -n dist/MacStatus.app --args --preview
open -n dist/MacStatus.app --args --preview-dark
open -n dist/MacStatus.app --args --show
open -n dist/MacStatus.app --args --settings
open -n dist/MacStatus.app --args --settings --dark
open -n dist/MacStatus.app --args --welcome
open -n dist/MacStatus.app --args --background
```

预览与正式浮层使用同一个 DashboardView。`--dark` 只覆盖本应用外观，不修改系统偏好；浮层还会继承状态栏外观。`--background` 跳过首次引导，用于测量后台状态。

`--diagnose` 输出真实本机快照，含本机地址；仅用于本地核对。`--metric=cpu|memory|disk` 可请求对应详情。请勿将未经检查的完整输出贴到公开 Issue。

## 手动回归

- 菜单栏速度在 B / K / M 单位变化时固定宽度；图标点击、点击外部、快捷键与再次打开。
- 卡片排序 / 隐藏 / 全部隐藏后可恢复，设置重启后保留。
- 启动曲线只从右侧积累，缺失或睡眠间隔不生成假线。
- 公网查询关闭时不发请求；IPv4 / IPv6 的失败状态不掩盖本地连接。
- 设置 / 引导关闭后后台降频；CPU / 内存 / 磁盘 / Wi-Fi 详情仅在对应模块需要时读取。
- 重复启动只保留一个实例；真实登录项、网络切换、多显示器和睡眠按实际设备验收。

GitHub Actions 检查测试与 Release 打包，不执行以上完整界面路径，也不会启用登录项。

本地 `verification/`、构建目录和原始日志不入仓。公开记录见 [PERFORMANCE.md](PERFORMANCE.md)。
