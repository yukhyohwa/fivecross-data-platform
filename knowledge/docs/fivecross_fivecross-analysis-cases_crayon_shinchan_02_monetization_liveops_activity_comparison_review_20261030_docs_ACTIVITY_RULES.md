# 活动规则与关键时间表（历史副本）

> 当前规则与时间表的权威入口已拆分至 `../../activity_event_timetable_20261030/docs/ACTIVITY_RULES.md` 及其 `reference/` 文件。本文件仅保留活动比较 case 在历史验证时使用的规则快照，不再作为后续排期维护入口。

## 通用业务口径

- 先读此规则表；未来确有分析需求才按需重新取数，不因引用规则而刷新数据库。
- 只有用户明确指令才更新Excel/PPT；本reference不接入运行中report config，历史报告未改算。
- 除露营父子例外，其它当前名册按首位有效new_role自然日为D1，午夜换天；[open_date+(startD-1),open_date+endD)。
- 开服锚点排water/windows/internal；收入与登录不套用锚点FC长度条件。
- 现金排water/windows/sandbox/freebuy/COIN且保internal；晶钻额外排internal_users_new，shop_item[1].item_id=10206，num/100仅一次。
- 联合付费为跨产品/跨服/跨渠道distinct FC并集；不能加渠道UV。现金TWD+晶钻1:1为消费等值非财务净收入；资金充值/转换独立排重。
- 未知为JSON null（CSV以null显示）；配置ID、实例ID、奖励物ID、消耗物ID不互换。first/last仅观测，不是正式开关。

**历史覆盖状态：** 野外露营及垂钓/盲盒以2026-11-04自然日期开始；旧D22–D28已被用户确认覆盖。结束日期待确认，不能推2026-11-10。运行中config、历史SQL、Excel/PPT及其数值原样保留，尚未按新规则重算。

## 当前case完整名册

共 **11 条**：配置中的8项比较活动，加露营父活动与垂钓/盲盒。不是整个游戏活动全量。其它排期规划逐格保留在JSON的schedule_inventory，共773个非空活动栏单元格；无当前case映射的条目明确标记schedule_only_not_in_current_report，不能当已上线活动。

| 活动 | 父活动 | 排期类型 | 起止 | 消耗道具 | 礼包范围 | 确认状态 |
|---|---|---|---|---|---|---|
| 限时坐骑·钢达姆机器人 | 无 | 开服日龄 | 开服D2–D7 | 10206 晶钻 | 未知（null） | 日龄已确认；未映射字段待确认 |
| 限时伙伴·机器犬小白 | 无 | 开服日龄 | 开服D1–D7 | 10206 晶钻 | 未知（null） | 日龄已确认；未映射字段待确认 |
| 限时伙伴·和服小葵 | 无 | 开服日龄 | 开服D8–D14 | 10206 晶钻 | 未知（null） | 日龄已确认；未映射字段待确认 |
| 欢乐派对 | 无 | 开服日龄 | 开服D8–D14 | 未知（null） 未知（null） | product_name_tc REGEXP '狂歡派對 / 狂欢派对'（先去重product_id） | 日龄已确认；未映射字段待确认 |
| 开心礼盒机1 | 无 | 开服日龄 | 开服D9–D11 | 未知（null） 未知（null） | product_name_tc REGEXP '開心禮盒機 / 开心礼盒机 / 幸運許願池 / 幸运许愿池'（沿用已验证分类器；先去重product_id） | 日龄已确认；未映射字段待确认 |
| 开心礼盒机2 | 无 | 开服日龄 | 开服D15–D17 | 10244 抽奖币 | product_name_tc REGEXP '開心禮盒機 / 开心礼盒机 / 幸運許願池 / 幸运许愿池'（沿用已验证分类器；先去重product_id） | 日龄已确认；未映射字段待确认 |
| 限时技能·飞虹泡泡 | 无 | 开服日龄 | 开服D15–D21 | 10206 晶钻 | 未知（null） | 日龄已确认；未映射字段待确认 |
| 人生大富翁（自选＋时装） | 无 | 开服日龄 | 开服D15–D21 | 未知（null） 未知（null） | 大富翁自选礼包 + product_id=118601（大富翁時裝禮包）；排除大富翁特權卡 | 日龄已确认；未映射字段待确认 |
| 野外露营 | 无 | 自然日期 | 2026-11-04开始；结束待确认 | 未知（null） 未知（null） | 未知（null） | 开始自然日期已确认；结束及精确时刻待确认 |
| 垂钓奇遇 | camping | 自然日期 | 2026-11-04开始；结束待确认 | 10245 鱼饵 | product_id@product_name_tc LIKE '%垂釣%' | 开始自然日期已确认；结束及精确时刻待确认 |
| 盲盒挑战 | camping | 自然日期 | 2026-11-04开始；结束待确认 | 10159 魔法棒 | product_id@product_name_tc LIKE '%盲盒禮包%' | 开始自然日期已确认；结束及精确时刻待确认 |

