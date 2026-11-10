# CT GL Two-Platform User KPI

足球小子海外项目（Captain Tsubasa GL，`app_id = 65002005`）玩家粒度充值与最后登录时间合并工具。

本工具参考 `common/kpi_overview_v1` 的组织方式：SQL 模板放在当前目录，Python 脚本通过 `fivecross-data-client` 执行查询，最后把两份结果合并成统一报表。

## 目录结构

```text
ct_two_platform_kpi/
├── sys_merge_ct_two_platform_kpi.py          # 执行入口：调用 data-client 跑 SQL 并合并
├── sys_ct_gl_odps_user_recharge_last_login.sql
│                                             # ODPS：开服 2023-12-05 至 2026-05-27
├── sys_ct_gl_ta_user_recharge_last_login.sql # TA：2026-05-28 至 2026-06-10
├── README.md
├── temp_queries/                             # 运行时生成 task json
└── merged_reports/                           # 运行后输出 CSV/XLSX
```

## 数据口径

- ODPS 数据源：`dm_platform.daily_lcx_user_info`
- TA 数据源：`ta.v_event_19`
- 项目识别：`65002005`
- 输出粒度：每个 `lcm_id` 一行
- 合并逻辑：同一 `lcm_id` 的收入相加，最后登录时间取最大值
- 输出字段：`lcm_id`, `total_recharge_cny`, `last_login_time`, `odps_revenue_cny`, `ta_revenue_cny`

## 依赖项目

脚本默认按以下目录关系寻找 `fivecross-data-client`：

```text
github/
├── fivecross-data-client/
└── fivecross-sql-lib/
    └── common/
        └── ct_two_platform_kpi/
```

请确认 `fivecross-data-client/.env` 已配置：

- ODPS Global 凭据
- TA Global 凭据

## 执行方式

进入当前目录后运行：

```powershell
cd C:\Users\5xgames\Desktop\github\fivecross-sql-lib\common\ct_two_platform_kpi
python .\sys_merge_ct_two_platform_kpi.py
```

脚本会依次执行：

1. `sys_ct_gl_odps_user_recharge_last_login.sql`
2. `sys_ct_gl_ta_user_recharge_last_login.sql`
3. 合并两份 CSV，输出到 `merged_reports/`

## 只合并已有 CSV

如果两份 SQL 已经手动跑出 CSV，可以跳过查询：

```powershell
python .\sys_merge_ct_two_platform_kpi.py --skip-fetch --odps-csv <odps.csv> --ta-csv <ta.csv>
```

如果不传 `--odps-csv` 或 `--ta-csv`，脚本会尝试从 `fivecross-data-client/data/output/` 自动寻找最新的对应 CSV。
