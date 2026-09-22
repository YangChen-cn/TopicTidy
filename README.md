<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="TopicTidy app icon">
</p>

<h1 align="center">TopicTidy</h1>

<p align="center">
  本地、可解释、可撤销的 macOS Downloads 智能整理器
</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-111111?logo=apple">
  <img alt="Swift 6.2+" src="https://img.shields.io/badge/Swift-6.2%2B-F05138?logo=swift&logoColor=white">
  <img alt="Local first" src="https://img.shields.io/badge/processing-local%20only-20A37F">
  <img alt="No Python" src="https://img.shields.io/badge/runtime-none%20required-555555">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-blue">
  <a href="https://github.com/YangChen-cn/TopicTidy/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/YangChen-cn/TopicTidy"></a>
</p>

TopicTidy 不按扩展名粗暴分类。它综合课程号、文件名、下载来源、文档正文和 Apple 本地语义能力，识别属于同一课程、项目或主题的文件。每个建议都会解释依据；文件在确认前保持原位，整理后也能安全撤销。

## 特点

- 课程号、文件名、来源 URL、正文关键词与本地语义混合判断
- PDF、DOCX、PPTX、TXT 和 Markdown 文本提取
- Apple NaturalLanguage embedding；已安装语言支持可选的本地 Translation pivot
- 主题级确认、取消、恢复和撤销，不必整批接受
- SQLite 保存方案、人工修正、目录关联和逐文件操作日志
- 默认离线、默认保守、绝不覆盖同名文件
- 纯原生 Swift：同一套 `TopicTidyCore` 同时提供菜单栏 GUI 与 `tt` CLI，运行时不需要 Python、pip 或 Xcode

## 安装

### GUI

适用于 Apple Silicon 和 macOS 15 或更高版本。无需安装 Python、pip 或 Xcode。

1. 从 [GitHub Releases](https://github.com/YangChen-cn/TopicTidy/releases/latest) 下载 `TopicTidy-0.9.0-arm64.dmg`。
2. 打开 DMG，把 TopicTidy 拖入 Applications。
3. 启动后点击菜单栏托盘图标。

当前分发包使用 `TopicTidy` 自签名证书，尚未经过 Apple Developer ID 公证。首次打开时，Gatekeeper 可能要求在“系统设置 → 隐私与安全性”中确认来源。

### CLI

`tt` 是原生 Swift 二进制，从源码构建：

```bash
swift build -c release
.build/release/tt --help
```

也可以直接用应用包内的 `tt`（每日任务使用的就是它）：

```bash
/Applications/TopicTidy.app/Contents/Resources/tt --help
```

## CLI 快速开始

```bash
tt scan
tt propose
tt review 1
tt apply 1
tt history
tt undo 1
```

常用配置：

```bash
tt config destination ~/Documents/TopicTidy
tt config auto-confirm --enable --threshold 0.92
tt schedule enable --at 09:00
tt semantic status
```

`scan` 只读取 Downloads 顶层普通文件，忽略目录、符号链接、隐藏文件、Organized 和未完成下载。`propose --json` 输出稳定的 `topic_id`、可编辑的 `display_name`，以及 course code、文件名、正文、native semantic、cross-language semantic 和来源 URL 的结构化证据。

`apply` 会重新计算实际目标并要求确认。方案生成后已变化的文件会跳过；同名冲突使用稳定编号后缀，绝不覆盖。高置信度自动确认默认关闭，只处理完整、无排除成员、无冲突且达到阈值的主题。

## GUI

菜单栏面板可完成扫描、主题审阅、文件调整、单主题确认、历史撤销和设置。完整窗口提供更宽的主题侧栏与证据视图。SwiftUI 只负责界面，扫描、分类、SQLite、移动和恢复都由 `TopicTidyCore` 在同一进程内完成。

运行阶段不联网，也不依赖开发机路径。

<!-- SIZE_TABLE_START -->
| 分发物 | 迁移前（Python Core） | 迁移后（原生 Swift） | 减少 |
| --- | ---: | ---: | ---: |
| `.app` | 86.1 MiB | 5.97 MiB | 93.1% |
| `.dmg` | 43.1 MiB | 3.19 MiB | 92.6% |
<!-- SIZE_TABLE_END -->

上表由 `scripts/build_app.sh` 对同一份应用实测生成；原始字节数保存在 `dist/TopicTidy-0.9.0-size-report.json`。完整的速度与等价性对比见 [docs/MIGRATION.md](docs/MIGRATION.md)。

## 工作原理

```text
Downloads 顶层文件
   ↓ 扫描（只读）
课程号 / 文件名 / 来源 URL / 正文 / 本地语义
   ↓ 保守聚类 + 结构化证据
方案（SQLite，未移动任何文件）
   ↓ 用户按主题确认
移动记录 + 关联学习
   ↓ 随时
撤销（校验指纹后恢复原位）
```

## 开发

```bash
swift build            # 构建 Core、tt、TopicTidy
swift test             # 66 项测试：扫描、提取、聚类、操作、自动化、GUI 契约
.build/debug/tt benchmark            # 核心聚类基准（F1 门禁）
.build/debug/tt benchmark Resources/fixtures/holdout_unseen.json
scripts/build_app.sh   # 生成签名 .app 与 DMG
```

测试与基准必须使用临时 Downloads 目录，绝不指向真实的 `~/Downloads`。

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 模块职责与核心不变量
- [docs/MIGRATION.md](docs/MIGRATION.md) — Python → Swift 迁移的等价性证据与实测对比
- [docs/HOLDOUT_EVALUATION.md](docs/HOLDOUT_EVALUATION.md) — 留出语料评估
- [docs/REAL_WORLD_EVALUATION.md](docs/REAL_WORLD_EVALUATION.md) — 真实语料评估
