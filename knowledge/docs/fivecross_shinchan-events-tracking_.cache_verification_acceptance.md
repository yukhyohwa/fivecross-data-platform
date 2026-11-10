# 小新繁体埋点验收

复核日期：2026-11-05。数据源：`ta.v_event_18`。

事件范围：2026-10-06～2026-11-04。属性及Sample范围：2026-10-29～2026-11-04。

身份口径：`#account_id`=角色ID、`fc_id`=账号ID、`#distinct_id`=匿名标识。

- 主清单：111个事件、1101行属性。
- 新增事件：ad_play, board_tile_build, online_num, pvp_reward。
- 补入属性：384行，其中155行在本次窗口仅对应事件有非空值。
- 真实Sample：991行；另110行注明未取得原因。
- 公共表：47项。公共候选仍需确认语义和适用范围。

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
|new_role|fcsdk_info|对象组|varchar|
|login|fcsdk_info|对象组|varchar|
|charge|fcsdk_info|对象组|varchar|
|open_toysbox|times|数组|double|
|title_up|title|列表|double|
|toy_cultivate|elder2|对象组|row(id double, "level" double, name varchar, quality double, unique_id double)|
|toy_incubate|son_toy|对象组|array(varchar)|
|board_tile_land|type_shijian|字符串|double|
|game_ad_impression|value|数值|varchar|
|game_ad_impression|config_id|字符串|double|
|game_ad_impression|config_name|数值|varchar|
|daily_role_snapshot|job|字符串|double|
|daily_role_snapshot|title|列表|double|
|daily_role_snapshot|mount|对象组|row(exp double, "level" double, skinlist varchar, talentlist varchar, "use" double)|
|daily_role_snapshot|artifact|对象组|row(exp double, gem_list array(varchar), "level" double, pos_gem_map varchar, pos_gem_name varchar, role_id double, skin_list array(varchar), "use" double)|
|daily_role_snapshot|back|对象组|row(collectionlist array(varchar), feathers array(varchar))|
|daily_role_snapshot|back_talent|对象组|row(good_use varchar, wing_map varchar, wing_name varchar, wing_talent_skill_num varchar)|
|daily_role_snapshot|back_skin|对象组|row(skinlist varchar, "use" double)|
|daily_role_snapshot|first_pay_time|字符串|timestamp(3)|
|daily_role_snapshot|last_pay_time|字符串|timestamp(3)|
|daily_guild_snapshot|guild_user|对象组|array(varchar)|
|pve_buff|pve_buff|列表|row("1020" array(varchar), "1002" array(varchar), "1028" array(varchar), "1035" array(varchar))|
|pve_rank_time|rank_time|数值|timestamp(3)|
|pve_milestone_reach|rank_time|数值|timestamp(3)|

## 新增属性索引

|事件|补入属性数|新增事件|
|---|---:|---|
|ta_app_start|14|否|
|ta_app_end|18|否|
|ta_app_install|14|否|
|ta_app_crash|15|否|
|gamer_guide|15|否|
|game_movie|14|否|
|new_role|1|否|
|login|8|否|
|charge|1|否|
|questionnaire_reward|3|否|
|equip_dress|3|否|
|open_toysbox|6|否|
|skill_up|3|否|
|shriosaving_fight|14|否|
|mount_get|1|否|
|artifact_up|7|否|
|back_up|1|否|
|remain_find|7|否|
|toy_break|5|否|
|toy_cultivate|5|否|
|toy_incubate|5|否|
|movie_integrate|3|否|
|movie_decompose|7|否|
|friend_up|6|否|
|stage_fight|1|否|
|pvp_chapter|6|否|
|board_tile_land|1|否|
|game_ad_impression|14|否|
|item_change|4|否|
|daily_role_snapshot|94|否|
|battle_start|7|否|
|card_battlepower|1|否|
|shrine_pray|19|否|
|pve_buff|4|否|
|dress_preview|14|否|
|toysbox_theme_change|14|否|
|limited_draw_prompt|14|否|
|ad_play|2|是|
|board_tile_build|9|是|
|online_num|2|是|
|pvp_reward|2|是|
