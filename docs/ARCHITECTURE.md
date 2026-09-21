# 架构说明

核心包按职责分层：`scanner` 负责顶层枚举、稳定性检查、指纹和索引；`extractors` 提供可插拔 `DocumentExtractor` 接口与格式实现；`metadata` 负责 macOS 来源元数据；`text_features` 提供跨格式词元特征；`clustering` 负责结构化证据、课程种子及 complete-link 聚类；`topic_naming` 负责稳定主题命名和内部身份；`operations` 负责预览、移动、日志恢复和撤销；`cli` 只负责终端交互。

SQLite 使用 WAL 和外键，当前 schema 版本为 2。`files` 保存当前文件身份，`features` 以指纹和具体 extractor 版本缓存文本/向量，`topics.topic_key` 是稳定内部身份，`topics.display_name` 是可修改名称。`plans` 与 `plan_members` 保存不可隐式执行的方案快照及结构化证据，`operation_batches` 与 `operation_logs` 保存每次操作的文件级意图和结果，`associations` 通过 `topic_key` 保存人工确认关系。项目尚未进入用户阶段，因此 schema 不做向后迁移；版本不匹配时重建测试数据库。

PDF extractor 只访问采样页。少量页面全部读取；大型文档选择前三页、25%/50%/75% 代表页和最后两页。前部页面获得更高字符预算，同时为中部和尾部预留空间，总文本不超过 `max_chars`。

分类顺序是：人工关联 → 强课程号种子 → 无标识文件谨慎附着课程 → 剩余文件 complete-link 聚类。课程号冲突会把 pair score 直接降为零。同域名只是弱证据。complete-link 要求两个组之间每一对文件都达到阈值，避免单个桥接文件把不一致的资料合并。每个结果分别报告课程代码、文件名、正文、语义、来源 URL 的分数和 strong/weak/none 强度。

命名首先采用课程代码；否则从文件名和文档标题中寻找在组内正文得到支持的连续短语，保留自然词序。它不会把高频关键词重新排序后拼成名称。无可靠短语时使用简洁标题或 `Related Documents`。

`benchmark` 从打包的标注 fixture 建立临时数据库，比较 expected 与 predicted 文件对，报告 precision、recall、F1、精确分组匹配和未分类匹配。fixture 覆盖课程讲义、正文课程号、相似名称的不同课程、PDF/DOCX 修改版本、无关归档文件、相同来源 URL 的无关内容和大型 PDF 场景。

SQLite 事务无法与 APFS rename 构成共同原子操作。工具因此在移动前提交 `intent`，移动后立即写结果。下一次启动会检查未结束批次：目标存在且源消失时记为已移动，反之记为未开始，无法唯一判断时记为 ambiguous。撤销会重新计算 SHA-256，检查原路径空闲，再做同卷 rename；冲突只会跳过并报告。

首版的边界是：没有 OCR、没有递归目录扫描、没有后台 LaunchAgent、没有云端模型、没有模型训练。评分是用于排序和审阅的启发式信号，不是校准后的概率。
