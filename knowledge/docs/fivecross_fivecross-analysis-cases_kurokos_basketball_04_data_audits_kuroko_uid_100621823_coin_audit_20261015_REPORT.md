# 黑子的籃球 TC｜UID 100621823 黑子幣稽核

## 結論

查詢範圍為 **2026-10-13 00:00:00～2026-10-15 17:00:00（含首尾）**，資料源為海外數數 `ta.v_event_10`。

- 玩家角色 UID：`100621823`
- 玩家 UUID：`gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412`
- 免費黑子幣：`19999998`
- 付費黑子幣：`19999999`

直接以 UUID 查詢後，確認此前按角色 `gid/#user_id` 的口徑確實漏掉 Web 充值事件。Web 充值事件名為 `srcoin_buy`，其 `gid=0`，並使用獨立的 TA 身份：

- 遊戲角色事件 TA `#user_id`：`1199684065603620864`
- Web 充值事件 TA `#user_id`：`1205183578841813002`
- Web 充值事件 `#account_id`：玩家 UUID

兩類事件可由同一 UUID 串接。

## 汇总

| 币别 | 期初观测余额 | Web充值 | 消费 | 最新可验证余额 |
|---|---:|---:|---:|---:|
| 付费黑子币 | 0 | +8,500 | -8,270 | **230** |
| 免费黑子币 | 5 | +595 | -470 | **130** |
| 合计 | 5 | +9,095 | -8,740 | **360** |

- Web 充值：**4笔**，支付金额合计 **TWD 8,500**。
- 黑子币消费：**7笔 `kuroko_pay` 订单**。
- 余额关系已完整核对：
  - 付费币：`0 + 8,500 - 8,270 = 230`
  - 免费币：`5 + 595 - 470 = 130`

> 最新黑子币余额观测时间为 2026-10-13 21:52:02.374。10月14～15日虽有登录日志，但没有包含这两种币的钱包快照，因此230付费币、130免费币仍表述为“最新可验证余额”，不能冒充2026-10-15 17:00的直接即时快照。

## Web充值与消费明细

| 时间 | event_name | role_id | uuid | 免费币before | 免费币diff | 免费币after | 付费币before | 付费币diff | 付费币after | extra_info |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|
| 2026-10-13 14:12:51.344 | srcoin_buy | 0 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 5 | 400 | 405 | 0 | 5000 | 5000 | pay_currency：TWD pay_amount：5000 order_id：6c029f70-09b6-44fe-bedf-be9f20ce59b5 |
| 2026-10-13 14:13:41.270 | charge | 100621823 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 405 | 0 | 405 | 5000 | -3000 | 2000 | pay_currency：kuroko_pay product_id：ProphetKuroko.tw.Payment3000.gift478 |
| 2026-10-13 14:13:46.989 | charge | 100621823 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 405 | 0 | 405 | 2000 | -1990 | 10 | pay_currency：kuroko_pay product_id：ProphetKuroko.tw.Payment1990.gift477 |
| 2026-10-13 14:17:01.127 | srcoin_buy | 0 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 405 | 120 | 525 | 10 | 2000 | 2010 | pay_currency：TWD pay_amount：2000 order_id：fac9ef9f-36e3-42b0-ac9b-1cd815ff6155 |
| 2026-10-13 14:17:29.259 | charge | 100621823 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 525 | 0 | 525 | 2010 | -1490 | 520 | pay_currency：kuroko_pay product_id：ProphetKuroko.tw.Payment1490.gift476 |
| 2026-10-13 14:17:42.978 | charge | 100621823 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 525 | -470 | 55 | 520 | -520 | 0 | pay_currency：kuroko_pay product_id：ProphetKuroko.tw.Payment990.gift475 |
| 2026-10-13 21:47:44.715 | srcoin_buy | 0 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 55 | 50 | 105 | 0 | 1000 | 1000 | pay_currency：TWD pay_amount：1000 order_id：9a88b5cf-b555-4601-a78e-dc167f6880ea |
| 2026-10-13 21:48:08.006 | charge | 100621823 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 105 | 0 | 105 | 1000 | -670 | 330 | pay_currency：kuroko_pay product_id：ProphetKuroko.tw.Payment670.gift474 |
| 2026-10-13 21:51:42.176 | srcoin_buy | 0 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 105 | 25 | 130 | 330 | 500 | 830 | pay_currency：TWD pay_amount：500 order_id：6ff84e30-ad09-4060-b690-69d46d75915c |
| 2026-10-13 21:51:56.255 | charge | 100621823 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 130 | 0 | 130 | 830 | -450 | 380 | pay_currency：kuroko_pay product_id：ProphetKuroko.tw.Payment450.gift473 |
| 2026-10-13 21:52:02.374 | charge | 100621823 | gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412 | 130 | 0 | 130 | 380 | -150 | 230 | pay_currency：kuroko_pay product_id：ProphetKuroko.tw.Payment150.gift472 |

另查到一笔 `charge` 免费商品事件（`product_id=web.package.tw.0.gift289`、`is_freebuy=true`），仅发放道具 `1100971`，没有免费币或付费币变化，因此未纳入黑子币明细。

## 口径

1. 本次最终明细直接按 UUID 查询，不再先限定角色 `gid/#user_id`。
2. `srcoin_buy` 是Web现金充值，`pay_currency=TWD`，币变动为正数。
3. `charge` 且 `pay_currency=kuroko_pay` 是黑子币消费，币变动为负数。
4. 同一事件内免费币和付费币变化横向合并为一行。
5. 所有金额与余额均来自 `a_rst` 的 `before/diff/after`，未再使用相邻余额差推定充值。

## 输出文件

- `sql/kuroko_coin_event_detail.sql`：UUID-first 最终明细 SQL
- `scripts/run_query.py`：执行最终查询
- `scripts/build_outputs.py`：验证余额关系并生成汇总及 Excel
- `outputs/kuroko_coin_event_detail.csv`：指定格式完整明细
- `outputs/kuroko_coin_event_detail.xlsx`：指定格式 Excel
- `outputs/kuroko_coin_audit_summary.csv`：汇总
