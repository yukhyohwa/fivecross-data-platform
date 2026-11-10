# KR event_24：charge.shop 与 pay_currency 专项

固定事件时间上界：`2026-11-06 11:30:00`（不含；沿用数仓事件时钟，不额外转换时区）。

最近30日（2026-10-08～11-06）`charge` 为 **0 条**，今天截至上界为 **0 条**。

**shop 数仓字段不存在，三个枚举均无法判定币种映射。** 这里的未知不是每个枚举“0条”或已验收。

| shop | pay_currency 实查 | 状态 |
|---:|---|---|
| 1 | 无可分组样本 | 没有属性：shop列不存在；无法按枚举分组 |
| 2 | 无可分组样本 | 没有属性：shop列不存在；无法按枚举分组 |
| 3 | 无可分组样本 | 没有属性：shop列不存在；无法按枚举分组 |

扩大到2026-07-10～11-06，找到 **8条历史charge日志**；日期为2026-07-21、2026-07-23。
币种为 `JPY`，地区为 `JP`；其中 **8/8条为sandbox=true**，不能视为KR正式支付的正确币种。

已检查这8条日志的顶层字段，并解析8条token；token内shop路径：{}。不将store_type或shop_buy.shop_id冒充charge.shop。

## 文档待修正

- 原始文档 charge.shop 的显示名为“折扣”，说明为95、80、100，与本次待验的商店枚举1、2、3不一致。
- charge.store_type 在同一事件中重复定义，并出现不同枚举说明，应合并确认。
- pay_currency 说明沿用了其他项目的粉钻/积分文字，不能作为KR映射依据。

## 结论与验收条件

本次不能给出shop=1/2/3对应的正式币种映射。需要先确认event_24的KR正式环境与上报版本，补上shop字段，并分别提供三种场景的charge日志；再按同条日志核对shop、pay_currency、store_type、charge_region、sandbox和is_freebuy。

分组SQL、聚合结果及三个枚举状态见 [`charge_shop_currency_ce73d888019b`](target/charge_shop_currency_ce73d888019b/)。

没有触发样本不等于证明功能漏报；历史JP沙盒日志也不证明KR正式支付币种错误。
