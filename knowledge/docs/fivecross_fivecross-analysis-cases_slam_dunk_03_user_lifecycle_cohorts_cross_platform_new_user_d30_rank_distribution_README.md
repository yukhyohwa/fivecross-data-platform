# 灌篮全球跨平台新增用户 D30 段位分布

本 case 固化“灌篮全球版（GL）新增用户在约第 30 天时的段位分布”分析，解决数据迁移后同一问题需要跨阿里云 MaxCompute 与数数 ThinkingData 查询的问题。

## 本次固定分析范围

| 新增 cohort | 段位观察截止日 | 平台 | 快照角色数 |
|---|---:|---|---:|
| 2026-04-23 ~ 2026-04-26 | 2026-05-26 | 阿里云 ODPS | 1,612 |
| 2026-06-04 ~ 2026-06-07 | 2026-07-07 | 数数 Trino | 2,283 |

这里的“D30”是业务给定的一组新增日期和统一观察截止日，并非对每个注册日逐日严格计算 `注册日 + 30 天`。统计对象也不要求在截止日当天活跃：只要角色在新增日至观察截止日期间存在有效段位快照，就取该角色窗口内最后一条快照。

## 核心口径

- 游戏：灌篮全球版，`app_id = 63002013`，数数事件视图 `ta.v_event_21`。
- 新增用户先按账户识别：阿里云使用 `reg_day`，数数使用 `NUU`。
- 段位按角色统计，最终粒度为 `account/lcm_id + role_id`。
- 一个账户存在多个角色时，每个有有效快照的角色各计一次。
- 不要求第 30 天当天活跃。
- 每个角色取观察窗口内最后一条带段位的快照。
- 阿里云不依赖已停更的 `g63002013_dev.dm_server_user_info`，而是现场使用 `daily_user_snapshot + daily_vip + dim_rankname` 还原其计算逻辑。
- 数数段位使用 `match_rank` 阈值映射；空段位快照会在排序前排除，避免被 `ELSE` 误归为“灌篮高手”。

详细口径见 [METHODOLOGY.md](METHODOLOGY.md)，SQL 分段说明见 [SQL_GUIDE.md](SQL_GUIDE.md)。

## 目录

```text
cross_platform_new_user_d30_rank_distribution/
├─ README.md
├─ METHODOLOGY.md
├─ SQL_GUIDE.md
├─ VALIDATION_CHECKLIST.md
├─ config/
│  └─ analysis.example.json
├─ sql/
│  ├─ 01_odps_april_new_user_rank.sql
│  └─ 02_ta_june_new_user_rank.sql
├─ scripts/
│  └─ run_case.py
└─ outputs/
   ├─ README.md
   └─ baseline_20260721.csv
```

## 执行

环境依赖：`fivecross-data-client` 已配置阿里云与数数登录，Python 环境含 `pandas`。

```powershell
cd C:\Users\5xgames\Desktop\github\fivecross-analysis-cases\slam_dunk\03_user_lifecycle_cohorts\cross_platform_new_user_d30_rank_distribution
C:\Users\5xgames\Desktop\github\fivecross-data-client\venv\Scripts\python.exe .\scripts\run_case.py
```

如数据已分别导出为 CSV，可跳过查询只做合并：

```powershell
C:\Users\5xgames\Desktop\github\fivecross-data-client\venv\Scripts\python.exe .\scripts\run_case.py `
  --skip-fetch `
  --odps-csv <odps.csv> `
  --ta-csv <ta.csv>
```

原始结果写入 `outputs/raw/`，合并后的段位分布 CSV 和汇总 CSV 写入 `outputs/reports/`。

## 修改日期复用

复用到新 cohort 时，需要同步修改两份 SQL 中的三类日期：新增起止日、快照扫描起始日、观察截止日。修改后必须执行 [VALIDATION_CHECKLIST.md](VALIDATION_CHECKLIST.md)，尤其检查数据平台覆盖、快照角色数、空段位和重复角色。

## 来源与固化关系

本 case 从以下工作目录整理而来：

- 原 `fivecross-sql-lib` 跨平台段位工作目录中的正式 SQL 与执行逻辑
- 阿里云历史构表逻辑：`daily_user_snapshot + daily_vip + dim_rankname`
- 数数历史段位逻辑：`ta.v_event_21` 的 `snapshot$` 事件及 `match_rank` 阈值

`fivecross-sql-lib` 仍可作为通用 SQL 库；本目录是包含方法、执行、校验和历史基线的完整分析 case。
