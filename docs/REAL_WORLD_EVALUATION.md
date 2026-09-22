# 50 文件真实语料评估

评估日期：2026-09-22。测试使用独立 Downloads、独立整理目录和独立 SQLite 状态目录，没有移动真实 `~/Downloads`。

## 语料

语料共 50 个文件：19 PDF、5 PPTX、2 DOCX、24 Markdown。22 个文件来自本机已有课程资料和技术笔记的副本，28 个文件来自公开教学资料：

- [MIT OpenCourseWare 6.622 Power Electronics](https://ocw.mit.edu/courses/6-622-power-electronics-spring-2023/lists/typed-lecture-notes/)：6 PDF；
- [Stanford CS229](https://cs229.stanford.edu/syllabus-spring2021.html)：5 PDF；
- [University of Toronto Neural Networks](https://www.cs.toronto.edu/~hinton/coursera_slides.html)：5 PPTX；
- [Microsoft ML for Beginners](https://github.com/microsoft/ML-For-Beginners)：5 Markdown；
- [SERC course materials](https://serc.carleton.edu/integrate/teaching_materials/carbon_emissions/penny_story.html)：1 DOCX。

网络文件在测试副本中写入真实来源 URL 元数据。预先标注 9 个主题：ELEC6008、ELEC7011、ELEC7043、FreeRTOS、Embedded Linux、MIT 6.622、Stanford CS229、Toronto Neural Networks、Microsoft ML for Beginners；另有 3 个单文件资料应保持未分类。

## 结果

指标按“同组文件对”计算。初次运行产生 9 个组和 22 个未分类文件；最终运行产生 9 个组和 3 个未分类文件。

| 版本 | TP | FP | FN | Precision | Recall | F1 |
|---|---:|---:|---:|---:|---:|---:|
| 优化前 | 32 | 10 | 99 | 0.7619 | 0.2443 | 0.3699 |
| 优化后 | 131 | 0 | 0 | 1.0000 | 1.0000 | 1.0000 |

最终方案识别出的组大小为 3、2、2、9、10、6、5、5、5。YOLO 单文档、ELEC6103 单讲义和能源课程 syllabus 保持未分类，符合保守策略。这里的 1.0000 只表示这批固定语料上的结果，不代表未知 Downloads 的准确率。

随后对最终保存方案执行完整文件操作：47 个已分类文件全部移动成功，创建 9 个主题目录；再执行 `undo`，47 个文件全部验证并恢复，测试 Downloads 回到 50 个顶层文件，整理目录中没有残留文件。3 个未分类文件在整个过程中保持原位。

## 暴露的问题与修改

1. PDF 引文中的 `NOTES2021`、`ORNL2005`，以及普通正文中的 `HAVE1000`、`TASK1000` 曾被课程正则误识别。现在正文课程码使用学科前缀 allowlist，并排除 1900–2099 的年份；文件名和来源 URL 仍可使用较宽的项目代码。
2. 下划线和连字符曾使 `cs229-notes1`、`mit6_622_s23_lec01` 成为一个完整 token。现在分隔符会拆词，并使用集合 overlap 识别稳定系列标识。
3. Apple language detection 对中英代码混排笔记不稳定。native embedding space 现在根据标题和摘要选择稳定语言，语义代表文本版本进入缓存键。
4. FreeRTOS 各章节正文差异大，但标题共享 identifier-like 的 `FreeRTOS`。该信号与语义证据共同使用；普通领域短语不会得到相同权重，避免把 YOLO、Toronto slides 和通用 machine-learning 文档误并。
5. Embedded Linux 笔记由 README 明确链接全部章节。现在可把这种直接链接识别为有界集合，不进行传递式扩张，并输出 `document_links` 证据。
6. 关键词 stopword 和 tokenizer 更新以前不会使 extractor cache 失效。共享文本特征版本现已成为 cache key 的一部分。
7. 自动 proposal 名称曾覆盖新的命名改进。现在仅人工 rename 的名称持久覆盖建议名，内部 `topic_key` 始终不变。

## 复现边界

下载语料和本机课程副本没有提交到公开仓库，避免版权和隐私问题。仓库 benchmark 增加了匿名合成场景，固定保护本轮发现的系列标识、Markdown 索引、伪课程代码、来源域名和课程冲突行为。真实语料目录保留本机供后续回归；`proposal-before.json` 和 `proposal-final.json` 保存了本轮前后输出。
