# 110 文件真实语料复测

评估日期：2026-09-23。以原有 [50 文件语料](REAL_WORLD_EVALUATION.md) 为基础，在本机 `TopicTidy-RealWorld-50/Downloads` 新增 60 份公开的 Markdown 文档，合计 110 份文件。新增文档的 URL、文件大小、SHA-256 和人工标注保存在本机 `manifest-110.json`；文档本体未提交到公开仓库。

## 语料组成

- 40 份系列课程文档：[Microsoft AI for Beginners](https://github.com/microsoft/AI-For-Beginners)、[Data Science for Beginners](https://github.com/microsoft/Data-Science-For-Beginners)、[Web Dev for Beginners](https://github.com/microsoft/Web-Dev-For-Beginners)、[IoT for Beginners](https://github.com/microsoft/IoT-For-Beginners)、[Generative AI for Beginners](https://github.com/microsoft/generative-ai-for-beginners)，各 8 份。这五个课程同属 GitHub 的 `microsoft` 组织，可检查是否因共用托管站点而误合并。
- 20 份应保持未分类的独立项目 README，来自 Git、Deno、Kubernetes、PyTorch、TensorFlow 等不同仓库。本地文件名使用项目名称，避免 20 个同名 `README.md` 冲突。
- 原有 50 份不变：PDF、PPTX、DOCX 和 Markdown，包括本地课件与公开教学资料。

新增文件均保存真实来源 URL 为 macOS `kMDItemWhereFroms` 元数据。人工标注共 14 个主题、23 个应未分类文件。

## 实测结果

使用最新的纯 Swift `tt` release 构建、全新 SQLite state 和独立目标目录。`scan` 处理 110 份，提取错误 0，用时约 0.95 秒。首次完整语义 `propose` 用时约 30.47 秒，无 Translation 降级警告。按“同组文件对”计分：

| 运行方式 | TP | FP | FN | Precision | Recall | F1 | 建议组 | 未分类 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 跳过语义 | 122 | 0 | 149 | 1.0000 | 0.4502 | 0.6209 | 11 | 62 |
| 完整本地语义 | 217 | 0 | 54 | 1.0000 | 0.8007 | 0.8893 | 17 | 26 |

全部 23 份应未分类文件仍未分类；另有 3 份已标注课程文件还未被归入主题：`07 Python for Data Science.md`、`GitHub Basics.md`、`Prompt Engineering Fundamentals.md`。Microsoft ML、Web Dev 和 IoT 部分课程还被拆成多个建议组，也是 54 个漏分文件对的来源。这批语料上的 Precision 1.0 不代表一般场景的准确率。

## 发现与修复

1. 首轮语义建议卡在 Apple Translation 语言状态查询。同步调用方在主线程等待任务，而该任务可能需要主线程的 run loop。现在使用 detached task、有界等待和主线程 run loop 驱动；`tt semantic status` 已实测能返回 `zh-Hans → en: installed`。
2. GitHub 的原始文件托管域名以及通用的 `README/main/lessons` URL 词汇会让不同仓库获得假的强来源证据。现在识别 GitHub 仓库边界：同仓库是强来源信号；不同仓库的无课程码文件不自动相互聚类。
3. 一份中文 YOLO 学习文档曾因英文 pivot 语义分数约 0.89，被错并入生成式 AI 课程。现在跨语言中等强度命中还需要文件名或来源证据；没有词面线索的文件仍可在 pivot 相似度达到 0.92 时形成建议。

新增的合成 holdout 保护 GitHub 同仓库/异仓库边界，以及没有其他证据时 0.89 的跨语言语义假阳性。完整 `swift test` 和内置 core/holdout benchmark 均通过。

本轮仅执行了 `scan` 与 `propose`，未运行 `apply` 或自动移动。本机的 `manifest-110.json`、`proposal-swift-110-verified.json` 和 `evaluation-swift-110.json` 可供逐文件复核。

## 重复与增量运行（2026-09-24）

在同一台 Mac 上，把原始 110 文件语料复制到新的临时目录和全新 SQLite state；增加与修改操作只发生在临时副本。两轮都调用相同的本地 release 构建、相同已安装的 Apple 语言资产，使用墙钟时间计量单次命令。`propose` 开启原生语义与按需翻译；增加的是一份 Markdown 副本，修改的是该新增文件的正文。数字受系统缓存和后台负载影响，不能当作稳定性能承诺。

| 操作 | 优化前 | 优化后 |
| --- | ---: | ---: |
| 首次 `scan` | 0.89 s | 1.16 s |
| 首次 `propose` | 29.63 s | 20.53 s |
| 无变化再次 `propose` | 12.20 s | 3.77 s |
| 新增 1 文件后 `scan` | 0.05 s | 0.05 s |
| 新增 1 文件后 `propose` | 12.61 s | 3.93 s |
| 修改 1 文件后 `scan` | 0.05 s | 0.05 s |
| 修改 1 文件后 `propose` | 16.38 s | 7.82 s |

采样显示无变化时主要耗时来自 complete-link 聚类重复计算同一文件对。现在同一次 proposal 内只计算一次文件对评分；原有提取、原生语义和翻译结果仍按文件指纹/版本保存在 SQLite。修改后的 proposal 需重新生成该文件的语义向量和可能的 English pivot，因此比无变化运行慢。优化前后的分组结果仍需通过冻结 benchmark 门禁，不能以速度换掉保守性。

另用新的临时副本对原始 110 文件重新 `scan`/`propose`：17 个建议组的成员集合和全部未分类文件，与优化前保存的方案逐项一致。新方案保存在本机 `proposal-swift-110-incremental-verified.json`。
