# Order Reconcile: AliCloud (ODPS) vs 数数 (TA)

多游戏统一订单对账工具，比对阿里云（MaxCompute/ODPS）与数数（TA Trino）两侧的充值订单，输出差异明细报告。

---

## 目录结构

```
order_reconcile_alicloud_vs_ta/
├── sys_match_orders.py          # 统一入口脚本
├── README.md                    # 本文档
├── games/                       # 各游戏的 SQL 提取脚本
│   ├── ntk/                     # 新三国
│   │   ├── sys_extract_ta_orders.sql
│   │   └── sys_extract_odps_orders.sql
│   ├── ss2tc/                   # 圣斗士星矢 2 (TC)
│   │   ├── sys_extract_ta_orders.sql
│   │   └── sys_extract_odps_orders.sql
│   ├── sdtc/                    # 灌篮高手 (TC)
│   │   ├── sys_extract_ta_orders.sql
│   │   └── sys_extract_odps_orders.sql
│   └── ct/                      # 足球小将
│       ├── sys_extract_ta_orders.sql
│       └── sys_extract_odps_orders.sql
├── temp_queries/                # 运行时临时文件（自动生成，勿手动修改）
└── order_comparison_results/    # 对账报告输出目录（Excel）
```

---

## 游戏配置一览

| `--game` | 游戏 | ODPS app_id | TA 数据表 | 默认起始日 |
|---|---|---|---|---|
| `ntk` | 新三国 | `65002004` | `ta.v_event_19` | 2026-04-01 |
| `ss2tc` | 圣斗士星矢 2 TC | `23000113` | `ta.v_event_19` | 2026-03-01 |
| `sdtc` | 灌篮高手 TC | `23002013` | `ta.v_event_20` | 2026-04-01 |
| `ct` | 足球小将 | `65002005` | `ta.v_event_19` | 2026-04-01 |

---

## 使用方法

### 前提条件
- 确保 `fivecross-data-client` 已配置并可正常连接 TA 和 ODPS

### 运行

```powershell
cd C:\...\fivecross-sql-lib\common\order_reconcile_alicloud_vs_ta

# 指定游戏和起始日期
python sys_match_orders.py --game sdtc --start 2026-04-01

# 省略 --start 则使用该游戏的默认起始日
python sys_match_orders.py --game ntk
```

### 参数说明

| 参数 | 必填 | 说明 |
|---|---|---|
| `--game` | ✅ | 游戏 ID，可选：`ntk` / `ss2tc` / `sdtc` / `ct` |
| `--start` | ❌ | 起始日期，格式 `YYYY-MM-DD`，省略时使用游戏默认值 |

---

## 匹配逻辑

脚本采用**两轮匹配**策略，尽可能覆盖各平台订单号的差异：

1. **第一轮**：`ta_purchase_id` ↔ `odps_order_id`
2. **第二轮**：对第一轮未匹配的记录，用 `ta_store_order_id` ↔ `odps_order_id` 再次尝试

### 输出报告字段说明

| 字段 | 说明 |
|---|---|
| `match_status` | `Matched` / `Only in TA` / `Only in ODPS` |
| `time_diff_minutes` | TA 与 ODPS 事件时间差（分钟），仅 Matched 行有值 |
| `ta_amt_cny` | TA 侧折合人民币金额 |
| `odps_amt_cny` | ODPS 侧折合人民币金额 |

报告保存在 `order_comparison_results/` 目录下，命名格式：
```
{GAME_PREFIX}_Order_Reconcile_{start_date}_{timestamp}.xlsx
```

---

## 新增游戏

1. 在 `games/` 下新建游戏目录，添加 `sys_extract_ta_orders.sql` 和 `sys_extract_odps_orders.sql`
2. 在 `sys_match_orders.py` 的 `GAMES` 字典中添加对应配置项
