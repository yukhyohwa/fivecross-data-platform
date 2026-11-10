# JUMP Assemble：活跃时长的生命周期用户构成分析

## 要回答的问题

当周 M2 人均在线时长上涨时，先判断是否由用户生命周期构成变化所致，重点检验 **D+1 用户**（首次活跃后第 1 天仍活跃）占比是否上升；再进一步区分：

1. D+1 用户占比上升带来的 **构成效应**；
2. D+1 用户自身玩得更久带来的 **组内时长效应**；
3. D0、D2–D6、D7–D13、D14+ 的构成或时长变化。

本 case 使用 JUMP Assemble TC 数据。所有日期均按 Asia/Shanghai 自然日。

## 已验证的发现（2026-07-27 快照）

比较窗口：

| 指标 | 2026-07-13 至 07-19 | 2026-07-20 至 07-26 | 变化 |
|---|---:|---:|---:|
| M2 人均在线时长 | 28.49 分钟 | 30.73 分钟 | +2.24 分钟（+7.9%） |
| D+1 占 DAU（用户日） | 2.50% | 2.90%* | +0.40pp |

\* D+1 cohort 快照只覆盖到 2026-07-23，因此后一期 D+1 指标实际比较的是 07-20 至 07-23，不能当成完整 7 天的精确周环比。

结论：D+1 占比回升与 M2 时长回升方向一致，因而是**支持性证据**；但它不是已验证的完整归因。要证明贡献大小，必须执行 `sql/31_m2_duration_by_lifecycle_day.sql`，获得相同 M2 用户口径下每个生命周期桶的人数、时长和人均时长。

## 口径

- M2 在线时长：同一用户、同一自然日的相邻事件间隔在 0–119 秒时累计；末尾事件不补偿。
- M2 用户：当日有 `NUU` / `LOGIN_SUCCESS` 的有效账号，排除 `internal_users`、`is_water`；同时排除 `#event_name LIKE '%app%'` 与 `$part_event='role_login'` 的事件流。
- D0/D1：按观察窗口内首次 `NUU` 或 `LOGIN_SUCCESS` 的自然日定义。D1 即首次活跃日期 +1 日。
- 生命周期桶：D0、D1、D2–D6、D7–D13、D14+；互斥且穷尽，因此用户数、总时长可加总回总体 M2。

## 文件说明

```text
sql/31_m2_duration_by_lifecycle_day.sql
    以 M2 同口径输出“日期 × 生命周期桶”的人数、总时长、人均时长、人数占比和时长占比。

scripts/run_m2_lifecycle_query.py
    通过 fivecross-data-client 提交上述 Trino SQL，并保存 CSV。

scripts/build_d1_mix_analysis.mjs
    读取 cohort 与 active_duration SQLite 快照，生成 Excel、每日 CSV 和图表。

data/d1_user_mix_daily_20260727.csv
data/m2_duration_daily_20260727.csv
    本次结论使用的可复核快照。
```

## 复跑步骤

1. 在 `sql/31_m2_duration_by_lifecycle_day.sql` 中修改 `config` CTE 的起止日期。
2. 修改 `scripts/run_m2_lifecycle_query.py` 中 `CLIENT` 为本机 `fivecross-data-client` 路径，并运行：

```powershell
python .\scripts\run_m2_lifecycle_query.py
```

3. 将导出的生命周期 CSV 作为主证据。每个日期都应校验：

```text
sum(active_users by lifecycle_bucket) = m2_active_users
sum(total_duration_min by lifecycle_bucket) = m2_total_duration_min
```

4. 归因时不要只看 D+1 占比。对每个桶同时比较：人数占比、桶内人均时长、时长占比。总体人均时长恒等于：

```text
总体 M2 人均时长 = Σ（生命周期桶人数占比 × 生命周期桶人均时长）
```

建议使用基期人数占比与两期平均人数占比各做一次分解；两者差异作为交互项/残差，避免把构成与组内时长效应混为一谈。

已有的快照可用下列命令生成 Excel。若 SQLite 路径不同，通过环境变量覆盖：

```powershell
$env:MONTH_DB = 'D:\path\to\jump_tc_month1.db'
$env:WEEKLY_DB = 'D:\path\to\jump_tc_weekly.db'
node .\scripts\build_d1_mix_analysis.mjs
```

## 判读框架

| 观察结果 | 可以支持的解释 | 不能直接推断的结论 |
|---|---|---|
| D+1 占比上升，且 D+1 时长高于总体 | D+1 构成对总体时长有正向压力 | 不能仅据时间同步断言“D+1 导致时长上涨” |
| D+1 占比不变，但 D+1 人均时长上升 | D+1 组内行为变深 | 不能说明其他生命周期桶没有贡献 |
| D14+ 时长贡献提升 | 存量核心用户可能是主驱动 | 需要结合玩法、活动、周末或版本变更继续验证 |
| 同一周末各生命周期桶普遍上升 | 周末效应是可检验候选解释 | 需要至少多个周末/工作日配对，不可只看单周 |

## 数据质量与限制

1. DAU cohort 快照是设备口径，而 M2 是账号口径；在没有同口径生命周期 M2 输出前，只能用前者判断构成方向，不能精确量化 M2 贡献。
2. 观察窗口定义“首次活跃”。若要分析回流老用户，应改用全历史首活/注册日期，而非仅窗口内首活。
3. 最近几天数据必须确认已完整落库后再做周环比，避免因数据截断制造假象。
4. 活动、限时玩法、gacha、周末均是待验证的候选驱动；需在生命周期桶内再比较参与/未参与用户，不能只依时间重合做因果结论。
