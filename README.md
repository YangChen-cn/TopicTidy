# TopicTidy

TopicTidy 是一个面向 macOS 的本地智能 Downloads Organizer。它不会按扩展名粗暴分类，而是综合课程号、文件名、下载来源、文档内容和本地语义向量，为 `~/Downloads` 生成可解释的主题分组。默认仍由你审阅并确认方案；也可以显式启用高置信度自动确认。每次移动都有保存的方案和操作日志，并可验证后撤销。

## 安装

需要 macOS 和 Python 3.12 或更新版本。建议使用独立虚拟环境：

```bash
cd /path/to/文件整理器
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e .
```

这是完整的运行安装，不会安装 PyTorch、Transformers 或 sentence-transformers，也不会下载模型。语义特征使用 macOS 自带的 NaturalLanguage sentence embedding；跨语言候选使用 Apple Translation 的已安装语言资产。首次使用时只会在本机编译两个轻量 Swift helper，因此需要 Xcode Command Line Tools。

命令行简称为 `tt`（TopicTidy）；同时保留 `downloads-organizer` 兼容入口。macOS 自带的 `tidy` 是另一个 HTML 工具，请勿将它用于本项目。

可以提前检查和准备原生 backend：

```bash
tt semantic status
tt semantic prepare
```

这两个命令都不会访问网络。`semantic status` 分别报告 Apple embedding 和 `zh-Hans`、`ja`、`ko` 到 English 的 Translation 状态，并区分 `installed`、`not installed` 与 `unavailable`。`semantic prepare` 只编译 helper，不准备或下载语言资产。

每个文件保留原语言的 native embedding。不同原生语言空间不会直接比较；`propose` 只为跨语言候选构造约 2400 字符的代表性短文本。候选优先来自文件名、正文或来源路径；完全没有词面线索时，每个文件至少探索 1 个最近的跨语言文件，14 天窗口内最多探索 2 个近邻。每轮最多生成 24 个新 pivot，已有缓存不占额度，因此后续 propose 可以继续覆盖尚未探索的候选，而不会退化成一次性全量翻译。英文短文本直接进入 English NLEmbedding，其他语言仅在对应 Translation 语言对已经安装时翻译到 English，再生成 pivot embedding。14 天内零词面线索的 pair 需要至少 0.88 的跨语言语义相似度才可独立成组，窗口外要求至少 0.92。macOS 26+ 支持命令行 helper 的 installed-only 翻译；旧系统会安全降级。任何未安装或不支持的语言对都不会触发下载，也不会让建议生成失败。

扫描缓存同时校验文件指纹、extractor version 和共享文本特征版本。即使文件大小和 mtime 没变，只要提取器或关键词逻辑更新，也会重新提取并清除对应 native/pivot 语义缓存。

## 使用

```bash
tt scan
tt propose
tt review 1
tt apply 1
tt history
tt undo 1
tt benchmark
tt config show
```

`scan` 只读取 Downloads 顶层文件。它忽略目录、符号链接、隐藏文件、`Organized` 和 `.crdownload`、`.download`、`.part`、`.tmp` 等未完成下载。支持 PDF、DOCX、PPTX、TXT 和 Markdown 文本提取；扫描件不做 OCR。提取器通过注册表插拔，扫描器不依赖具体文档库。大型 PDF 只读取前几页、代表性中间页和末尾页，并在文本预算内停止。

`propose --json` 适合脚本和未来 GUI。每个主题同时包含稳定的 `topic_id`、可修改的 `display_name`，以及 course code、文件名、正文、原生语义、跨语言语义和来源 URL 六类结构化证据。证据区分 `strong`、`weak` 和 `none`；跨语言命中会显示类似 `跨语言语义相似度 0.84（zh-Hans → en）` 的独立依据。默认启用零下载的 macOS 原生语义 backend；`propose --no-semantic` 会同时跳过 native 和 pivot 语义计算。

