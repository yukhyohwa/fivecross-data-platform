# JUMP TC 2026年7月商品→英雄→漫画收入归因

## 交付

- [最终Excel](outputs/final/JUMP_TC_2026年7月_商品英雄漫画收入归因.xlsx)
- [归因规则与8月复用](docs/归因规则与8月复用.md)
- [独立验证](validation/independent_verification.json)
- [真实查询导出清单及哈希](validation/source_manifest.json)

本次收入基准为用户提供的原始Excel，共51个商品，USD 1,010,985.94。数据来源为真实执行的TA Global `ta.v_event_23` 7月1日至31日流水，以及实时商品/英雄/商店维表；未使用6月流水替代7月。6月case仅复用已验证的作品、稀有度及查询/追踪结构。

**重要限制**：本次SQL现金控制USD 1,011,802.04与用户收入表存在USD 816.10差异。Excel保留源表收入，另列逐SKU SQL对照及差异，未强行调平，原因尚未完全解释。不明USD 23,943.02保留在最后一列及充值权重分母中。仅产出漫画作品收入，不虚构合同发行商/分账。

## July attribution changes and August reuse

The July rules supersede the opening-week allocation rules; do not copy June's single-S-hero mapping or cash-revenue weighting into this case.

- **Monthly S pools:** allocate limited-reading bundles and paid-star spending on limited-reading tickets by actual monthly draws (`SUM(count)`, not event rows). July mappings are pool 101 → Gojo, 102 → Pain, and 103 → Hisoka.
- **A-ticket routing:** first split special-reading ticket value by the actual ticket consumption of pools 2/3/4/5. Pool 2 is the ordinary A pool; allocate its portion equally across its validated non-limited A roster. Pools 3/4/5 map to Itadori/Shinobu/Gon respectively. Validate the month's actual pool rewards and roster rather than inferring membership from adjacent IDs.
- **Independent A activities:** July does not include this activity form. For August, inspect activity-item gain/consumption and the target hero before allocation; do not automatically merge an independent activity into the ordinary A pool.
- **R and generic products:** ordinary-reading tickets and R reset cards are shared equally across the validated R roster. Generic growth, membership and battle-pass products follow the source workbook's all-hero equal-allocation rule. `gift1` is shared across A and R heroes; the user's corrected `gift19` rule is equal allocation across all 29 July heroes, not R-only and not the current S hero.
- **Self-selection bundles:** trace purchase delivery, box inventory and opening rewards; use a unique matching `hero_add` when the hero is absent from the opening resources. Unopened boxes, mixed-source ambiguities and non-unique matches remain unknown. Do not assume FIFO for paid/free mixed inventory.
- **Star recharge revenue:** every recharge SKU uses the same whole-month paid-star consumption allocation vector, including unknown consumption in the denominator. Only paid stars (`id=3`, `gu_type=2`, `nums<0`) are included; free stars and refund recoveries are excluded. This is a monthly allocation estimate, not a causal link from each recharge order to its later use.
- **Units and settlement:** cash bundles and star recharge receipts are both USD and may be summed. Star consumption is only an allocation weight and must not be added as revenue. Aggregate hero amounts to manga; contractual publisher entities and revenue-share rates remain unprovided.
- **August refresh:** update the date window and input revenue workbook, rerun all source queries, refresh S/A pools and monthly eligible heroes, revalidate reused product IDs and self-selection resources, and reconcile source revenue before treating the result as settlement-ready. Preserve July's frozen inputs and outputs.

The detailed Chinese business wording is maintained in [归因规则与8月复用](docs/归因规则与8月复用.md) and the workbook's `口径与8月复用` sheet. The unresolved **USD 816.10** source-vs-SQL difference must remain visible until explained.

## 复现

使用现有客户端虚拟环境Python：

```bash
"C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe" scripts/build_july.py
"C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe" scripts/verify_july.py
```

实际查询已由`fetch_july.py`、`fetch_extra.py`、`fetch_cash_controls.py`通过现有数据客户端执行，任务放于其`tasks/configs/adhoc`。客户端命令必须传任务文件basename：`main.py fetch --task jump_tc_july_complete.json`，不可传adhoc相对完整路径。导出须按完整名称加时间戳匹配，避免`july_hero_`误选`july_hero_reasons_`。

查询和SQL保留在`sql/`、`config/`；原始导出在`data/raw/`且Git忽略。原始输入文件未改动。无提交或推送。

## 验证内容

- 全部商品、英雄、漫画金额按分守恒，原始精确金额合计落分总额守恒。
- `gift19`全部29位英雄均分；全部充值SKU按整月含不明付费星权重分配。
- S权重采用`SUM(count)`；A特供分支采用资源数组实际券耗。
- 大表独立COUNT核对（购买、资源、使用、hero_add），paid-star日控制与消费聚合一致。
- 订单唯一、汇率无缺失、钱包freeamount全为0、库存余额连续。
- 最终Excel保存后独立重新打开；真实导出CSV与客户端原文件哈希及行数一致。
