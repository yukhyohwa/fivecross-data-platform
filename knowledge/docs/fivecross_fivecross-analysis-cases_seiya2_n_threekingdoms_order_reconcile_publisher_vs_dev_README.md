# Order Reconcile: Publisher vs Dev

比对**开发方 Excel / CSV 明细**与发行方 **ODPS 或 TA（数数）数据**，识别订单与支付类型，输出对账报告。

圣斗士与新三国的数据源切换口径：2026-03～04 以阿里云 ODPS 为主、TA 补全；2026-05～06 以 TA 为主、ODPS 补全。`hybrid` 会把两个来源的查询边界前后各扩 2 天，并把补全记录明确标记为 `TA_FALLBACK` 或 `ODPS_FALLBACK`。

---

## 目录结构

```
order_reconcile_publisher_vs_dev/
├── sys_match_orders.py          # 统一入口脚本
├── README.md                    # 本文档
├── games/
│   ├── input/                   # ← 开发方提供的 Excel / CSV 放这里
│   │   └── dena-67月.xlsx
│   ├── ntk/
│   │   ├── extract_odps_orders.sql
│   │   └── extract_ta_orders.sql
│   └── ss2/
│       ├── extract_odps_orders.sql
│       └── extract_ta_orders.sql
├── temp_queries/               # 运行时临时文件（自动生成，勿修改）
└── output/                     # 对账报告输出（Excel，自动生成）
```

---

## 游戏配置一览

| `--game` | 游戏 | ODPS app_id |
|---|---|---|
| `ntk` | 新三国 | `65002004` |
| `ss2` | 圣斗士星矢 2 (TC + SEA) | `23000113`, `60000001` |

---

## 使用方法

### 第一步：放入开发方文件

将开发方提供的 Excel 或 CSV 放入 `games/input/` 目录：
```
games/input/dena-67月.xlsx
games/input/圣1繁体充值明细.csv
```

### 第二步：运行脚本

```powershell
cd C:\...\fivecross-sql-lib\common\order_reconcile_publisher_vs_dev

# 新三国 6-7月
python sys_match_orders.py --game ntk --start 2025-06-01 --end 2025-07-31 --input dena-67月.xlsx

# 圣斗士 9-12月
python sys_match_orders.py --game ss2 --start 2025-09-28 --end 2025-12-31 --input 圣1繁体充值明细.csv

# 圣斗士 2026-05～06（TA/数数）
python sys_match_orders.py --game ss2 --source ta --start 2026-05-01 --end 2026-06-30 --input "圣1繁体充值明细(26.3-26.6).csv"

# 圣斗士 2026-03～06 完整版（3～4 月 ODPS、5～6 月 TA）
python sys_match_orders.py --game ss2 --source hybrid --start 2026-03-01 --end 2026-06-30 --input "圣1繁体充值明细(26.3-26.6)_v2.csv"

# 新三国 2026-03-29～06-30（3～4 月 ODPS、5～6 月 TA）
python sys_match_orders.py --game ntk --source hybrid --start 2026-03-29 --end 2026-06-30 --input "荣三3.29-6.30.xlsx"
```

### 参数说明

| 参数 | 必填 | 说明 |
|---|---|---|
| `--game` | ✅ | 游戏 ID：`ntk` / `ss2` |
| `--start` | ✅ | 起始日期 `YYYY-MM-DD` |
| `--end` | ✅ | 结束日期 `YYYY-MM-DD` |
| `--input` | ✅ | 文件名（自动从 `games/input/` 读取），或绝对路径 |
| `--source` |  | 发行方数据库来源：`odps`（默认）、`ta`，或圣斗士／新三国使用的 `hybrid` |

> 支持 `.xlsx`、`.xls`、`.csv`；CSV 自动尝试 UTF-8 / Big5 / GBK 等编码。

---

## 输出报告

报告保存在 `output/` 目录，命名格式：
```
{GAME}_Publisher_Reconcile_{start}_{end}_{timestamp}.xlsx
```

包含三个 Sheet：

| Sheet | 内容 |
|---|---|
| `Reconciliation_Summary` | 数据范围、匹配率和支付类型计数 |
| `Free_Amount_Orders` | 仅含赠送币（`wallet_free > 0`）的订单 |
| `Full_Comparison_Report` | 全部订单，含支付状态分类 |

### 支付状态分类（`payment_status`）

| 状态 | 说明 |
|---|---|
| 纯付费 L 币 | `wallet_paid > 0` 且 `wallet_free = 0` |
| 混合 L 币 | `wallet_paid > 0` 且 `wallet_free > 0` |
| 纯免费/赠送 L 币 | `wallet_paid = 0` 且 `wallet_free > 0` |
| 第三方直接货币支付 | `wallet_paid = 0`、`wallet_free = 0` 且购买金额大于 0 |
| 无付费额度记录 | `wallet_paid = 0`、`wallet_free = 0` 且无购买金额；实际收入暂记为“不明”，待人工确认是否为内部用户 |
| 发行方未匹配 | 发行方数据库中无匹配记录 |
| 沙盒测试 | `validation_type = 'SANDBOX_RECEIPT'`，优先于金额分类 |

上述分类适用于所有记录类型，包括 `PURCHASE_EVENT`、`TA_PURCHASE_EVENT` 和 `WALLET_ONLY`；`source_type` 不参与支付分类。

`Full_Comparison_Report` 与 `Free_Amount_Orders` 会输出 `实际收入` 列：纯付费 L 币与第三方直接货币支付取开发方明细中的结算金额；纯免费及沙盒取 0；无付费额度记录暂记为“不明”；混合 L 币按付费 L 币占钱包总抵扣的比例分摊开发方结算金额。

---

## 新增游戏

1. 在 `games/<game_id>/` 下新建 `extract_odps_orders.sql`
   - 日期占位符使用 `{start_day_nodash}` 和 `{end_day_nodash}`（格式：`YYYYMMDD`）
2. 在 `sys_match_orders.py` 的 `GAMES` 字典中添加对应配置
