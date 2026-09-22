<p align="center">
  <img src="macos/Assets/AppIcon.png" width="128" height="128" alt="TopicTidy app icon">
</p>

<h1 align="center">TopicTidy</h1>

<p align="center">
  本地、可解释、可撤销的 macOS Downloads 智能整理器
</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-111111?logo=apple">
  <img alt="Python 3.12+" src="https://img.shields.io/badge/Python-3.12%2B-3776AB?logo=python&logoColor=white">
  <img alt="Local first" src="https://img.shields.io/badge/processing-local%20only-20A37F">
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
- 同一套 Python Core，同时提供原生菜单栏 GUI 与 CLI

## 安装

### GUI

适用于 Apple Silicon 和 macOS 15 或更高版本。无需安装 Python、pip 或 Xcode。

1. 从 [GitHub Releases](https://github.com/YangChen-cn/TopicTidy/releases/latest) 下载 `TopicTidy-0.9.0-arm64.dmg`。
2. 打开 DMG，把 TopicTidy 拖入 Applications。
3. 启动后点击菜单栏托盘图标。

当前分发包使用 `TopicTidy` 自签名证书，尚未经过 Apple Developer ID 公证。首次打开时，Gatekeeper 可能要求在“系统设置 → 隐私与安全性”中确认来源。

### CLI

CLI 依赖放在标准 `cli` extra 中，避免进入 GUI 自包含环境。发布到 PyPI 后可用以下任一方式安装：

```bash
uv tool install 'topictidy[cli]'
```

或：

```bash
pipx install 'topictidy[cli]'
```

安装后同时提供短命令和兼容入口：

```bash
tt --help
downloads-organizer --help
```

> Python packaging 的 optional extra 不会被 console entry point 自动选择，因此省略 `[cli]` 只会安装可供 GUI/库调用的 Core。直接使用 `uv tool install topictidy` 无法可靠安装 Typer、Rich 和 watchdog；这里明确写出 extra，避免得到残缺 CLI。

截至 2026-09-23，PyPI 的 `topictidy` 项目页返回 404，名称暂未被公开项目占用；最终归属仍以首次发布成功为准。若届时不可用，首选替代分发名为 `topictidy-macos`，命令仍保持 `tt` 与 `downloads-organizer`。

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

菜单栏面板可完成扫描、主题审阅、文件调整、单主题确认、历史撤销和设置。完整窗口提供更宽的主题侧栏与证据视图。SwiftUI 只负责界面；扫描、分类、SQLite、移动和恢复仍由 Python Core 处理。

GUI 包含独立 Python 3.12 runtime 和预编译 Apple helper。运行阶段不联网，也不依赖开发机路径。GUI 构建只安装 Core 依赖，并安全移除 pip、headers、测试、缓存、无运行价值的安装元数据和 CLI-only 包。

<!-- SIZE_TABLE_START -->
| 分发物 | 精简前 | 精简后 | 减少 |
| --- | ---: | ---: | ---: |
| `.app` | 115.8 MiB | 86.1 MiB | 29.7 MiB（25.6%） |
| `.dmg` | 69.5 MiB | 43.1 MiB | 26.5 MiB（38.1%） |
<!-- SIZE_TABLE_END -->

上表由 0.9.0 构建脚本对同一份应用在精简前后实测生成；原始字节数保存在 `TopicTidy-0.9.0-size-report.json` 中。

## 工作原理

```text
Downloads 顶层文件
        ↓
元数据 + 可插拔文档提取器
        ↓
课程号 / 文件名 / URL / 正文 / 本地语义证据
        ↓
保守聚类与可解释建议
        ↓
人工审阅或显式授权的高置信度自动确认
        ↓
持久化移动意图 → 同卷移动 → 可验证撤销
```

大型 PDF 只抽取前几页、代表性中间页和末尾页，并在文本预算耗尽时停止。不同语言的 native embedding 不会直接比较；跨语言候选只翻译约 1000–3000 字符的代表性文本，并且只使用已安装的 Apple Translation 语言资产。

数据默认保存在：

```text
~/Library/Application Support/DownloadsOrganizer/
```

## Development

需要 Python 3.12+、Swift 6.2+ 和 macOS 15+。开发依赖包含 CLI extra、pytest、build 与 twine：

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[dev]'
pytest
tt benchmark
```

构建并验证 Python wheel 与 sdist：

```bash
python -m build
python -m twine check dist/*
python scripts/verify_distribution.py dist/*.whl
```

`verify_distribution.py` 会检查 `tt` 和 `downloads-organizer` entry point，在全新临时环境中安装 wheel 的 `[cli]` extra，并实际运行两个命令的 `--help`。

构建原生 GUI 与签名 DMG：

```bash
python macos/scripts/build_app.py --identity TopicTidy
python macos/scripts/smoke_bundle.py dist/TopicTidy.app
```

完整提交门禁：

```bash
pytest
tt benchmark
tt benchmark src/downloads_organizer/fixtures/holdout_unseen.json --min-f1 0.94
python -m build
python scripts/verify_distribution.py dist/*.whl
swift build --package-path macos
git diff --check
```

架构边界见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，真实语料评估见 [docs/REAL_WORLD_EVALUATION.md](docs/REAL_WORLD_EVALUATION.md)。所有自动化测试使用临时 Downloads，不会操作真实下载目录。

## License

[MIT](LICENSE)
