# 海外钱包充值明细导出

从数数（ThinkingData / TA）提取海外项目的钱包充值及直购事件，导出统一格式的 CSV。当前任务为 **2026-07-01 至 2026-09-30（含首尾日期）**，全部使用数数数据。新版按用户提供的对账 SQL 输出 14 个字段和每日港币换算金额。

## 目录

| 文件 / 目录 | 用途 |
| --- | --- |
| `sys_run_wallet_export.py` | 生成任务配置、调用数据客户端、复制 CSV 到本目录 |
| `wallet_recharge_trino.sql` | 当前 7–9 月数数查询，包含充值明细和汇率关联 |
| `wallet_recharge_maxcomputer.sql` | 历史 2026 年 4 月 ODPS 查询，当前脚本不执行 |
| `temp_queries/` | 自动生成的任务 JSON，另保留历史任务配置 |
| `output/` | 本次及历史 CSV 导出结果 |

## 数据来源和筛选口径

当前使用数据客户端的 `ta` 引擎，区域为 `global`。查询按 `$part_date` 筛选日期，合并以下事件表：

| 表 | 项目 / 游戏 ID | 额外筛选 |
| --- | --- | --- |
| `ta.v_event_19` | 圣斗士 2、三国、足球小将等；游戏 ID 从产品 ID 提取 | 钱包事件继续排除 `65002005`；直购事件纳入（包括该 ID） |
| `ta.v_event_20` | 灌篮台湾，固定 `23002013` | 按用户提供的新对账 SQL 映射 |
| `ta.v_event_21` | 灌篮全球，固定 `63002013` | 按用户提供的新对账 SQL 映射 |
| `ta.v_event_22` | 灌篮韩国，固定 `33002013` | 按新 SQL 纳入两种事件，不再使用原产品 ID 排除条件 |

- 四张表均纳入 `LCX_WALLET_PURCHASE_TRANSACTION` 和 `WALLET_DIRECT_CHARGE_PURCHASE`。
- 仅保留 `COALESCE(TRY_CAST(paidamount AS DOUBLE), 0) > 0` 的记录。
- `v_event_19` 的 `game_id` 从 `productid` 中通过正则 `g(\d+)` 提取；灌篮三张表按上表固定映射。
- 使用 `UNION ALL` 合并明细，未按订单 ID 去重，也未额外过滤沙盒、退款或交易状态。
- `store` 固定为 `LCX_WALLET`；`channel_type` 为空字符串或 NULL 时使用 `UNKNOWN`。
- `transaction_type` 保留原始事件名，用于区分钱包充值和直购。

汇率来自数数的 `ta_dim.ta_exchange`：以交易日期、原币币种匹配 `ex.exchange`（币种忽略大小写），以同一天和 `HKD` 匹配 `hkd.exchange`。按用户提供的公式计算港币金额：`paid_amount / COALESCE(ex.exchange, 1.0) * COALESCE(hkd.exchange, 1.0)`。两个汇率字段保留原值（可能为 NULL），仅金额计算使用 1.0 兜底；缺失汇率对应的金额不能视为已完成真实汇率换算。新版不再使用月度人民币汇率。

## 输出字段

| 字段 | 含义 / 来源 |
| --- | --- |
| `months` | 充值月份，`YYYYMM` |
| `day` | 充值分区日期，`YYYY-MM-DD` |
| `channel_no` | `channelno` |
| `productid` | 原始 `productid`，按新 SQL 字段名输出 |
| `lcm_id` | 数数 `#account_id` |
| `game_id` | 灌篮按表固定映射；其他项目从产品 ID 提取 |
| `store` | 固定 `LCX_WALLET` |
| `channel_type` | `channeltype`，空字符串或 NULL 使用 `UNKNOWN` |
| `paid_amount` | `paidamount`，通过 TRY_CAST 转为 DOUBLE，原币金额 |
| `currency_code` | `currencycode` |
| `exchange_rate_usd` | 当日原币 `ex.exchange`，沿用示例字段名 |
| `exchange_rate_hkd` | 当日 HKD `hkd.exchange` |
| `sales_hkd` | 按上述公式计算的港币金额 |
| `transaction_type` | 原始钱包或直购事件名 |

结果按 `day`、`channel_no` 升序排列。

## 运行方法

依赖同级仓库 `fivecross-data-client`，目录布局为：

```text
github/
├── fivecross-analysis-cases/
│   └── platforms/overseas_wallet_recharge/
└── fivecross-data-client/
```

先按数据客户端 README 完成依赖、Playwright 和数数登录配置。脚本优先使用 `fivecross-data-client/venv/Scripts/python.exe`，不存在时使用启动脚本的 Python。

在本目录执行：

```powershell
python sys_run_wallet_export.py
```

执行流程：

1. 读取 `wallet_recharge_trino.sql`，在 `temp_queries/` 生成任务 JSON。
2. 调用客户端 `main.py fetch --task <任务 JSON 路径>`，以 CSV 格式导出。
3. 客户端先保存到 `fivecross-data-client/data/output/`，脚本再将本次新生成、匹配任务名前缀的 CSV 复制到本目录 `output/`。

文件名格式为 `wallet_recharge_202607_202609_trino_v2_<导出时间>.csv`。若客户端返回失败或没有生成匹配的新 CSV，脚本会报错。

## 更换日期范围

日期没有命令行参数，需要同时修改：

1. `wallet_recharge_trino.sql` 中各事件表的日期条件，以及顶部日期说明（汇率按交易日期关联）。
2. `sys_run_wallet_export.py` 中 `TASK_CONFIGS` 的 `name`，使文件名前缀与新日期范围一致。

任务 JSON 会在运行时重新生成，无需手工编辑。修改后同步更新本说明的当前范围；历史导出文件继续保留。

## 新版 2026 年 7–9 月导出记录

2026-10-10 导出文件：[wallet_recharge_202607_202609_trino_v2_20261010_113007.csv](output/wallet_recharge_202607_202609_trino_v2_20261010_113007.csv)。后续对账使用此新版，历史初版文件保留。

| 月份 | 明细行数 |
| --- | ---: |
| 2026-07 | 1,878 |
| 2026-08 | 2,003 |
| 2026-09 | 2,274 |
| 合计 | 6,155 |

其中钱包事件 3,075 条、直购事件 3,080 条。已核对 14 个字段、日期范围 `2026-07-01` 至 `2026-09-30`、范围外记录为 0、金额均大于 0、两种汇率均无缺失、`sales_hkd` 计算与公式一致。行数为事件明细数，不代表去重订单数；尚未与账务系统完成完整性对账。

## 历史初版导出记录（已被新版口径替代）

2026-10-10 导出文件：[wallet_recharge_202607_202609_trino_20261010_111710.csv](output/wallet_recharge_202607_202609_trino_20261010_111710.csv)。

| 月份 | 明细行数 |
| --- | ---: |
| 2026-07 | 925 |
| 2026-08 | 1,087 |
| 2026-09 | 1,063 |
| 合计 | 3,075 |

已核对输出的 12 个字段、三个目标月份和日期边界：最早 `20260701`，最晚 `20260930`，范围外记录为 0。行数表示筛选后的事件明细数，不代表去重订单数；这些检查不构成与账务系统的完整性对账。