## 家族别名与分期

开心礼盒机 = 开心福引机 = 娃娃机 = 影像欢乐；关联奖励/活动线索：["坐骑-涂鸦飞机", "奇妙大力锤"]；这些关联名称先作为线索登记，不直接当作礼包SKU或独立活动收入；这些无期号别名只指家族，必须继续指定1/2期，不能直接匹配到某一期。

## 逐活动可复用规则

### 限时坐骑·钢达姆机器人

- 登记键：`mount_gundam`；别名：["坐騎扭蛋(鋼達姆機器人)-1116001"]
- 时间：{"kind": "server_age", "startD": 2, "endD": 7, "natural_start": null, "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日龄窗口已确认；午夜为统计换天规则，不证明后台精确开关时刻", "independent_switch": null}
- event/type/name及ID：{"event": "active_reward", "type": 1116, "name": "限时坐骑-钢达姆机器人", "instance_id": "1126118950174741", "configuration_id": null, "alternate_observed_instances": ["1126441072721921"]}
- 消耗定义：{"item_id": "10206", "name": "晶钻", "event": "item_change", "type": null, "change_source": null, "definition": "仅直接晶钻消费：a_rst中10206正向(before-after)/100；同FC+角色+服后续0–2秒最早目标领奖，单扣减只归属一次；排除±2秒已有正向shop_buy，不能当抽数或礼包购买。"}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": null, "confirmed_skus": null}
- 参与：未知（null）
- 规则优先级：本次用户确认 > 已确认配置/排期 > 已验证SQL与维表 > 事件观测
- 按实际type+id+name区分主题；同名备用实例仅为原始观测，不能自动并入，也不能认定测试。
- 其他召唤券消耗与主题礼包映射未知；现有正式比较采用直接晶钻口径。
- 待确认：后台精确开关时刻；未填的道具、领奖参与及产品映射
- 证据：
  - `config/schedule.json` → mappings[0]
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!J3,J4,J5,J6,J7,J8
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `data/raw/20261104/instances.csv` → type/id/name（不使用first_time/last_time作排期）
  - `sql/current/activity_names_dates_payments.sql` → GachaLogs / SpendRaw / DirectCandidates

### 限时伙伴·机器犬小白

- 登记键：`companion_shiro`；别名：["限時召喚(機械小白（傳奇）)-1117001"]
- 时间：{"kind": "server_age", "startD": 1, "endD": 7, "natural_start": null, "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日龄窗口已确认；午夜为统计换天规则，不证明后台精确开关时刻", "independent_switch": null}
- event/type/name及ID：{"event": "active_reward", "type": 1117, "name": "限时伙伴-机器犬小白", "instance_id": "1126131835076610", "configuration_id": null, "alternate_observed_instances": ["1126591396577283"]}
- 消耗定义：{"item_id": "10206", "name": "晶钻", "event": "item_change", "type": null, "change_source": null, "definition": "仅直接晶钻消费：a_rst中10206正向(before-after)/100；同FC+角色+服后续0–2秒最早目标领奖，单扣减只归属一次；排除±2秒已有正向shop_buy，不能当抽数或礼包购买。"}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": null, "confirmed_skus": null}
- 参与：未知（null）
- 规则优先级：本次用户确认 > 已确认配置/排期 > 已验证SQL与维表 > 事件观测
- 按实际type+id+name区分主题；同名备用实例仅为原始观测，不能自动并入，也不能认定测试。
- 其他召唤券消耗与主题礼包映射未知；现有正式比较采用直接晶钻口径。
- 待确认：后台精确开关时刻；未填的道具、领奖参与及产品映射
- 证据：
  - `config/schedule.json` → mappings[1]
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!H2,H3,H4,H5,H6,H7,H8
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `data/raw/20261104/instances.csv` → type/id/name（不使用first_time/last_time作排期）
  - `sql/current/activity_names_dates_payments.sql` → GachaLogs / SpendRaw / DirectCandidates

