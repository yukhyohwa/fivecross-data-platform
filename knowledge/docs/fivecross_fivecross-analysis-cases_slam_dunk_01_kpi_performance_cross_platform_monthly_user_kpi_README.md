# 灌篮全球 / 韩国跨平台月度用户 KPI

本 case 固化灌篮全球版（63002013）与韩国版（33002013）的月度新增、90 天回流、老用户 KPI：用户数、收入、ARPU 与 D1/D3/D7/D14/D21/D27/D30 留存。

## 数据分段

| 月份 | 平台 | 用户类型 | 观察截止日 |
|---|---|---|---|
| 2026-01 ~ 2026-04 | 阿里云 MaxCompute / ODPS | 新增、回流（90 天流失）、老用户 | 2026-05-27 |
| 2026-05 ~ 2026-06 | 数数 ThinkingData / Trino | 新增、老用户 | 2026-07-21 |

数数只有 2026-05-01 之后的历史，无法可靠判断 90 天流失后回流，因此数数部分不输出回流分类。

## 文件

- `sys_sd_gl_kr_odps_monthly_kpi.sql`：阿里云 1~4 月 KPI。
- `sys_sd_gl_kr_ta_monthly_kpi.sql`：数数 5~6 月 KPI。
- `sys_run_sd_gl_kr_mixed_platform_kpi.py`：调用 `fivecross-data-client`，合并为 CSV/XLSX。
- `VALIDATION_CHECKLIST.md`：重跑或调整日期后的核验项。

## 运行

```powershell
cd C:\Users\5xgames\Desktop\github\fivecross-analysis-cases\slam_dunk\01_kpi_performance\cross_platform_monthly_user_kpi
python .\sys_run_sd_gl_kr_mixed_platform_kpi.py
```

使用已导出的两端 CSV 合并：

```powershell
python .\sys_run_sd_gl_kr_mixed_platform_kpi.py --skip-fetch --odps-csv <odps.csv> --ta-csv <ta.csv>
```

执行结果写入 `reports/`，运行时生成的查询任务写入 `temp_queries/`。

## 核心口径

- 新增：阿里云为 `reg_day = active_day`；数数为当月存在 `NUU`。
- 回流：阿里云距上次活跃超过 90 个完整自然日；数数不做回流拆分。
- 老用户：月活跃中未被归为新增或回流的账户。
- 收入：阿里云 `purchase` 已为 RMB；数数 `PURCHASE` 排除沙盒并按日汇率换算 RMB。
- 留存：按 cohort 日精确 Dn 活跃；`eligible_dN_users` 仅包含到观察截止日已成熟的 cohort，避免未成熟 cohort 被误算作流失。

## 注意事项

- 阿里云 4 月 D30 只覆盖观察截止日前已成熟的 cohort；分母由 `eligible_d30_users` 表示。
- 数数 6 月 D27/D30 同样只使用已成熟 cohort。
- 跨平台结果按月拼接，不对重叠期账户进行跨源去重；本 case 的两段月份由对应平台各自控制。
