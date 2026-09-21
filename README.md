# TopicTidy

TopicTidy 是一个面向 macOS 的本地智能 Downloads Organizer。它不会按扩展名粗暴分类，而是综合课程号、文件名、下载来源、文档内容和本地语义向量，为 `~/Downloads` 生成可解释的主题分组。文件只会在你审阅并确认方案后移动，且每个批次都可以验证后撤销。

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

扫描缓存同时校验文件指纹与 extractor version。即使文件大小和 mtime 没变，只要 extractor version 更新，也会重新提取并清除对应 native/pivot 语义缓存。

## 使用

```bash
tt scan
tt propose
tt review 1
tt apply 1
tt history
tt undo 1
tt benchmark
```

`scan` 只读取 Downloads 顶层文件。它忽略目录、符号链接、隐藏文件、`Organized` 和 `.crdownload`、`.download`、`.part`、`.tmp` 等未完成下载。支持 PDF、DOCX、PPTX、TXT 和 Markdown 文本提取；扫描件不做 OCR。提取器通过注册表插拔，扫描器不依赖具体文档库。大型 PDF 只读取前几页、代表性中间页和末尾页，并在文本预算内停止。

`propose --json` 适合脚本和未来 GUI。每个主题同时包含稳定的 `topic_id`、可修改的 `display_name`，以及 course code、文件名、正文、原生语义、跨语言语义和来源 URL 六类结构化证据。证据区分 `strong`、`weak` 和 `none`；跨语言命中会显示类似 `跨语言语义相似度 0.84（zh-Hans → en）` 的独立依据。默认启用零下载的 macOS 原生语义 backend；`propose --no-semantic` 会同时跳过 native 和 pivot 语义计算。

`review` 提供 `list`、`rename`、`move`、`split`、`merge`、`exclude` 和 `folder` 命令。含空格的主题名需要使用引号，例如：

```text
review: rename "Renewable Energy" "Sustainable Power"
review: move 7 "ELEC6008"
review: exclude 12
review: done
```

`apply` 会再次显示实际目标路径并请求确认。也可在自动化测试中使用 `--yes`。目标固定在 `~/Downloads/Organized` 内；同名文件使用稳定的 ` (2)`、` (3)` 后缀，永不覆盖。方案生成后发生变化的源文件会被跳过。

`watch` 使用 macOS FSEvents 前台监控，合并事件并等待文件稳定后更新索引，不会自动移动文件：

```bash
tt watch --interval 300
```

## 数据与配置

SQLite 数据库、约 100 KB 的原生 helper 和进程锁默认保存在 `~/Library/Application Support/DownloadsOrganizer/`。测试或开发时可设置：

```bash
export DOWNLOADS_ORGANIZER_DOWNLOADS=/tmp/demo/Downloads
export DOWNLOADS_ORGANIZER_HOME=/tmp/demo/state
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
```

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

更多实现边界见 [架构说明](docs/ARCHITECTURE.md)。