### 限时伙伴·和服小葵

- 登记键：`companion_himawari`；别名：["限時召喚(和服小葵（傳奇）)"]
- 时间：{"kind": "server_age", "startD": 8, "endD": 14, "natural_start": null, "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日龄窗口已确认；午夜为统计换天规则，不证明后台精确开关时刻", "independent_switch": null}
- event/type/name及ID：{"event": "active_reward", "type": 1117, "name": "限时伙伴-和服小葵", "instance_id": "1126131835076611", "configuration_id": null, "alternate_observed_instances": ["1126831914745857"]}
- 消耗定义：{"item_id": "10206", "name": "晶钻", "event": "item_change", "type": null, "change_source": null, "definition": "仅直接晶钻消费：a_rst中10206正向(before-after)/100；同FC+角色+服后续0–2秒最早目标领奖，单扣减只归属一次；排除±2秒已有正向shop_buy，不能当抽数或礼包购买。"}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": null, "confirmed_skus": null}
- 参与：未知（null）
- 规则优先级：本次用户确认 > 已确认配置/排期 > 已验证SQL与维表 > 事件观测
- 按实际type+id+name区分主题；同名备用实例仅为原始观测，不能自动并入，也不能认定测试。
- 其他召唤券消耗与主题礼包映射未知；现有正式比较采用直接晶钻口径。
- 待确认：后台精确开关时刻；未填的道具、领奖参与及产品映射
- 证据：
  - `config/schedule.json` → mappings[2]
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!H9,H10,H11,H12,H13,H14,H15
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `data/raw/20261104/instances.csv` → type/id/name（不使用first_time/last_time作排期）
  - `sql/current/activity_names_dates_payments.sql` → GachaLogs / SpendRaw / DirectCandidates

### 欢乐派对

- 登记键：`party`；别名：["歡樂派對", "狂歡派對", "狂欢派对"]
- 时间：{"kind": "server_age", "startD": 8, "endD": 14, "natural_start": null, "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日龄窗口已确认；午夜为统计换天规则，不证明后台精确开关时刻", "independent_switch": null}
- event/type/name及ID：{"event": null, "type": null, "name": null, "instance_id": null, "configuration_id": null, "alternate_observed_instances": []}
- 消耗定义：{"item_id": null, "name": null, "event": null, "type": null, "change_source": null, "definition": null}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": "product_name_tc REGEXP '狂歡派對|狂欢派对'（先去重product_id）", "confirmed_skus": null}
- 参与：未知（null）
- 规则优先级：本次用户确认 > 已确认配置/排期 > 已验证SQL与维表 > 事件观测
- 待确认：后台精确开关时刻；未填的道具、领奖参与及产品映射
- 证据：
  - `config/schedule.json` → mappings[3]
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!J9,J10,J11,J12,J13,J14,J15
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `scripts/current/classification.py` → classify: party regexp

### 开心礼盒机1

- 登记键：`giftbox_1`；别名：["自選-2 代影像(1期)", "开心福引机1", "影像欢乐A"]
- 时间：{"kind": "server_age", "startD": 9, "endD": 11, "natural_start": null, "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日龄窗口已确认；午夜为统计换天规则，不证明后台精确开关时刻", "independent_switch": null}
- event/type/name及ID：{"event": "active_reward", "type": 1048, "name": "影像欢乐", "instance_id": "1126118950174752", "configuration_id": null, "alternate_observed_instances": []}
- 消耗定义：{"item_id": null, "name": null, "event": null, "type": null, "change_source": null, "definition": null}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": "product_name_tc REGEXP '開心禮盒機|开心礼盒机|幸運許願池|幸运许愿池'（沿用已验证分类器；先去重product_id）", "confirmed_skus": null}
- 参与：未知（null）
- 规则优先级：本次用户确认 > 已确认配置/排期 > 已验证SQL与维表 > 事件观测
- 开心礼盒机=开心福引机=影像欢乐是家族别名，不是单一期次别名。两期按各服日龄窗口分摊共享SKU，不是统一自然日期；购买者不必有领奖日志。
- 窗外消费保留全游戏口径，不强塞任一期；单笔至多归属一期。
- 10244为已知家族道具；本期消耗归属未在当前case独立核验，不自动复制第二期定义。
- 待确认：后台精确开关时刻；未填的道具、领奖参与及产品映射
- 证据：
  - `config/schedule.json` → mappings[4]
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!N10,N11,N12
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `scripts/current/classification.py` → classify: giftbox regexp
  - `scripts/current/schedule.py` → calculate: Gift family split
  - `data/raw/20261104/instances.csv` → type=1048, id=1126118950174752

