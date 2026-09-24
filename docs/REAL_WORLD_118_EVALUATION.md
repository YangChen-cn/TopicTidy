# 118 文件真实语料与来源锚定复测

评估日期：2026-09-24。保留 [110 文件语料](REAL_WORLD_110_EVALUATION.md)的全部文件和人工标签，并从 MIT OpenCourseWare 加入两组官方 PDF 讲义，每组四份：

- [6.006 Introduction to Algorithms，Spring 2020](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-spring-2020/resources/lecture-notes/)：Lecture 1 Introduction、3 Sorting、9 Breadth-First Search、16 Dynamic Programming Subproblems。
- [6.046J Design and Analysis of Algorithms，Spring 2015](https://ocw.mit.edu/courses/6-046j-design-and-analysis-of-algorithms-spring-2015/resources/lecture-notes/)：Lecture 1、2、6、9 Notes。

课件保存在本机 `TopicTidy-RealWorld-50/Downloads`，不提交到仓库。`manifest-118.json` 在算法修改前固定两门课程的标签，并记录每份讲义的官方直链、字节数和 SHA-256；`manifest-110.json` 保持不变。最终建议与逐主题计分保存在同目录的 `proposal-upgrade-110-optimized.json`、`proposal-upgrade-118.json` 和 `evaluation-upgrade-118.json`。所有运行使用隔离 SQLite state，仅执行 `scan` 和 `propose`，没有移动文件。

按人工标签的同组文件对计分：

| 语料与算法 | TP | FP | FN | Precision | Recall | F1 | 建议组 | 未分类 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 原 110，v1 历史记录 | 217 | 0 | 54 | 1.0000 | 0.8007 | 0.8893 | 17 | 26 |
| 原 110，升级前一轮 | 210 | 0 | 61 | 1.0000 | 0.7749 | 0.8732 | 18 | 26 |
| 原 110，来源锚定后 | 252 | 0 | 19 | 1.0000 | 0.9299 | 0.9637 | 15 | 24 |
| 扩展 118，优化前 | 218 | 8 | 65 | 0.9646 | 0.7703 | 0.8566 | 20 | 26 |
| 扩展 118，来源锚定后 | 264 | 0 | 19 | 1.0000 | 0.9329 | 0.9653 | 17 | 24 |

新增的 6.006 和 6.046J 各自完整成组，互不混入；优化前 6.046J 的两份讲义曾被错并入 6.006。原 110 文件中的 Microsoft AI（8 份）和 Data Science（8 份）也各自合为一组。16 个标注主题中仍有 Web Dev 的 6+2 分裂，以及一份生成式 AI 入门文档未加入 7 文件核心，共 19 对漏分。23 份预期未分类文件仍全部未分类，最终 proposal 没有翻译警告。

算法修复区分两个问题。`ocw.mit.edu/courses/<课程路径>` 是明确课程来源：不同课程路径形成硬冲突，同一路径提供强来源依据，不能仅凭共享 `ocw.mit.edu` 域名合并。同一 GitHub 仓库或 OCW 课程路径中的异质章节，只有在综合向量和至少两个有效原生语义视图相互佐证、配对支持达到原门槛、全组无冲突时，才能补强固定核心的组级评估；普通多视图配对仍使用两视图平均、三视图中位数。两个小核心合并仍要对所有原始核心双向验证，扩张成员不会继续招募文件。新增组仍受旧算法完整同组的自动整理门槛约束。

本机真实语料是开发与回归样本，不能当作未知 Downloads 的统计精度估计。仓库内的独立升级验收 fixture、原 core 和 holdout 继续作为安全门槛。
