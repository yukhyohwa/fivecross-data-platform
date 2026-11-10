# 黑子韩服｜UID 100687868｜2026-11-09 黑子币流水核查

## 需求与范围

核查给定 UUID 在 11 月 9 日的黑子币充值、消费及可验证余额。归档位置为 `kurokos_basketball/04_data_audits/kr_uuid_blackcoin_flow_20261109/`。

| 项目 | 口径 |
| --- | --- |
| 用户提供的 UUID | `885c3452-b03c-45a6-be0f-ecc4f9aa7116` |
| 日志中的完整 UUID | `gc_5X_885c3452-b03c-45a6-be0f-ecc4f9aa7116` |
| 游戏角色 UID／gid | `100687868` |
| 区服与源表 | KR，ThinkingData App 12，`ta.v_event_12` |
| 分区与事件边界 | `$part_date = '2026-11-09'`，事件时间 `[2026-11-09 00:00:00, 2026-11-10 00:00:00)` |
| 时间说明 | 沿用 TA 原始事件时间，不另作换算；未独立验证源时区，不能把表内时间直接宣称为韩国当地时间 |
| 数据时点 | 首次明细导出：北京时间 2026-11-09 17:31:17；独立汇总导出：17:34:26；当日未结束 |
| 免费／付费币 | `19999998`／`19999999`，同时核对 `freeCurrency`／`paidCurrency` 语义 |

这是指定账号的证据核查，不因 KPI 黑名单而排除该账号，也不全量导出玩家事件。

## 已验证结果

| 时间（2026-11-09，源事件时间） | 事项 | 付费币变动 | 免费币变动 | 付费／免费币余额 |
| --- | --- | ---: | ---: | --- |
| 09:04:04.891 | Web 充值 KRW 21,000 | +21,000 | +2,100 | 21,000／2,100 |
| 09:05:15.083 | Web 充值 KRW 21,000 | +21,000 | +2,100 | 42,000／4,200 |
| 09:11:28.151 | 商品 `21000178`，`Kuroko.kr.7500.gift173` | −7,500 | 0 | 34,500／4,200 |

- 2 笔充值支付合计 KRW 42,000；实际入账 42,000 付费币、4,200 免费币。
- 1 笔黑子币消费，扣除 7,500 付费币；未消耗免费币。
- 付费币：`0 + 42,000 − 7,500 = 34,500`；免费币：`0 + 4,200 − 0 = 4,200`。
- 查询窗口内未观察到 `charge_fail` 或 `refund_order`。
- 最新钱包观测时间为 09:11:28.151；玩家最后事件为 12:08:11.467，后者不能用作钱包快照。

## 身份与事件关联关系

以完整 UUID 关联两套 TA 身份，不能只用 `gid` 或游戏端 `#user_id` 过滤所有记录：

| 事件侧 | gid | TA `#user_id` | 关联方式 |
| --- | --- | --- | --- |
| Web 充值 `srcoin_buy` | `0` | `1568715648970792982` | 完整 UUID |
| 游戏购买 `charge` | `100687868` | `1568715657783025674` | 同一完整 UUID |

`srcoin_buy` 的 KRW 金额表示充值支付，`a_rst` 正变动表示付费币及赠送免费币入账。`charge + pay_currency=kuroko_pay` 表示内部钱包消费，实际扣币读 `a_rst.diff`；其 `pay_amount=0` 不等于没有消费。

使用 `a_rst` 的具名 `id/before/diff/after/key` 字段。服务端汇总先用 `transform` 按具名字段生成 `(id,diff)`，再展开；不把不同项目的 UNNEST 列位置直接套用到 KR。退款与失败支付只作为各自事件证据，不能合并为成功扣款。

数据链：`identity.sql → UUID/gid/TA 身份与事件覆盖`；`detail.sql → 原始订单及资源明细 → reconcile.py → 中文流水与 audit_summary.json`；`verify.sql → 独立服务端汇总 → reconcile.py 交叉核对`。

## 关联案例与共享依赖

| 来源 | 复用内容 | 本案例的区别 |
| --- | --- | --- |
| [周运营综合需求](../../01_kpi_reports/weekly_comprehensive_requirements/README.md) | 充值与商品消费分开、资源扣除读取方式 | 不沿用 TC 的 `1 黑子币 = 1 TWD` 估值 |
| [BP 购买退款核查](../bp_purchase_refund_audit_20261001_20261101/README.md) | 成功购买、支付失败、退款及钱包充值分开 | 本次按韩服 App 12、指定 UUID 和当日窗口查询 |
| [TC 单玩家黑子币核查](../kuroko_uid_100621823_coin_audit_20261015/README.md) | UUID 关联 Web 充值与游戏消费、前后余额连续性 | 不复用 TC 角色身份或 Trino 数组的隐式列顺序 |
| [游戏 SQL 规则](../../../../fivecross-sql-lib/games/kurokos_basketball/GAME_LOGIC_RULES.md) | KR 源表、身份和资源规则 | 本案例保留 KR 实际支付币种 KRW |
| [数据客户端](../../../../fivecross-data-client/README.md) | 已有 TA 登录与只读查询 | 不在 case 保存凭据、浏览器 profile 或 session |