系列文件名中的稳定标识（例如 `CS229`）、标题中的产品/项目标识（例如 `FreeRTOS`）以及 Markdown README/索引对当前文件的明确链接都可作为保守的系列证据。普通领域词组和同一下载域名仍不能单独触发合并。

`review` 提供 `list`、`rename`、`move`、`split`、`merge`、`exclude` 和 `folder` 命令。含空格的主题名需要使用引号，例如：

```text
review: rename "Renewable Energy" "Sustainable Power"
review: move 7 "ELEC6008"
review: exclude 12
review: done
```

`apply` 会再次显示实际目标路径并请求确认。也可在自动化测试中使用 `--yes`。同名文件使用稳定的 ` (2)`、` (3)` 后缀，永不覆盖。方案生成后发生变化的源文件会被跳过。

整理根目录默认为 `~/Downloads/Organized`，可改为同一磁盘上的其他位置：

```bash
tt config destination ~/Documents/TopicTidy
tt config show
```

目标根目录会写入方案快照，因此修改设置不会改变已经保存的旧方案。目录不能直接等于 Downloads，也不能是符号链接；当前版本仍使用同卷 rename，跨磁盘目标会在执行时安全跳过。

高置信度自动确认默认关闭。启用后，每日任务只自动执行达到阈值、无冲突、且没有任何成员被排除的完整分组；低分组、部分排除的分组、未分类文件和过期文件保持原位。README/index 的直接链接可以生成建议，但只有课程代码、系列标识、强语义或强来源 URL 中至少另一类独立强证据同时成立时，才允许自动移动。置信度是启发式评分，建议先使用默认 `0.92`：

```bash
tt config auto-confirm --enable --threshold 0.92
tt config auto-confirm --disable
tt auto run                 # 立即运行一次，便于验证设置
tt auto run --json          # 供 GUI 或其他本地调用方读取
```

启用自动确认是一项持久授权。每次自动移动仍会先保存方案，并以 `auto_apply` 批次记录到 `history`，可以照常用 `tt undo <batch-id>` 撤销。

`watch` 使用 macOS FSEvents 前台监控，合并事件并等待文件稳定后更新索引，不会自动移动文件：

```bash
tt watch --interval 300
```

每日自动扫描使用当前 macOS 用户的 LaunchAgent，无需保持终端打开：

```bash
tt schedule enable --at 09:00
tt schedule status
tt schedule disable
```

`schedule status` 同时检查 plist 配置和 `launchctl print`，区分 `not_configured`、`configured_not_loaded` 与 `loaded`。每日任务始终执行扫描。只有另外启用了 `auto-confirm` 时，它才会生成方案并自动移动高置信度分组。LaunchAgent 调用当前虚拟环境的 Python；删除或移动该虚拟环境后需要重新执行 `schedule enable`。日志位于应用数据目录的 `logs/`。

## 数据与配置

SQLite 数据库、约 100 KB 的原生 helper 和进程锁默认保存在 `~/Library/Application Support/DownloadsOrganizer/`。测试或开发时可设置：

```bash
export DOWNLOADS_ORGANIZER_DOWNLOADS=/tmp/demo/Downloads
export DOWNLOADS_ORGANIZER_HOME=/tmp/demo/state
export DOWNLOADS_ORGANIZER_DESTINATION=/tmp/demo/Organized
```

不要把 `DOWNLOADS_ORGANIZER_DOWNLOADS` 指向需要递归整理的目录；首版只处理该目录的顶层普通文件。人工确认的文件指纹与主题关联会用于未来建议。撤销成功后，对应学习关联会停用。

项目当前处于无用户测试阶段，不维护旧数据库迁移。若升级后提示 schema 版本不兼容，删除 `~/Library/Application Support/DownloadsOrganizer/organizer.sqlite3` 后重新执行 `scan`。

## 开发与验证

```bash
python -m pip install -e '.[dev]'
pytest
tt benchmark
```

benchmark 使用内置标注 fixture，输出 expected clusters、predicted clusters、未分类集合以及 pairwise precision / recall / F1。修改权重或命名算法后应保持默认 benchmark 通过；也可传入自定义 JSON：

