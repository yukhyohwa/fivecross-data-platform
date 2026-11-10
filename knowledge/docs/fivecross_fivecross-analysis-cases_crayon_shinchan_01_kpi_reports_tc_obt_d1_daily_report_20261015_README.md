# 小新繁体 OBT 第3日报（2026-10-16，最终归档）

最终成果为 `蜡笔小新繁体_OBT第3日报_20261016.xlsx`。`蜡笔小新繁体_OBT次日报_20261015.xlsx` 作为第3日报合并D1用户明细和历史列的底稿保留，不是另一份最新报告。

## 构建链与来源

1. `refresh_d2_latest.py`：按各模块实际执行时间刷新，`data/source/latest_refresh_manifest.json`记录截止时间；历史脚本固定2026-10-16，不要在当前日期重新取数覆盖归档。
2. `prepare_d3_report.py`、`build_d3_conclusions.py`：由CSV形成第3日报输入与结论。
3. `data/chart_qa/d3/build_mainline.mjs`、`build_d3_report.mjs`：正式主线表与报告工作表构建器。虽然历史上放在chart_qa目录，它们是构建依赖，不是可删除的debug脚本。
4. `assemble_d3_updated_details.py`：合并上述工作表、D1用户底稿与当前主线数据。

`build_activity_tables_d2.py`、`build_first_charge_tables.py`分别生成活动和首充/商品分R底表。`sql/`保留12个相关查询；已移除被共享活动快照替代的`08_activity_user_daily_source.sql`。旧D1运行入口、旧报告生成器、日志和图表预览已移出目录，项目外备份可恢复。

## 口径

OBT自2026-10-14起，按fc_id去重；排除internal_users_new、is_water_new、is_windows_new。有效charge排除sandbox、is_freebuy、COIN，按日币别汇率转USD。活动使用1117伙伴、1116坐骑，排除activity_id=0；抽数按资源消耗换算，不以奖励数组长度计数。主线是全局关卡表，不按区服拆分。

`data/`和`tasks/`保留本地来源与审计资料，不上传玩家明细、登录态、查询缓存。Git保留正式SQL、构建代码和最终第3日报。