### 开心礼盒机2

- 登记键：`giftbox_2`；别名：["背饰-春日部防衛隊風箏-104801", "开心福引机2", "影像欢乐B"]
- 时间：{"kind": "server_age", "startD": 15, "endD": 17, "natural_start": null, "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日龄窗口已确认；午夜为统计换天规则，不证明后台精确开关时刻", "independent_switch": null}
- event/type/name及ID：{"event": "active_reward", "type": 1048, "name": "影像欢乐", "instance_id": "1126118950174758", "configuration_id": null, "alternate_observed_instances": []}
- 消耗定义：{"item_id": "10244", "name": "抽奖币", "event": "item_change", "type": null, "change_source": null, "definition": "用户确认的实际正向before-after扣减量；一次归属同FC+角色+服后续0–2秒目标领奖。不是10268，不以奖励数组长度代替抽数。"}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": "product_name_tc REGEXP '開心禮盒機|开心礼盒机|幸運許願池|幸运许愿池'（沿用已验证分类器；先去重product_id）", "confirmed_skus": null}
- 参与：未知（null）
- 规则优先级：本次用户确认 > 已确认配置/排期 > 已验证SQL与维表 > 事件观测
- 开心礼盒机=开心福引机=影像欢乐是家族别名，不是单一期次别名。两期按各服日龄窗口分摊共享SKU，不是统一自然日期；购买者不必有领奖日志。
- 窗外消费保留全游戏口径，不强塞任一期；单笔至多归属一期。
- 待确认：后台精确开关时刻；未填的道具、领奖参与及产品映射
- 证据：
  - `config/schedule.json` → mappings[5]
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!N16,N17,N18
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `scripts/current/classification.py` → classify: giftbox regexp
  - `scripts/current/schedule.py` → calculate: Gift family split
  - `data/raw/20261104/instances.csv` → type=1048, id=1126118950174758

### 限时技能·飞虹泡泡

- 登记键：`skill_bubble`；别名：["限時召喚技能 飛虹泡泡(傳奇)"]
- 时间：{"kind": "server_age", "startD": 15, "endD": 21, "natural_start": null, "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日龄窗口已确认；午夜为统计换天规则，不证明后台精确开关时刻", "independent_switch": null}
- event/type/name及ID：{"event": "active_reward", "type": 1122, "name": "限时技能-飞虹泡泡", "instance_id": "1126320813637633", "configuration_id": null, "alternate_observed_instances": ["1126986533568513", "1127059548012545"]}
- 消耗定义：{"item_id": "10206", "name": "晶钻", "event": "item_change", "type": null, "change_source": null, "definition": "仅直接晶钻消费：a_rst中10206正向(before-after)/100；同FC+角色+服后续0–2秒最早目标领奖，单扣减只归属一次；排除±2秒已有正向shop_buy，不能当抽数或礼包购买。"}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": null, "confirmed_skus": null}
- 参与：未知（null）
- 规则优先级：本次用户确认 > 已确认配置/排期 > 已验证SQL与维表 > 事件观测
- 按实际type+id+name区分主题；同名备用实例仅为原始观测，不能自动并入，也不能认定测试。
- 其他召唤券消耗与主题礼包映射未知；现有正式比较采用直接晶钻口径。
- 待确认：后台精确开关时刻；未填的道具、领奖参与及产品映射
- 证据：
  - `config/schedule.json` → mappings[6]
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!H16,H17,H18,H19,H20,H21,H22
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `data/raw/20261104/instances.csv` → type/id/name（不使用first_time/last_time作排期）
  - `sql/current/activity_names_dates_payments.sql` → GachaLogs / SpendRaw / DirectCandidates

