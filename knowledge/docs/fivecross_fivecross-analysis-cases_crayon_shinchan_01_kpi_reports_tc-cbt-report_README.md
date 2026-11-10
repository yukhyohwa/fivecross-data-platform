# 小新繁体 CBT 首周对比报告（最终归档）

最终成果为 `reports/Shinchan_TW_CBT_First_Week_D0_D4_LTV5_Compare_FULL_20260802_r26.pptx` 及同名 `.xlsx`。比较窗为繁体 CBT 2026-07-29～08-02、新加坡 2026-05-08～05-12。

## 保留范围

- `scripts/build_week4_report.mjs`：最终报告构建器，读取 `data/latest/week4_*.csv` 中的14个正式模块及 `survey_group_composition_compare.csv`。
- `sql/`：仅保留与最终14个模块对应的40、41、42、44～50、52～55号查询。
- 问卷行为底表来自相邻 `../../04_surveys_retention/tc-cbt-survey-analysis/data/raw/questionnaire_daily_retention_ltv.csv`。
- `scripts/build_survey_group_compare.py`：问卷构成对照的生成方法；SG输入仍需原始问卷Excel，最终汇总CSV已保留。
- `data/latest/`：正式数据与来源清单，仅本地保留，不提交玩家级原始数据。

早期日报、D0/D1诊断、后续单人付费前事件查询、无关原始数据和中间版报告已移出本目录，保存在项目外的清理备份。最终PPT和Excel内容、哈希未改变。

## 使用

`python main.py` 检查并显示最终文件。`python main.py --build` 使用现有本地底表重建r26，不取新数据。构建依赖既有Codex Artifact Tool Node环境；不要用当前日期自动延长历史CBT查询窗口。
