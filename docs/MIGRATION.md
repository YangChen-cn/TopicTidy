# Python → Swift 迁移记录

本次迁移把 TopicTidy 从"SwiftUI + Python Core"改为纯原生 Swift，同时保持聚类算法与产品行为不变。本文记录验证方式、实测差异与残留事项。

## 迁移顺序

逐层迁移，每层都与 Python 参考实现做差分比对，确认一致后再进入下一层：

1. 纯函数层（`config` / `models` / `text_features` / `topic_naming` / `semantic_text`）
2. `db` + `scanner` + `extractors`
3. `embedding` / `translation`（由 helper 子进程改为进程内调用）
4. `clustering`
5. `operations` / `workflow` / `preferences` / `automation` / `scheduler`
6. CLI 与 GUI 共用同一 `TopicTidyCore`

## 等价性证据

**差分脚本** `scripts/parity.sh` 把同一份素材分别喂给两个实现，比较 `scan` 输出、`propose --json` 和完整数据库内容（`files`、`features`（含 embedding 向量）、`semantic_pivots`、`plan_members`、`evidence`、`plans`、`operations`、`associations`、`topics`），并在其后执行 `apply` → `undo` → `review rename` 再各比较一次。迁移完成时 4 个场景（courses、markdown-collection、mixed-formats、office-documents）× 6 个产物全部一致。

**冻结的 golden 输出**：`Tests/TopicTidyCoreTests/Fixtures/*-golden.json` 保存了 Python 参考实现给出的 predicted clusters 与未分类集合；`benchmark core` 与 `holdout_unseen` 两个 fixture 的分组、命名、证据与 F1 均逐项相等。Python 删除后这些 golden 成为长期回归基线。

**embedding 逐元素相等**：同一份语义文本经 helper 子进程与经进程内 `NLEmbedding` 得到的 512 维向量按位相同，因此 `semantic_similarity` 分数完全一致。

**提取器字符级相等**：真实 DOCX/PPTX/PDF 的 `title`、`keywords`、`summary`、`text` 与 Python 参考输出逐字符相同（`Tests/TopicTidyCoreTests/Extractors`）。

**测试**：迁移前 Python 侧 `pytest` 72 项全部通过；迁移后 Swift 侧 66 项测试覆盖同一批断言（scanner、extractors、clustering、operations、automation、preferences、AppService 契约、benchmark 门禁）。

## 实测对比

素材：60 个 Markdown 文件、6 个主题（同一台 Apple Silicon 机器，release 构建）。

| 操作 | Python Core | 原生 Swift | 变化 |
| --- | ---: | ---: | ---: |
| `scan`（冷启动，60 文件全量提取） | 1406 ms | 79 ms | 17.8x 更快 |
| `scan`（缓存命中） | 97 ms | 28 ms | 3.5x 更快 |
| `propose`（含语义，冷向量缓存） | 12748 ms | 3632 ms | 3.5x 更快 |
| `propose --no-semantic` | 469 ms | 719 ms | 1.5x 更慢 |
| `benchmark`（29 文件聚类） | 136 ms | 105 ms | 1.3x 更快 |
| GUI 单次请求（status） | 143 ms | 21 ms | 6.8x 更快 |

GUI 请求由"每次启动 Python 子进程 + JSON 往返"改为进程内调用；`--help` 冷启动 18 ms。`propose --no-semantic` 略慢是唯一退步项：聚类本身仍比 Python 慢约 1.5 倍（Swift 的集合与字符串运算缺少 CPython 的 C 级捷径），绝对差约 250 ms，且该路径已被缓存优化从 18.8 s 降到 719 ms。

分发物体积：

| 分发物 | 迁移前 | 迁移后 | 减少 |
| --- | ---: | ---: | ---: |
| `TopicTidy.app` | 86.1 MiB | 5.97 MiB | 93.1% |
| `TopicTidy-0.9.0-arm64.dmg` | 43.1 MiB | 3.19 MiB | 92.6% |

应用内原有 84.9 MiB 的 Python runtime 与两个 helper；现在只剩 `Contents/MacOS/TopicTidy`、`Contents/Resources/tt` 和应用图标。

## 有意保留的差异

- **backend 版本号**：`apple-nlembedding:<版本>:<helper 摘要>` → `...:native`。旧缓存向量会在下一次 propose 时按新版本重算一次。
- **PDF 文本**：PDFKit 与 pypdf 的取字算法不同，同页文本可能有细微差别。分页采样、字符预算和截断逻辑完全一致；benchmark fixture 使用固定文本，不受影响。
- **DOCX 合并单元格**：python-docx 会为横向合并的单元格重复文本，当前实现每个 `w:tc` 只取一次。仅影响表格含合并单元格的文档，且只用于分类。
- **casefold**：使用 `lowercased()` 近似 Python `casefold()`（`ß`→`ss` 等少数映射不同），影响仅限于文件名/链接的大小写归一化。
- **evaluated `str.isspace()` 集合**：`Py.isSpace` 与正则中的 `\s` 手工补齐了 ICU 与 CPython 不一致的少数空白字符（`\v`、`\x1c-\x1f`、`\x85`）。

## 残留事项

- 用户数据目录中由旧版本写入的 `~/Library/Application Support/DownloadsOrganizer/bin/`（Python 时代编译的 helper）已不再被使用，可以手动删除；数据库本身无需重建，schema 版本仍为 6，原生核心直接打开了 Python 写入的现有数据库。
- 仓库根目录的 `.venv/` 是迁移期的 Python 参考环境，已被 `.gitignore` 忽略，保留用于将来复核；它不参与构建与分发。
- `dist/` 中旧版本的 Python wheel/sdist 属于迁移前产物，可以删除。