## 文件与复跑

```text
scripts/prepare_queries.py   生成固定 UUID／日期的 SQL 和客户端 JSON 任务
scripts/run_queries.py       依次查询并保存一组新鲜证据，再执行核对
scripts/reconcile.py         仅使用本案例保存的证据，离线核对并重建结果
sql/identity.{sql,json}      身份映射与当天事件覆盖汇总
sql/detail.{sql,json}        充值、购买、失败、退款及目标钱包资源明细
sql/verify.{sql,json}        独立服务端资源汇总
tests/test_reconcile.py     离线成功及损坏证据回归检查
outputs/*_source.csv        三份原始查询结果
outputs/source_manifest.json 原始导出文件名、提取时点与 SHA256
outputs/audit_summary.json  余额、事件数、口径、限制与核查结果
outputs/*黑子币流水.csv      中文流水，含订单号及前后余额
```

在本 case 根目录执行，Python 使用已有数据客户端的 `.venv` 或 `venv`（Python 3.11+，标准库及 `tzdata`）：

```powershell
$client = 'C:\Users\5xgames\Desktop\github\fivecross-data-client'
$py = "$client\.venv\Scripts\python.exe"
& $py scripts/reconcile.py
& $py -m unittest discover -s tests -v
```

以上为离线复核，不触发查询。重新读取 TA 时执行：

```powershell
& $py scripts/run_queries.py
```

客户端默认从本仓库的同级目录定位，可通过 `FIVECROSS_DATA_CLIENT_ROOT` 覆盖。执行器检查每个查询是否产生本轮新文件，三个查询均成功后才替换本地证据，避免复用客户端历史结果。仅重新生成 SQL 使用 `scripts/prepare_queries.py`。更换 UUID／日期需要同步调整生成脚本、核查脚本中的身份与日期断言、导出前缀和 README。

## 测试方案与验收

| 检查 | 方法 | 预期 |
| --- | --- | --- |
| 身份与窗口 | 核对完整 UUID、11 月 9 日日期及身份覆盖 | Web 充值与游戏购买均保留 |
| 订单与行唯一性 | 对原始事件行、订单号分别去重检查 | 当前 3 条明细无重复 |
| 单条资源算术 | 每币种 `before + diff = after` | 全部通过 |
| 余额连续性 | 前笔 `after` 等于后笔 `before` | 两币种无跳变 |
| 收支闭合 | 首次观测前余额 + 入账 − 扣除 = 最新 after | 付费 34,500，免费 4,200 |
| 独立核验 | 明细 Python 汇总对比 `verify.sql` 服务端汇总 | 两币种的入账、支出分别一致 |
| 回归场景 | 原始证据正常；重复订单；单行算术错误；连续性断裂；独立汇总不一致 | 正常通过，其余拒绝生成成功结果 |
| 目录迁移 | 核对迁移前后文件 SHA256、Python 语法、JSON 和文档相对链接 | 文件保留，执行与引用路径有效 |

回归测试在临时目录复制证据后修改，不改动保存的原始结果；不连接 TA。核查摘要的重新生成时间不代表数据提取时间，提取时间以 `source_manifest.json` 为准。

2026-11-09 本地验收结果：5 项回归测试全部通过，离线重建余额与初次核查一致。目录迁移后检查了 16 份 Python、29 份 JSON、15 个新增索引／本案例相对链接；74 份原有 SQL、CSV、Excel 与本地环境文件内容校验一致。新查询执行器本次仅做语法及静态检查，未再次读取 TA。

## 限制

- 原始导出是 11 月 9 日进行中的快照，晚到日志和当天后续交易可能改变结果。
- 首次 `before=0` 是首次钱包事件发生前的观测，不是独立的零点余额快照。
- 34,500／4,200 是 09:11:28.151 的最新可验证余额，不等同实时或日终余额。
- 未观察到退款仅表示该源、UUID 和窗口内没有匹配事件，不排除外部系统或窗口外退款。
- 玩家级原始资料保留在本地 `outputs/`；代码、SQL、README 与测试方案可纳入版本控制。
