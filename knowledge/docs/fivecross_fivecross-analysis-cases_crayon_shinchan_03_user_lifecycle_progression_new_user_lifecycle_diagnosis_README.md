# 蜡笔小新新用户生命周期诊断 Case

用于分析蜡笔小新（Crayon Shin-chan）繁体 App 18 的首周表现，并可用新加坡 App 13 作为成熟参照。分析链路：

`新增/活跃 → 付费转化与收入 → 首日留存 → 主线推进与卡点`

## SQL

| 文件 | 用途 | 主要输出 |
|---|---|---|
| `sql/01_cbt_kpi_summary.sql` | 双区域 CBT/OBT KPI 对比 | new_role、login、charge、DAU、付费率、ARPU、ARPPU |
| `sql/02_first_day_retention_compare.sql` | 首日留存对比 | R0/R1/R3/R7/R14/R30 留存人数与留存率、成熟状态 |
| `sql/03_main_stage_bottleneck.sql` | 主线卡点诊断 | 挑战人数、挑战次数、推进代理通过率、重复挑战卡点 |

## 使用前必须修改

1. `01_cbt_kpi_summary.sql`：替换 `{{START_DATE}}`、`{{END_DATE}}`；同时检查 SQL 中 SG 参照期是否仍为目标日期。
2. `02_first_day_retention_compare.sql`：替换繁体与新加坡的 cohort 日期和观察窗口；繁体 R1 只有在次日自然日结束后才可作为成熟值。
3. `03_main_stage_bottleneck.sql`：替换 `{{START_DATE}}`、`{{END_DATE}}`，并确认 `stage_fight.a_rst[1].key = 1001` 与维表 `dim_18_0_52765` 的实际字段。

## 固定口径

- App 18 使用 `ta.v_event_18`，App 13 使用 `ta.v_event_13`；事件表和标签表后缀必须一致。
- 活跃使用 `login`，新增使用 `new_role`，不得使用 `NUU`。
- 有效充值使用 `charge`，排除 `sandbox` 与 `is_freebuy`。
- App 18 收入使用 `pay_amount / ta_dim.ta_exchange.exchange`；App 13 的 `pay_amount_usd` 已是 USD，不重复换算。
- 默认排除 `internal_users`、`is_windows`、`is_water`；若业务要求不同，必须在报告中显式记录。
- 主线“通过率”和“卡点”是行为代理：重复挑战不能直接声称为失败，最高关卡重试仅表示观察到的卡点信号。

## 执行顺序

1. 先执行 `01_cbt_kpi_summary.sql`，确认日期、区域和样本量。
2. 再执行 `02_first_day_retention_compare.sql`，确认 cohort 是否成熟。
3. 最后执行 `03_main_stage_bottleneck.sql`，定位需要结合等级、付费和留存进一步分析的关卡。

本 case 的 SQL 来源于 `fivecross-sql-lib/games/crayon_shinchan`，保留原始字段与维表引用，便于回溯和继续扩展。