### 人生大富翁（自选＋时装）

- 登记键：`monopoly`；别名：["人生大富翁(需要配指定日期)", "人生大富翁-按日期", "人生大富翁", "大富翁"]
- 时间：{"kind": "server_age", "startD": 15, "endD": 21, "natural_start": null, "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日龄窗口已确认；午夜为统计换天规则，不证明后台精确开关时刻", "independent_switch": null}
- event/type/name及ID：{"event": null, "type": null, "name": null, "instance_id": null, "configuration_id": null, "alternate_observed_instances": []}
- 消耗定义：{"item_id": null, "name": null, "event": null, "type": null, "change_source": null, "definition": null}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": "大富翁自选礼包 + product_id=118601（大富翁時裝禮包）；排除大富翁特權卡", "confirmed_skus": [{"id": "118601", "name": "大富翁時裝禮包"}]}
- 参与：未知（null）
- 规则优先级：本次用户确认 > 已确认配置/排期 > 已验证SQL与维表 > 事件观测
- 自选礼包与118601时装纳入；特权卡归特权与月卡，不计本活动。SKU列表为已明确单品，不代表自选礼包全量ID。
- 待确认：后台精确开关时刻；未填的道具、领奖参与及产品映射
- 证据：
  - `config/schedule.json` → mappings[7]
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!I16,I17,I18,I19,I20,I21,I22
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `scripts/current/classification.py` → classify: 大富翁特權卡 before 大富翁

### 野外露营

- 登记键：`camping`；别名：["野外露營", "露營活動", "露營活動(滿月)"]
- 时间：{"kind": "natural_date", "startD": null, "endD": null, "natural_start": "2026-11-04", "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日期确认，精确开关时刻未确认", "independent_switch": null}
- event/type/name及ID：{"event": null, "type": null, "name": null, "instance_id": null, "configuration_id": "1070001", "alternate_observed_instances": []}
- 消耗定义：{"item_id": null, "name": null, "event": null, "type": null, "change_source": null, "definition": null}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": null, "confirmed_skus": null}
- 参与：未知（null）
- 规则优先级：本次用户确认覆盖旧日龄计算
- 旧开服D22–D28只保留为历史排期，不再是当前规则；不据此推算2026-11-10结束。
- 待确认：结束日期；精确开关时刻
- 证据：
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 主題-野外露營!N27:O27
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!J23:J29,T23（已覆盖的历史排期）

### 垂钓奇遇

- 登记键：`fishing`；别名：["垂釣奇遇"]
- 时间：{"kind": "natural_date", "startD": null, "endD": null, "natural_start": "2026-11-04", "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日期确认，精确开关时刻未确认", "independent_switch": null}
- event/type/name及ID：{"event": "active_reward", "type": 1074, "name": "垂钓奇遇", "instance_id": null, "configuration_id": "1074001", "alternate_observed_instances": []}
- 消耗定义：{"item_id": "10245", "name": "鱼饵", "event": "item_change", "type": 2, "change_source": 43, "definition": "sum(a_rst中id=10245且before>after的before-after)，仅type=2/change_source=43；资源量不等于认证钓鱼次数；注意结束转换。"}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": "product_id@product_name_tc LIKE '%垂釣%'", "confirmed_skus": null}
- 参与：active_reward type=1074 AND name=垂钓奇遇，领奖FC去重；参与率=同窗领奖FC/登录FC，不强制参与者有当日登录。
- 规则优先级：本次用户确认覆盖旧日龄计算
- 旧开服D22–D28只保留为历史排期，不再是当前规则；不据此推算2026-11-10结束。
- 仅继承父活动时间；独立开关待确认；不继承父领奖、产品或参与范围。
- 待确认：结束日期；精确开关时刻；是否独立开关
- 证据：
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 主題-野外露營!N23:O23
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!J23:J29,T23（已覆盖的历史排期）
  - `config/fishing.json` → reward_type/reward_name/bait_item/bait_type/bait_change_source/product_name_tc_like；startD/endD已覆盖
  - `sql/dashboards/fishing_daily.sql` → Participation / ConsumeEvents / GiftProducts
  - `evidence/supplements/fishing/fishing_dimensions.csv` → kind=item,id=10245

### 盲盒挑战

