# 架构说明

核心包按职责分层：`scanner` 负责顶层枚举、稳定性检查、指纹、extractor-version cache invalidation 和索引；`extractors` 提供可插拔 `DocumentExtractor` 接口与格式实现；`metadata` 负责 macOS 来源元数据；`text_features` 提供跨格式词元特征；`clustering` 负责结构化证据、课程种子及 complete-link 聚类；`topic_naming` 负责稳定主题命名和内部身份；`operations` 负责预览、移动、日志恢复和撤销；`preferences` 提供持久设置接口；`workflow` 和 `automation` 组合扫描、建议、自动确认与移动；`scheduler` 只负责 macOS LaunchAgent；`cli` 只负责终端输入输出。文件状态未变化但 extractor version 改变时，scanner 复用已有内容指纹、重新提取，并清除 native 与 pivot 缓存。

SQLite 使用 WAL 和外键，当前 schema 版本为 5。`app_settings` 保存目标根目录、自动确认开关和阈值；`files` 保存当前文件身份，`features` 以指纹和 extractor 版本缓存文本、`native_embedding` 及其语言空间；`semantic_pivots` 以文件指纹和目标语言缓存代表性短文本、翻译结果、Translation/embedding 版本和 English pivot vector。文件内容或 extractor 缓存变化时删除对应 pivot；embedding helper 版本变化时复用翻译文本，只重新编码。`topics.topic_key` 是稳定内部身份，`topics.display_name` 是可修改名称。`plans` 与 `plan_members` 保存方案快照、当时的目标根目录及结构化证据，`operation_batches` 与 `operation_logs` 保存每次操作的文件级意图和结果，`associations` 通过 `topic_key` 保存人工确认关系。项目尚未进入用户阶段，因此 schema 不做向后迁移；版本不匹配时重建测试数据库。

语义层使用 `SemanticEncoder` 和 `TranslationBackend` 接口。`semantic_text.build_semantic_text` 从标题、摘要、关键词以及正文前/中/后代表片段生成最多约 2400 字符的输入；embedding 和翻译都不读取全文。默认 embedding helper 调用 `NLEmbedding.sentenceEmbedding`，Translation helper 调用 Apple Translation 的 `LanguageAvailability` 和 macOS 26+ `installedSource` 会话。helper 不安装 Python ML 框架、不访问云端 API，也不请求语言包。

同语言且 `native_embedding_space` 相同时优先比较 native vector。不同语言时，只有两边都具备 English pivot vector 才计算 `semantic_cross_language`；否则该项为零并继续依赖其他证据。pivot 是 propose 阶段的 fallback：课程号冲突或已经足够分类的文件不会翻译。候选先使用 filename/content/source 信号；没有 lexical clue 时，每个文件选择 1 个最近的跨语言候选，14 天内可扩展到 2 个。每轮最多生成 24 个新 pivot，缓存命中不占额度，使多轮 propose 能逐步探索剩余候选。14 天内的零 lexical pair 需要 pivot cosine 至少 0.88 才能凭跨语言语义达到阈值，窗口外要求 0.92。`supported` 但未安装和 `unsupported` 状态只生成降级说明，不会中断方案。

PDF extractor 只访问采样页。少量页面全部读取；大型文档选择前三页、25%/50%/75% 代表页和最后两页。前部页面获得更高字符预算，同时为中部和尾部预留空间，总文本不超过 `max_chars`。

分类顺序是：人工关联 → 强课程号种子 → 无标识文件谨慎附着课程 → 剩余文件 complete-link 聚类。课程号冲突会把 pair score 直接降为零。同域名只是弱证据。complete-link 要求两个组之间每一对文件都达到阈值，避免单个桥接文件把不一致的资料合并。每个结果分别报告课程代码、文件名、正文、原生语义、跨语言语义、来源 URL 的分数和 strong/weak/none 强度。

命名首先采用课程代码；否则从文件名和文档标题中寻找在组内正文得到支持的连续短语，保留自然词序。它不会把高频关键词重新排序后拼成名称。无可靠短语时使用简洁标题或 `Related Documents`。

`benchmark` 从打包的标注 fixture 建立临时数据库，比较 expected 与 predicted 文件对，报告 precision、recall、F1、精确分组匹配和未分类匹配。fixture 覆盖课程讲义、正文课程号、相似名称的不同课程、PDF/DOCX 修改版本、无关归档文件、相同来源 URL 的无关内容、大型 PDF 和中英 English pivot 场景。

SQLite 事务无法与 APFS rename 构成共同原子操作。工具因此在移动前提交 `intent`，移动后立即写结果。下一次启动会检查未结束批次：目标存在且源消失时记为已移动，反之记为未开始，无法唯一判断时记为 ambiguous。撤销会重新计算 SHA-256，检查原路径空闲，再做同卷 rename；冲突只会跳过并报告。

自定义整理目录通过 `PreferenceStore` 暴露给 CLI 和未来 GUI。每个方案固化生成时的根目录，预览、应用和撤销都使用该快照，避免设置变化改写旧方案。目标可以位于 Downloads 外，但必须是同一磁盘上的真实目录；文件名冲突仍使用确定性后缀且绝不覆盖。

`DailyAutomationService` 是每日流程的应用层接口。自动确认默认关闭；显式启用后，它仍先持久化方案，只选择置信度达到阈值且无冲突的完整 topic，并以 `auto_apply` 批次执行。其余成员在该自动方案中排除且不移动。`LaunchAgentScheduler` 负责安装每天一次的用户级 plist，调用 `python -m downloads_organizer auto run`；它不负责分类或移动，也不触发网络访问。

首版的边界是：没有 OCR、没有递归目录扫描、没有云端模型、没有模型下载、没有模型训练。评分是用于排序和审阅的启发式信号，不是校准后的概率。