```bash
tt benchmark path/to/fixture.json --min-f1 0.95
tt benchmark --json
tt benchmark src/downloads_organizer/fixtures/holdout_unseen.json --min-f1 0.94
```

独立 holdout 包含 42 个半真实文件，覆盖通用 `report/project/notes` 文件名、同领域不同项目、同域名无关下载、README 集合、中英文相似主题、相近但冲突的课程号，以及 20 个应保持未分类的文件。它与核心 benchmark 分开维护，不用于继续调整现有 50 文件语料的权重。

测试全部使用 pytest 临时目录，不会访问真实 Downloads。`examples/demo-downloads` 提供可复制的演示资料：

```bash
mkdir -p /tmp/organizer-demo/Downloads
cp examples/demo-downloads/* /tmp/organizer-demo/Downloads/
DOWNLOADS_ORGANIZER_DOWNLOADS=/tmp/organizer-demo/Downloads \
DOWNLOADS_ORGANIZER_HOME=/tmp/organizer-demo/state \
tt scan
DOWNLOADS_ORGANIZER_DOWNLOADS=/tmp/organizer-demo/Downloads \
DOWNLOADS_ORGANIZER_HOME=/tmp/organizer-demo/state \
tt propose --no-semantic
```

更多实现边界见 [架构说明](docs/ARCHITECTURE.md)，50 文件真实语料测试见 [真实文件评估](docs/REAL_WORLD_EVALUATION.md)。

## macOS 菜单栏应用（SwiftUI）

分发包支持 **Apple Silicon、macOS 15+**。打开 `TopicTidy-0.8.0-arm64.dmg`，把 `TopicTidy.app` 拖到 Applications 后打开，点击菜单栏托盘图标即可使用。无需安装 Python、pip、Xcode 或下载模型。

菜单栏使用约 380 pt 宽的紧凑面板，空状态随内容收起，主题默认折叠，按需展开文件和匹配依据。每个主题可以独立确认、取消或恢复；确认一个主题只移动该主题，其他建议继续留在方案中。面板直接提供扫描、主题与证据审阅、重命名/移动成员/拆分/合并/排除、移动清单确认、历史撤销、目标目录及每日任务设置。需要更多空间时可打开完整窗口。应用启动只读取状态，不自动扫描或移动；第一次扫描时系统可能请求 Downloads 访问权限。

分发包使用用户提供的 **TopicTidy 自签名证书**，包含独立 Python 3.12 与预编译 Apple helper，通过包内相对路径运行。它不依赖开发机目录，也不需要项目 `.venv`。自签名不等于 Apple Developer ID 公证，接收方的 Gatekeeper 可能阻止首次打开；确认来源后可在系统“隐私与安全性”中允许打开。不要关闭系统安全检查。Intel Mac 暂不支持。

请先放入最终安装位置，再启用每日任务。移动或重命名应用后，重新保存每日任务以更新 launchd 中的程序路径。关闭菜单栏应用不影响已启用的每日任务；卸载前在设置中关闭每日任务。

开发构建（需要 Swift 6.2+、Python 3.12+ 和钥匙串中的签名身份）：

```bash
python3 macos/scripts/build_app.py --identity TopicTidy
open dist/TopicTidy.app
```

构建阶段下载校验过 SHA-256 的独立 Python，并按 `macos/runtime-constraints.txt` 安装依赖；运行阶段不访问网络。`--runtime <archive>` 可复用已下载的固定运行时。脚本逐一签名嵌套代码、验证完整 bundle、检查源码/临时目录泄漏，生成 app 与签名 DMG。图标由内置 imagegen 生成，见 [素材记录](macos/Assets/README.md)。

原生界面通过本地 JSON 子进程调用 `gui_bridge`，复用服务层与 SQLite。所有请求在同一进程锁内恢复和执行；移动必须提交与当前预览一致的清单。测试使用临时 Downloads，不操作个人下载文件。