- 登记键：`blind_box`；别名：["盲盒挑戰"]
- 时间：{"kind": "natural_date", "startD": null, "endD": null, "natural_start": "2026-11-04", "natural_end": null, "start_at": null, "end_at": null, "timezone": "Asia/Shanghai", "certainty": "日期确认，精确开关时刻未确认", "independent_switch": null}
- event/type/name及ID：{"event": null, "type": null, "name": null, "instance_id": null, "configuration_id": "1076001", "alternate_observed_instances": []}
- 消耗定义：{"item_id": "10159", "name": "魔法棒", "event": "item_change", "type": null, "change_source": null, "definition": "sum(a_rst中id=10159且before>after的before-after)，全source正向扣减；可能含活动结束转12000金币，不能称成功开盒或抽数。"}
- 奖励物清单：未知（null）；奖励物不得当消耗物。
- 礼包：{"dimension": "ta_dim.dim_18_0_52801", "filter": "product_id@product_name_tc LIKE '%盲盒禮包%'", "confirmed_skus": null}
- 参与：未知（null）
- 规则优先级：本次用户确认覆盖旧日龄计算
- 旧开服D22–D28只保留为历史排期，不再是当前规则；不据此推算2026-11-10结束。
- 仅继承父活动时间；独立开关待确认；不继承父领奖、产品或参与范围。
- active_reward type/name未知，configuration_id=1076001不等于已验证事件type；不能据配置ID前缀猜1076。
- 参与人数与参与率必须NULL；不得以消耗FC或父活动领奖替代。
- 有限探针type2/source43为观测，不是全部消耗范围，也未证明与active_reward关联。
- 待确认：结束日期；精确开关时刻；是否独立开关；active_reward type/name与领奖参与定义；结束转换与真实开盒扣减区分
- 证据：
  - `docs/ACTIVITY_RULES_CONFIRMATION.md` → 本次用户确认 / 2026-11-06
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 主題-野外露營!N21:O21,B144:B145
  - `蠟筆小新-繁體版開服活動整理 (1).xlsx` → 活動排期_obt調整版!J23:J29,T23（已覆盖的历史排期）
  - `sql/dashboards/blind_box_daily.sql` → ConsumeEvents / GiftProducts / SELECT NULL participation
  - `evidence/supplements/blind_box/blind_dimensions.csv` → item_id@item_id=10159
  - `evidence/supplements/blind_box/blind_control.csv` → 历史0–2秒关联控制

## 露营子配置清单（规划证据，不认证已上线）

配置ID不是active_reward.type或实例ID；N21盲盒标预热而B144:C144标主体，说明规划内部存在阶段差异，不能据此认定独立开关。Q列旧时间戳与A1:B1主题说明不构成2026-11-04精确发布依据。其它露营子项未纳入当前报表，不继承已验证的垂钓/盲盒产品范围。

| 配置ID | 源名称 | 阶段备注 | 单元格 | 当前登记 |
|---|---|---|---|---|
| 1080001 | 趣味集卡任务 | 預熱 | N17:Q17 | 未知（null） |
| 1079001 | 露营自选礼包 | 預熱 | N18:Q18 | 未知（null） |
| 1078001 | 每日登录 | 預熱 | N19:Q19 | 未知（null） |
| 1077001 | 签到好礼 | 主體 | N20:Q20 | 未知（null） |
| 1076001 | 盲盒挑战 | 預熱 | N21:Q21 | blind_box |
| 1075001 | 露营计划 | 主體 | N22:Q22 | 未知（null） |
| 1074001 | 垂钓奇遇 | 主體 | N23:Q23 | fishing |
| 1073001 | 野炊大餐 | 預熱 | N24:Q24 | 未知（null） |
| 1072001 | 野炊大餐 | 預熱 | N25:Q25 | 未知（null） |
| 1071001 | 趣味集卡 | 預熱 | N26:Q26 | 未知（null） |
| 1070001 | 野外露营 | 未知（null） | N27:Q27 | camping |

## 离线维护与验证

```bash
python scripts/activity_rules.py build
python scripts/activity_rules.py validate
```

仅build重生成本Markdown和reference CSV；validate只读取。两者均不访问数据库、不运行正式报告build、不修改任何原xlsx/PPT或运行中config。修改规则先维护reference JSON并注明具体证据，执行validate后再按需build。新增已确认活动必须同步覆盖比对；未知保持null。
