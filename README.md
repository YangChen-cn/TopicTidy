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

这是完整的运行安装，不会安装 PyTorch、Transformers 或 sentence-transformers，也不会下载模型。语义特征使用 macOS 自带的 NaturalLanguage sentence embedding。首次执行 `propose` 时只会在本机编译一个约 100 KB 的 Swift helper，因此需要 Xcode Command Line Tools。

可以提前检查和准备原生 backend：

```bash
tidy semantic status
tidy semantic prepare
```

这两个命令都不会访问网络。系统按文档主要语言选择 Apple embedding；不同语言向量空间不会互相计算余弦相似度。如果某种语言的系统资产尚未存在，TopicTidy 不会代为下载，而是跳过该文件的语义向量。跨语言文件和缺少系统资产的文件仍使用课程号、文件名、正文词元和来源 URL 等证据。

## 使用

```bash
tidy scan
tidy propose
tidy review 1
tidy apply 1
tidy history
tidy undo 1
tidy benchmark
```

`scan` 只读取 Downloads 顶层文件。它忽略目录、符号链接、隐藏文件、`Organized` 和 `.crdownload`、`.download`、`.part`、`.tmp` 等未完成下载。支持 PDF、DOCX、PPTX、TXT 和 Markdown 文本提取；扫描件不做 OCR。提取器通过注册表插拔，扫描器不依赖具体文档库。大型 PDF 只读取前几页、代表性中间页和末尾页，并在文本预算内停止。

`propose --json` 适合脚本和未来 GUI。每个主题同时包含稳定的 `topic_id`、可修改的 `display_name`，以及 course code、文件名、正文、语义和来源 URL 五类结构化证据。证据区分 `strong`、`weak` 和 `none`。默认启用零下载的 macOS 原生语义 backend；`propose --no-semantic` 可主动跳过语义计算。

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
tidy watch --interval 300
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
tidy benchmark
```

benchmark 使用内置标注 fixture，输出 expected clusters、predicted clusters、未分类集合以及 pairwise precision / recall / F1。修改权重或命名算法后应保持默认 benchmark 通过；也可传入自定义 JSON：

```bash
tidy benchmark path/to/fixture.json --min-f1 0.95
tidy benchmark --json
```

测试全部使用 pytest 临时目录，不会访问真实 Downloads。`examples/demo-downloads` 提供可复制的演示资料：

```bash
mkdir -p /tmp/organizer-demo/Downloads
cp examples/demo-downloads/* /tmp/organizer-demo/Downloads/
DOWNLOADS_ORGANIZER_DOWNLOADS=/tmp/organizer-demo/Downloads \
DOWNLOADS_ORGANIZER_HOME=/tmp/organizer-demo/state \
tidy scan
DOWNLOADS_ORGANIZER_DOWNLOADS=/tmp/organizer-demo/Downloads \
DOWNLOADS_ORGANIZER_HOME=/tmp/organizer-demo/state \
tidy propose --no-semantic
```

更多实现边界见 [架构说明](docs/ARCHITECTURE.md)。
