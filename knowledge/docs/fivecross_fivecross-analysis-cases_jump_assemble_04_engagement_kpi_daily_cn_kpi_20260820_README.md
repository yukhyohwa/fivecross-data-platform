# Jump Assemble CN：2026-08-20 起每日 KPI

## 范围

- 产品：Jump Assemble CN / 数数 China
- 数据源：ThinkingData / Trino
- 路由：`ta.v_event_4`，标签表 `user_result_cluster_4`
- 查询日期：2026-08-20 至 2026-08-23
- 统计粒度：账号
- 2026-08-23 为查询时的未完整自然日，D1 留存标记为 `partial`，不解读为成熟结果。

## 指标

- `active_users`：当天发生 `NUU` 或 `LOGIN_SUCCESS` 的去重账号数。
- `revenue_source`：有效 `PURCHASE` 的原始币种金额；本次结果只有 1 种币种。
- `revenue_usd`：按支付日期与币种关联 `ta_dim.ta_exchange` 后换算的 USD。
- `ltv1_usd`：当天 NUU cohort 的 D0 收入 / NUU 人数。按账号口径，LTV1 只含 D0。
- `d1_retention_pct`：NUU cohort 在次一自然日发生活跃的账号数 / NUU 人数。
- `active_event_rows` / `active_events_per_user`：由于查询区间内没有事件名包含 `session` 的事件，暂以活跃事件行数和人均活跃事件数作为透明代理，不将其命名为真实 session 数。
- 排除：`user_result_cluster_4` 中 `internal_users`、`is_water`；收入排除 `SANDBOX_RECEIPT` 和非正金额。

## 可复用文件

- 本 case SQL：`sql/daily_event4_kpi.sql`
- 查询结果：`outputs/jump_cn_daily_kpi_20260820_20260823.csv`
- Excel：`outputs/jump_cn_daily_kpi_20260820_20260823.xlsx`
- 事件探查结果：`outputs/session_probe_20260820_20260823.csv`

## 参考 SQL 与历史 case

- SQL 库逻辑说明：`C:/Users/5xgames/Desktop/github/fivecross-sql-lib/games/jump_assemble/GAME_LOGIC_RULES.md`
- SQL 库账号维度分时 KPI：`C:/Users/5xgames/Desktop/github/fivecross-sql-lib/games/jump_assemble/trino/ja_cn_hourly_kpi_account_dim.sql`
- SQL 库设备级 KPI、留存、LTV 模板：`C:/Users/5xgames/Desktop/github/fivecross-sql-lib/games/jump_assemble/trino/obt/ja_obt_user_kpi_stats_device_accel_with_zone.sql`
- analysis case 月度 TA CN KPI：`C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/dual_platforms/kpi_overview_v1/sys_kpi_ta_cn.sql`
- analysis case 活跃时长与 D1 构成：`C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/jump_assemble/04_engagement_kpi/active_duration_lifecycle_mix/`

## 执行方式

使用 `fivecross-data-client` 已有环境，不另写连接：

```text
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe main.py fetch --task ja_cn_daily_event4_kpi_20260820_20260823.json
```

任务配置显式使用 `engine=ta`、`region=china`。不要将 Jump CN 改路由到 Global 的 event23。
