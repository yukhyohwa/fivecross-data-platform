# 台湾服殿堂活动收入归因

本项目仅保留最终简报及其直接来源，比较殿堂流川与殿堂三井上线首 7 日（D0–D6）。

## 最终交付

- `outputs/台湾服_殿堂活动收入归因_精简版_20261009.pptx`

简报共 5 页：封面、活动周总收入对比、人数／ARPU 两因素拆解、人数／付费率／ARPPU 三因素拆解、结论。

## 保留文件

- `data/raw/sd_decline_04_hof_package_funnel_20261009T021745344856Z_20261009_101803.csv`：最终简报使用的首 7 日活跃、全量付费及礼包指标。
- `data/raw/sd_decline_04_hof_package_funnel_20261009T021745344856Z.json`：上述数据的查询来源与校验记录。
- `sql/04_hof_package_funnel.sql`：对应的 ThinkingData 唯读查询。
- `docs/mitsui_package_ids.md`：三井礼包及目标道具映射依据。
- `scripts/build_hof_total_revenue_ppt.mjs`：重建最终简报。

## 口径

- 台湾服，流川 2026-06-04、三井 2026-09-24。
- 两场均使用 D0–D6。
- 全量收入来自去重后的有效 `PURCHASE`，按每日汇率换算为 CNY。
- 礼包购买率 = 礼包付费账号 ÷ 活跃账号。
- 未查询阿里云；数据来自 ThinkingData TA。
