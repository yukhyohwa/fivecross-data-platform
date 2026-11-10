# 小新KR埋点验收

复核日期：2026-11-06。数据源：`ta.v_event_24`。

事件范围：2026-10-08～2026-11-06。属性及Sample范围：2026-10-31～2026-11-06。

事件时间上界（不含，沿用数仓事件时钟）：2026-11-06 11:30:00。

身份口径：`#account_id`=角色ID、`fc_id`=账号ID、`#distinct_id`=匿名标识。

- 主清单：107个事件、1049行属性。
- 新增事件：无。
- 补入属性：44行，其中0行在本次窗口仅对应事件有非空值。
- 真实Sample：549行；另500行注明未取得原因。
- 公共表：46项。公共候选仍需确认语义和适用范围。

## 阅读方式

I列为实际属性类型，J列为对应事件的非空Sample，L列为字段状态，O列为事件复核结论。
公共属性重复行的“可删除”针对事件内重复定义，不代表可以停止上报公共层数据。

## 证据与限制

证据保存在配置指定的 evidence 目录：SQL、CSV、schema、字段映射、验收计划和验证摘要。
Sample按属性独立取样，不表示同一条日志；0与false为有效值。长JSON可在公式栏查看全文。
没有事件仅代表当前窗口未观测。字段存在且有Sample不证明触发、金额、流水算术或重复上报正确。

## 原文档字段类型差异

|事件|字段|文档类型|实际类型|
|---|---|---|---|
|game_ad_impression|config_id|数值|varchar|

## 新增属性索引

|事件|补入属性数|新增事件|
|---|---:|---|
|gamer_guide|1|否|
|new_role|1|否|
|login|1|否|
|card_levelup|1|否|
|task_reward|1|否|
|Illustrated|1|否|
|task_finish|1|否|
|mail_get|1|否|
|mail_read|1|否|
|prizewheel|1|否|
|toysbox_reward|1|否|
|privilege_reward|1|否|
|battlepass_levelup|1|否|
|battlepass_taskreward|1|否|
|battlepass_reward|1|否|
|equip_dress|1|否|
|line_reward|1|否|
|open_toysbox|1|否|
|toysbox_up|1|否|
|title_up|1|否|
|skill_up|1|否|
|card_Jobchange|1|否|
|shriosaving_fight|1|否|
|shriosaving_reward|1|否|
|friend_up|1|否|
|stage_fight|1|否|
|pvp_chapter|1|否|
|library_up|1|否|
|match3_combo|1|否|
|guild_join|1|否|
|guild_apply|1|否|
|guild_rabbit_fight|1|否|
|charity_sale_click|1|否|
|Companion_get|1|否|
|skill_get|1|否|
|shop_buy|1|否|
|shop_reset|1|否|
|item_change|1|否|
|battle_start|1|否|
|card_battlepower|1|否|
|feature_state|1|否|
|dress_change|1|否|
|ad_play|1|否|
|pvp_reward|1|否|

## KR 补充核验

- 原文档107个事件；30日观测70个，未观测37个。
- 已观测事件中的文档属性：缺列/子字段11行，全空35行，类型不符1行。
- 字段聚合和发现聚合使用同一事件时间上界，逐事件条数一致；11月6日是部分日，非数据库事务快照。
- KR输入副本由当前原表投影，移除繁体服历史Sample与复核结论，保留类型主名及源文档反馈；原始文件未改动。原表其他页签保留，主要逐行验收范围为事件数据与公共事件属性。
- “√”仅指该字段在指定窗口存在且类型一致，缺值提示仍保留，不代表触发时机或业务数值已通过。

### 未观测事件

`ta_app_crash`, `charge`, `rge`, `friend_delete`, `friend_apply`, `friend_add`, `active_reward`, `refund_order`, `questionnaire_reward`, `toysbox_lottery`, `speed_up`, `lamp_lev`, `card_awken`, `mount_energy_up`, `remain_mosaic_up`, `ring_up`, `movie_get`, `movie_mosaic`, `movie_integrate`, `movie_decompose`, `martial_up`, `martial_reward`, `kitchen_scheme_switch`, `pet_unlock`, `pet_upgrade`, `pet_travel_start`, `pet_travel_reward`, `guild_exit`, `guild_kickout`, `guild_job`, `charity_sale_purchase`, `pve_buff`, `pve_rank_time`, `pve_milestone_reach`, `dress_preview`, `toysbox_theme_change`, `limited_draw_prompt`

### 缺少的字段/子字段

|事件|字段|
|---|---|
|ta_app_start|#background_duration|
|ta_app_start|#start_reason|
|ta_app_start|#title|
|ta_app_end|#title|
|login|bundleId|
|open_toysbox|themes|
|daily_role_snapshot|mainstage|
|daily_role_snapshot|martial.skill_list|
|daily_role_snapshot|privilege_info.10001|
|daily_role_snapshot|privilege_info.1003|
|dress_change|dress_pos|

### charge 专项

近30日没有charge；历史8条仅为JP/JPY沙盒日志，schema无shop字段，无法验证三个枚举映射。完整结论见 [charge专项](charge_shop_currency.md)。
