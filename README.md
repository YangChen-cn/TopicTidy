# TopicTidy

TopicTidy 是一个面向 macOS 的本地智能 Downloads Organizer。它不会按扩展名粗暴分类，而是综合课程号、文件名、下载来源、文档内容和本地语义向量，为 `~/Downloads` 生成可解释的主题分组。文件只会在你审阅并确认方案后移动，且每个批次都可以验证后撤销。

## 安装

需要 macOS 和 Python 3.12 或更新版本。建议使用独立虚拟环境：

```bash
cd /path/to/文件整理器
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e '.[model]'
```

基础安装不包含约 470 MB 的 embedding 运行依赖；若只想先测试课程号和词元规则，可执行 `pip install -e .`。依赖在 `pyproject.toml` 中精确锁定。

首次启用语义分类时显式下载模型：

```bash
downloads-organizer model download
```

下载命令记录 Hugging Face 返回的 commit。此后 `propose` 设置离线环境并只从本地模型目录加载，不会把文件名、正文或向量发送到网络。若需锁定指定 revision，可使用 `--revision <tag-or-commit>`。

## 使用

```bash
downloads-organizer scan
downloads-organizer propose
downloads-organizer review 1
downloads-organizer apply 1
downloads-organizer history
downloads-organizer undo 1
```

`scan` 只读取 Downloads 顶层文件。它忽略目录、符号链接、隐藏文件、`Organized` 和 `.crdownload`、`.download`、`.part`、`.tmp` 等未完成下载。支持 PDF、DOCX、PPTX、TXT 和 Markdown 文本提取；扫描件不做 OCR。

`propose --json` 适合脚本和未来 GUI。未安装模型时仍能运行，并明确提示语义评分未启用。`propose --no-model` 可主动跳过模型。

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
downloads-organizer watch --interval 300
```

## 数据与配置

SQLite 数据库、模型和进程锁默认保存在 `~/Library/Application Support/DownloadsOrganizer/`。测试或开发时可设置：

```bash
export DOWNLOADS_ORGANIZER_DOWNLOADS=/tmp/demo/Downloads
export DOWNLOADS_ORGANIZER_HOME=/tmp/demo/state
```

不要把 `DOWNLOADS_ORGANIZER_DOWNLOADS` 指向需要递归整理的目录；首版只处理该目录的顶层普通文件。人工确认的文件指纹与主题关联会用于未来建议。撤销成功后，对应学习关联会停用。

## 开发与验证

```bash
python -m pip install -e '.[dev]'
pytest
```

测试全部使用 pytest 临时目录，不会访问真实 Downloads。`examples/demo-downloads` 提供可复制的演示资料：

```bash
mkdir -p /tmp/organizer-demo/Downloads
cp examples/demo-downloads/* /tmp/organizer-demo/Downloads/
DOWNLOADS_ORGANIZER_DOWNLOADS=/tmp/organizer-demo/Downloads \
DOWNLOADS_ORGANIZER_HOME=/tmp/organizer-demo/state \
downloads-organizer scan
DOWNLOADS_ORGANIZER_DOWNLOADS=/tmp/organizer-demo/Downloads \
DOWNLOADS_ORGANIZER_HOME=/tmp/organizer-demo/state \
downloads-organizer propose --no-model
```

更多实现边界见 [架构说明](docs/ARCHITECTURE.md)。
