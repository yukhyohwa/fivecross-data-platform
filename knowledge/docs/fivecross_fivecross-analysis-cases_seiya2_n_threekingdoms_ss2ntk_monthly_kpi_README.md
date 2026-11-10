# 星矢东南亚、星矢繁体、新三国 2026 年月度 KPI 统计项目 (`ss2ntk_monthly_kpi`)

本项目旨在统计 **星矢东南亚 (Saint Seiya SEA)**、**星矢繁体 (Saint Seiya TC)** 和 **新三国 (New Three Kingdoms / NTK)** 2026 年 1 至 6 月各月的月度核心 KPI、新老用户流水分布与 ARPU 表现。

---

## 🎯 目标游戏与标识映射 (App ID Mapping)

| 游戏名称 | 大区标识 | MaxCompute (ODPS) `app_id` | ThinkingData (TA Trino) `applicationid` / `productid` |
| :--- | :--- | :--- | :--- |
| **星矢繁体** (Saint Seiya TC) | 台湾 / 繁体 | `'23000113'` | `'23000113'`, `'seiya30tw'` |
| **星矢东南亚** (Saint Seiya SEA) | 东南亚 | `'60000001'` | `'60000001'` |
| **新三国** (New Three Kingdoms) | 国际服 | `'65002004'` | `'65002004'` |

---

## 📅 数据源拆分架构 (Data Source Split)

根据项目数据迁移节点，2026 年 1-6 月的数据源划分为：

1. **1-4 月 (2026-01 ~ 2026-04)**: 基于 **MaxCompute (ODPS)** 引擎查询。
   * **运行脚本**: [`ss2ntk_maxcompute_monthly_kpi_202601_04.sql`](file:///C:/Users/5xgames/Desktop/github/fivecross-sql-lib/common/ss2ntk_monthly_kpi/ss2ntk_maxcompute_monthly_kpi_202601_04.sql)
   * **数据截止与留存说明**: ODPS 历史快照截止到 2026 年 5 月 27 日。4 月注册用户的次月（5月）留存计算由于数据截止原因可能偏小，属已知正常现象。
2. **5-6 月 (2026-05 ~ 2026-06)**: 基于 **数数 / Trino (ThinkingData TA)** 引擎查询。
   * **运行脚本**: [`ss2ntk_trino_monthly_kpi_202605_06.sql`](file:///C:/Users/5xgames/Desktop/github/fivecross-sql-lib/common/ss2ntk_monthly_kpi/ss2ntk_trino_monthly_kpi_202605_06.sql)
   * **数据表**: 统一运行于 `ta.v_event_19`，通过 `applicationid` / `productid` / `affcode` 区分三个不同游戏。
   * **去水黑名单 (`UserBlacklist`)**: 使用项目 19 标签表 `user_result_cluster_19`，严格剔除 `cluster_name IN ('is_water', 'internal_users')` 水军与内部测试账号。

---

## 📊 统计指标算法与公式说明

| 字段名称 | 口径/公式 | 逻辑说明 |
| :--- | :--- | :--- |
| **`游戏`** | `game` | '星矢东南亚' / '星矢繁体' / '新三国' |
| **`月份`** | `month` | '2026-01', '2026-02', ..., '2026-06' |
| **`Sales(USD)`** | `SUM(price_show * exchange)` | 当月充值总流水 (USD) |
| **`MAU`** | `COUNT(DISTINCT account_id)` | 当月有过至少一次活跃登录的去重用户数 |
| **`NUU`** | `COUNT(DISTINCT reg_account_id)` | 首次活跃/注册月份等于当月的去重用户数 |
| **`NUU-Sales(USD)`** | `SUM(nuu_price_show * exchange)` | 当月新增注册用户在当月内产生的充值总流水 (USD) |
| **`占比(%)`** | `NUU-Sales * 100.0 / Sales` | 当月新用户流水占当月总流水的百分比 (%) |
| **`NUU-ARPU`** | `NUU-Sales / NUU` | 新用户当月人均贡献流水 (USD) |
| **`老用户`** | `MAU - NUU` | 当月活跃用户中，注册月份早于当月的老用户数 |
| **`月留存比例(%)`** | `老用户 * 100.0 / LAG(MAU)` | **老用户活跃留存率**: 当月活跃老用户占上月 MAU 的比例 (%) |
| **`老用户-ARPU`** | `(Sales - NUU-Sales) / 老用户` | 老用户当月人均贡献流水 (USD) |

---

## 📂 文件列表与说明

1. **[`ss2ntk_maxcompute_monthly_kpi_202601_04.sql`](file:///C:/Users/5xgames/Desktop/github/fivecross-sql-lib/common/ss2ntk_monthly_kpi/ss2ntk_maxcompute_monthly_kpi_202601_04.sql)**: MaxCompute (ODPS) 环境下执行 1-4 月月度 KPI 统计。
2. **[`ss2ntk_trino_monthly_kpi_202605_06.sql`](file:///C:/Users/5xgames/Desktop/github/fivecross-sql-lib/common/ss2ntk_monthly_kpi/ss2ntk_trino_monthly_kpi_202605_06.sql)**: Trino (TA `v_event_19`) 环境下执行 5-6 月月度 KPI 统计。
3. **[`ss2ntk_combined_monthly_kpi_2026.sql`](file:///C:/Users/5xgames/Desktop/github/fivecross-sql-lib/common/ss2ntk_monthly_kpi/ss2ntk_combined_monthly_kpi_2026.sql)**: 2026 全年 1-6 月跨引擎/跨表聚合与对比全量 SQL。
