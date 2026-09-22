# 架构说明

TopicTidy 是纯原生 Swift 实现：一个 SwiftPM package 同时产出 `TopicTidyCore`（库）、`tt`（CLI）和 `TopicTidy`（SwiftUI 菜单栏应用）。没有 Python runtime、没有 helper 子进程、没有 JSON bridge。

```text
Sources/
├── TopicTidyCore/        扫描、提取、语义、聚类、操作（CLI 与 GUI 共用）
│   ├── Models/           Extracted / IndexedFile / Evidence / ProposedGroup
│   ├── Config/           Settings、课程号正则、路径解析
│   ├── Database/         SQLite3 封装与 schema
│   ├── Scanner/          stat/指纹/来源元数据/索引更新
│   ├── Extractors/       PDF / DOCX / PPTX / 纯文本
│   ├── Semantic/         NLEmbedding、Apple Translation、代表性文本
│   ├── Clustering/       配对评估、complete-link、命名、证据
│   ├── Operations/       预览、移动、撤销、设置、调度、基准
│   ├── Fixtures/         内嵌 benchmark/holdout JSON
│   └── Support/          Python 语义兼容层、文件锁
├── tt/                   swift-argument-parser CLI
└── TopicTidy/            既有 SwiftUI 界面
```

## 分层职责

`TopicTidyCore/Support/PythonCompat.swift` 提供 `Py`（码点长度、切片、`splitlines`、`strip`、码点序比较）、`OrderedCounter`（`Counter.most_common` 的稳定顺序）和 `PyPath`（`pathlib` 式拼接）。迁移要求等价，因此聚类相关的字符串操作按 CPython 语义实现，而不是 Swift 默认的 grapheme cluster 语义。`Sources/tt` 与 `Sources/TopicTidy` 都不重复实现业务逻辑。

`Config` 拥有 `Settings`、`COURSE_PATTERN`、课程前缀 allowlist 和环境变量加载（`DOWNLOADS_ORGANIZER_DOWNLOADS` / `_HOME` / `_DESTINATION`）。`Paths.resolve` 用 `realpath(3)` 解析已存在的路径前缀，与 Python `Path.resolve()` 一致（Foundation 的 `resolvingSymlinksInPath` 不会解析 `/var`、`/tmp`）。

`Database` 直接使用系统 SQLite3，schema 版本 6 与迁移前完全一致，`~/Library/Application Support/DownloadsOrganizer/organizer.sqlite3` 无需重建或迁移。行数据在读取时立即物化（`Row` 是值类型），避免 statement 释放后悬垂指针。

`Scanner` 负责顶层枚举、稳定性检查、SHA-256 指纹、extractor-version cache invalidation 和索引持久化。来源 URL 先读 `com.apple.metadata:kMDItemWhereFroms` xattr，缺失时用 Spotlight 的 `MDItem` API（原生调用，不 fork `mdls`；子进程方式每次约 66 ms，60 个文件会拖慢一个数量级）。它只依赖 `ExtractorRegistry` 接口，不 import PDFKit 之外的具体格式库。

`Extractors` 每个实现都是 `DocumentExtractor`，声明 cache version、遵守文本预算、返回 `Extracted`。PDF 用 PDFKit，只访问采样页；TXT/Markdown 用 Foundation；DOCX/PPTX 使用自带的 `MiniZip` + `XMLParser` 做最小 OOXML 文本提取（`Compression` 框架的 `COMPRESSION_ZLIB` 就是 ZIP 条目里的裸 DEFLATE），不引入第三方依赖，也不实现完整 Office 解析器。

`Semantic` 直接在进程内调用 `NLEmbedding.sentenceEmbedding` 与 Apple Translation：`SemanticText` 生成最多约 2400 字符的代表性文本（标题/摘要/关键词 + 正文前中后采样），`NativeMacOSEncoder` 分块采样后做归一化平均，`Pivot` 只对候选文件补 English pivot，`NativeTranslationBackend` 只使用已安装语言资产，绝不请求下载。语义 backend 版本号因此从 `apple-nlembedding:<系统版本>:<helper 源码摘要>` 变为 `...:native`，旧缓存向量会在下一次 propose 时自动重算。

`Clustering` 一比一保留原规则：课程号冲突是硬负证据、complete-link 要求组间每一对都过阈值、正文课程号需要两个独立文件才升级为强证据、Markdown 链接集合不做传递扩张、generic token 不参与 overlap 放大。`ClusterCache` 只缓存"纯函数"级别的派生值（单个文件的 token、课程号、URL token、域），不改变任何评分，但把 60 文件语料的聚类从 18.8 s 降到 0.7 s。

`Operations` 负责预览、移动、日志恢复和撤销；`Workflow` 组合建议与自动确认；`AppService` 是 GUI 与测试共用的请求/响应门面（原 `gui_bridge.py` 的逻辑，现在进程内）。`Locking` 用 `flock(2)` 保证 CLI、GUI 和每日任务互斥。`Scheduler` 只维护 LaunchAgent，命令指向原生二进制（应用内为 `Contents/Resources/tt`，否则为当前 `tt`）。

SQLite 事务无法与 APFS rename 构成共同原子操作。工具因此在移动前提交 `intent`，移动后立即写结果。下一次启动会检查未结束批次：目标存在且源消失时记为已移动，反之记为未开始，无法唯一判断时记为 ambiguous。撤销会重新计算 SHA-256，检查原路径空闲，再做同卷 rename；冲突只会跳过并报告。中断恢复还会按方案中的 `topic_key` 恢复 association。

自定义整理目录通过 `PreferenceStore` 暴露给 CLI 和 GUI。每个方案固化生成时的根目录，预览、应用和撤销都使用该快照。目标可以位于 Downloads 外，但必须是同一磁盘上的真实目录；文件名冲突使用确定性后缀且绝不覆盖。

取消主题只把当前方案里该主题的成员标记为 `excluded`（不写长期 correction），界面随即把它从侧栏和建议列表中移除，避免留下无法处理的灰色条目；重新扫描会生成新方案，该主题会再次出现。排除单个文件同理，只是主题仍因剩余成员而保留。

GUI 的 `AppModel` 直接调用 `AppService`（actor），不再启动子进程。移动预览在用户确认时再次比较完整清单，防止其他客户端修改方案或目标冲突后执行用户未审阅的位置；只能确认完整主题或全部待整理主题。

## 分发边界

`TopicTidy.app` 只包含 `Contents/MacOS/TopicTidy`、`Contents/Resources/tt` 和图标，没有 Python、没有 helper、没有资源 bundle——两个 benchmark fixture 以 Swift 字面量内嵌，因此应用可任意搬迁。`scripts/build_app.sh` 负责 release 构建、图标生成、bundle 卫生检查（禁止出现 `python`/`*.py`/构建机路径）、逐项签名、DMG 与大小报告。`tt` 与 GUI 共享同一个 `TopicTidyCore`，不存在两套实现。
