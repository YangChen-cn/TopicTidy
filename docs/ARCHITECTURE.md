# 架构说明

核心包按职责分成五层：`scanner` 负责顶层枚举、稳定性检查、指纹和索引；`extract` 负责 macOS 来源元数据和文档文本；`clustering` 负责特征评分、课程种子及 complete-link 聚类；`operations` 负责预览、移动、日志恢复和撤销；`cli` 只负责终端交互。

SQLite 使用 WAL 和外键，当前 schema 版本为 1。`files` 保存当前文件身份，`features` 以指纹和提取器版本缓存文本/向量，`plans` 与 `plan_members` 保存不可隐式执行的方案快照，`operation_batches` 与 `operation_logs` 保存每次操作的文件级意图和结果，`associations` 保存人工确认的主题关系。

分类顺序是：人工关联 → 强课程号种子 → 无标识文件谨慎附着课程 → 剩余文件 complete-link 聚类。课程号冲突会把 pair score 直接降为零。同域名只是弱证据。complete-link 要求两个组之间每一对文件都达到阈值，避免单个桥接文件把不一致的资料合并。

SQLite 事务无法与 APFS rename 构成共同原子操作。工具因此在移动前提交 `intent`，移动后立即写结果。下一次启动会检查未结束批次：目标存在且源消失时记为已移动，反之记为未开始，无法唯一判断时记为 ambiguous。撤销会重新计算 SHA-256，检查原路径空闲，再做同卷 rename；冲突只会跳过并报告。

首版的边界是：没有 OCR、没有递归目录扫描、没有后台 LaunchAgent、没有云端模型、没有模型训练。评分是用于排序和审阅的启发式信号，不是校准后的概率。

