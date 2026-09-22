# Unseen holdout 评估

评估日期：2026-09-22。实现安全修复并冻结分类权重后，首次运行独立 `holdout_unseen.json`；没有根据该结果继续调参。

holdout 共 42 个半真实文件，其中 22 个属于 8 个预标注主题，20 个应保持未分类。场景包括：

- `report`、`project`、`notes` 等通用文件名；
- 同属太阳能预测领域但来自不同项目的文档；
- 同一下载域名下的税务、住宿和食堂文件；
- 仅有 README 直接链接的集合，以及另带 `Atlas42` 系列标识的 README 集合；
- 中文和英文的电池储能安全资料；
- 内容高度相似但课程号冲突的 COMP4101/COMP4102 和 ECON5001/ECON5002；
- JSON、DMG、ZIP、照片和日常单文件资料。

首次结果：pairwise precision 1.0000、recall 1.0000、F1 1.0000；8 个主题的成员集合精确匹配，20 个未分类文件全部保持未分类。

运行方式：

```bash
tt benchmark Resources/fixtures/holdout_unseen.json --min-f1 0.94
```

迁移到原生 Swift Core 后重新运行同一 fixture，结果不变（同样的 8 个主题、20 个未分类、precision/recall/F1 均为 1.0）；冻结的参考输出保存在 `Tests/TopicTidyCoreTests/Fixtures/benchmark-holdout-golden.json`。

这是一套独立安全回归集，不替代核心 benchmark，也不表示对未知 Downloads 的统计准确率。
