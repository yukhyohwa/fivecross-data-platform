# 小新繁体埋点验收

复核日期：2026-11-10。数据源：`ta.v_event_18`。

事件范围：2026-10-12～2026-11-10。属性及Sample范围：2026-11-04～2026-11-10。

事件时间上界（不含，沿用数仓事件时钟）：2026-11-10 11:27:00。

接收时间上界（不含，沿用数仓接收时钟）：2026-11-10 11:27:00。

身份口径：`#account_id`=角色ID、`fc_id`=账号ID、`#distinct_id`=匿名标识。

- 主清单：154个事件、4692行属性。
- 新增事件：Launch, af_complete_registration, af_login, af_purchase, af_tutorial_completion, click_ads, create_role, first_open, first_purchase, gcsdk_ad_impression, gcsdk_call_login, gcsdk_call_pay, gcsdk_first_open, gcsdk_init_success, gcsdk_login_failed, gcsdk_login_success, gcsdk_pay_failed, gcsdk_pay_init_failed, gcsdk_pay_init_success, gcsdk_pay_success, install, key_event_1_touxian, key_event_2_zhuanzhi, launch, level_02, level_03, level_04, level_05, level_06, level_07, level_08, level_09, level_10, level_20, level_30, level_40, level_50, loading_end, loading_start, package_1, package_2, package_3, reinstall, rr_1, rr_14, rr_3, rr_7。
- 补入属性：3687行，其中8行在本次窗口仅对应事件有非空值。
- 真实Sample：4666行；另26行注明未取得原因。
- 公共表：27项。公共候选仍需确认语义和适用范围。

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

## 新增属性索引

|事件|补入属性数|新增事件|
|---|---:|---|
|gamer_guide|20|否|
|new_role|20|否|
|login|20|否|
|charge|20|否|
|rge|20|否|
|card_levelup|20|否|
|task_reward|20|否|
|Illustrated|20|否|
|task_finish|20|否|
|mail_get|20|否|
|mail_read|20|否|
|prizewheel|20|否|
|friend_delete|20|否|
|friend_apply|20|否|
|friend_add|20|否|
|active_reward|20|否|
|refund_order|20|否|
|toysbox_reward|20|否|
|privilege_reward|20|否|
|battlepass_levelup|20|否|
|battlepass_taskreward|20|否|
|battlepass_reward|20|否|
|questionnaire_reward|20|否|
|equip_dress|20|否|
|line_reward|20|否|
|open_toysbox|20|否|
|toysbox_lottery|20|否|
|toysbox_up|20|否|
|title_up|20|否|
|skill_up|20|否|
|card_Jobchange|20|否|
|shriosaving_fight|20|否|
|shriosaving_reward|20|否|
|mount_get|20|否|
|mount_levup|20|否|
|mount_energy_up|20|否|
|artifact_skin_up_lv|20|否|
|artifact_up|20|否|
|back_up|20|否|
|back_talent|20|否|
|back_skin_unlock|20|否|
|remain_mosaic|20|否|
|remain_find|20|否|
|remain_mosaic_up|20|否|
|ring_up|20|否|
|toy_up|20|否|
|toy_break|19|否|
|toy_cultivate|20|否|
|toy_incubate|20|否|
|movie_get|20|否|
|movie_mosaic|20|否|
|movie_integrate|20|否|
|movie_decompose|20|否|
|martial_up|20|否|
|martial_reward|20|否|
|friend_up|20|否|
|stage_fight|20|否|
|pvp_chapter|20|否|
|library_up|20|否|
|match3_combo|20|否|
|kitchen_scheme_switch|20|否|
|kitchen_slot_unlock|20|否|
|board_tile_land|20|否|
|pet_unlock|20|否|
|pet_upgrade|20|否|
|pet_travel_start|20|否|
|pet_travel_reward|20|否|
|guild_create|20|否|
|guild_join|20|否|
|guild_exit|20|否|
|guild_kickout|20|否|
|guild_apply|20|否|
|guild_job|20|否|
|guild_rabbit_fight|20|否|
|charity_sale_click|20|否|
|charity_sale_purchase|20|否|
|Companion_get|20|否|
|skill_get|20|否|
|shop_buy|20|否|
|shop_reset|20|否|
|item_change|20|否|
|daily_role_snapshot|16|否|
|daily_guild_snapshot|15|否|
|battle_start|20|否|
|card_battlepower|20|否|
|shrine_pray|20|否|
|feature_state|20|否|
|pve_buff|20|否|
|pve_rank_time|20|否|
|pve_milestone_reach|15|否|
|dress_change|20|否|
|ad_play|20|否|
|board_tile_build|20|否|
|online_num|15|否|
|pvp_reward|21|否|
|Launch|41|是|
|af_complete_registration|41|是|
|af_login|42|是|
|af_purchase|44|是|
|af_tutorial_completion|40|是|
|click_ads|42|是|
|create_role|41|是|
|first_open|40|是|
|first_purchase|35|是|
|gcsdk_ad_impression|54|是|
|gcsdk_call_login|42|是|
|gcsdk_call_pay|42|是|
|gcsdk_first_open|22|是|
|gcsdk_init_success|42|是|
|gcsdk_login_failed|35|是|
|gcsdk_login_success|44|是|
|gcsdk_pay_failed|42|是|
|gcsdk_pay_init_failed|42|是|
|gcsdk_pay_init_success|43|是|
|gcsdk_pay_success|43|是|
|install|37|是|
|key_event_1_touxian|37|是|
|key_event_2_zhuanzhi|39|是|
|launch|42|是|
|level_02|27|是|
|level_03|37|是|
|level_04|37|是|
|level_05|37|是|
|level_06|39|是|
|level_07|39|是|
|level_08|37|是|
|level_09|37|是|
|level_10|37|是|
|level_20|39|是|
|level_30|40|是|
|level_40|37|是|
|level_50|22|是|
|loading_end|42|是|
|loading_start|42|是|
|package_1|42|是|
|package_2|41|是|
|package_3|35|是|
|reinstall|19|是|
|rr_1|37|是|
|rr_14|37|是|
|rr_3|37|是|
|rr_7|37|是|

## AppsFlyer 相关项专项复核

截止：2026-11-10，事件时间小于 2026-11-10 11:27:00（数仓时钟）。今天为未结束分区，截止之后或迟到日志不在本次结果内。

- schema 根字段 271 → 315；完整路径 436 → 492。新增根字段 44 个，既有字段类型变化 0 个。
- 事件窗口观察到 151 个精确事件名；相对上次证据新增观察到 47 个事件名。
- 按 af_ 字段、归因/收入/回调字段及 te_ads_object 有值定位到 47 个相关事件、1657 个带值的事件-字段组合。关联归属是实查线索，字段必填性和业务含义仍按接入契约确认。
- 相比上次扫描，首次在对应事件观察到有值的字段路径组合共 2423 项；因时间窗口不同，这不代表其实际上线日期。

### 新观察到的事件

|事件|事件窗口条数|首次分区（本窗口）|最后分区（本窗口）|
|---|---:|---|---|
|Launch|16|2026-11-10|2026-11-10|
|af_complete_registration|24|2026-11-10|2026-11-10|
|af_login|724|2026-11-10|2026-11-10|
|af_purchase|26|2026-11-10|2026-11-10|
|af_tutorial_completion|138|2026-11-10|2026-11-10|
|click_ads|525|2026-11-10|2026-11-10|
|create_role|25|2026-11-10|2026-11-10|
|first_open|24|2026-11-10|2026-11-10|
|first_purchase|2|2026-11-10|2026-11-10|
|gcsdk_ad_impression|514|2026-11-10|2026-11-10|
|gcsdk_call_login|747|2026-11-10|2026-11-10|
|gcsdk_call_pay|49|2026-11-10|2026-11-10|
|gcsdk_first_open|2|2026-11-10|2026-11-10|
|gcsdk_init_success|749|2026-11-10|2026-11-10|
|gcsdk_login_failed|3|2026-11-10|2026-11-10|
|gcsdk_login_success|730|2026-11-10|2026-11-10|
|gcsdk_pay_failed|24|2026-11-10|2026-11-10|
|gcsdk_pay_init_failed|25|2026-11-10|2026-11-10|
|gcsdk_pay_init_success|609|2026-11-10|2026-11-10|
|gcsdk_pay_success|25|2026-11-10|2026-11-10|
|install|26|2026-11-10|2026-11-10|
|key_event_1_touxian|15|2026-11-10|2026-11-10|
|key_event_2_zhuanzhi|9|2026-11-10|2026-11-10|
|launch|785|2026-11-10|2026-11-10|
|level_02|16|2026-11-10|2026-11-10|
|level_03|15|2026-11-10|2026-11-10|
|level_04|14|2026-11-10|2026-11-10|
|level_05|12|2026-11-10|2026-11-10|
|level_06|15|2026-11-10|2026-11-10|
|level_07|17|2026-11-10|2026-11-10|
|level_08|15|2026-11-10|2026-11-10|
|level_09|15|2026-11-10|2026-11-10|
|level_10|15|2026-11-10|2026-11-10|
|level_20|14|2026-11-10|2026-11-10|
|level_30|13|2026-11-10|2026-11-10|
|level_40|4|2026-11-10|2026-11-10|
|level_50|1|2026-11-10|2026-11-10|
|loading_end|731|2026-11-10|2026-11-10|
|loading_start|777|2026-11-10|2026-11-10|
|package_1|12|2026-11-10|2026-11-10|
|package_2|10|2026-11-10|2026-11-10|
|package_3|3|2026-11-10|2026-11-10|
|reinstall|1|2026-11-10|2026-11-10|
|rr_1|162|2026-11-10|2026-11-10|
|rr_14|38|2026-11-10|2026-11-10|
|rr_3|79|2026-11-10|2026-11-10|
|rr_7|90|2026-11-10|2026-11-10|

### AppsFlyer 相关事件覆盖

|事件|属性窗口事件数|相关带值字段数|部分缺值字段数|
|---|---:|---:|---:|
|Launch|16|38|18|
|af_complete_registration|24|37|17|
|af_login|724|39|19|
|af_purchase|26|41|20|
|af_tutorial_completion|138|37|17|
|click_ads|525|39|19|
|create_role|25|37|17|
|first_open|24|37|17|
|first_purchase|2|34|0|
|gcsdk_ad_impression|514|44|19|
|gcsdk_call_login|747|39|19|
|gcsdk_call_pay|49|39|19|
|gcsdk_first_open|2|20|0|
|gcsdk_init_success|749|39|19|
|gcsdk_login_failed|3|33|14|
|gcsdk_login_success|730|39|19|
|gcsdk_pay_failed|24|39|20|
|gcsdk_pay_init_failed|25|38|18|
|gcsdk_pay_init_success|609|39|19|
|gcsdk_pay_success|25|39|19|
|install|26|34|17|
|key_event_1_touxian|15|34|14|
|key_event_2_zhuanzhi|9|37|17|
|launch|785|39|19|
|level_02|16|24|4|
|level_03|15|34|14|
|level_04|14|34|14|
|level_05|12|34|14|
|level_06|15|36|16|
|level_07|17|36|16|
|level_08|15|34|14|
|level_09|15|34|14|
|level_10|15|34|14|
|level_20|14|36|16|
|level_30|13|37|17|
|level_40|4|35|15|
|level_50|1|20|0|
|loading_end|731|39|19|
|loading_start|777|39|19|
|package_1|12|39|19|
|package_2|10|38|18|
|package_3|3|34|0|
|reinstall|1|17|0|
|rr_1|162|33|17|
|rr_14|38|33|18|
|rr_3|79|33|18|
|rr_7|90|33|18|

部分缺值表示观测覆盖不足100%，并不等于违反必填要求；各回调场景可能不同。逐事件字段类型、分子/分母与样本见 appsflyer_field_coverage.csv，全部事件和漏列字段已合入 tracking_review.xlsx。

### 原文档问题统计

- 事件窗口未观测：3 个原文档事件。
- 数仓缺字段/子字段：3 行；对应事件全空：4 行；有值字段类型差异：0 行。以上包含原标暂不需要项，不全部构成强制整改。

### 一致性检查

四份正式查询证据已绑定当前源文档哈希、表、查询窗口及事件时间上界。属性统计与全字段扫描的逐事件事件数一致，字段覆盖分子未超过分母，有值字段均有对应事件样本，结果未触及1000事件查询上限。复核表逐样本与查询结果比对、发现路径归属和原文档保留检查通过。

AppsFlyer 转发配置、归因正确性、事件触发时机、真实支付金额、同笔业务是否重复上报仍需接入配置和操作级证据，不能仅由结构及聚合验收判定通过。

### 新增根字段

`#data_source_detail`, `ad_platform`, `af_ad`, `af_ad_id`, `af_ad_type`, `af_adset`, `af_adset_id`, `af_c_id`, `af_channel`, `af_cost_currency`, `af_currency`, `af_prt`, `af_quantity`, `af_revenue`, `af_siteid`, `api_version`, `app_id`, `app_name`, `app_version`, `attributed_touch_time`, `attributed_touch_type`, `bundle_id`, `campaign`, `ecpm`, `event_name`, `event_revenue`, `event_revenue_currency`, `event_revenue_usd`, `event_source`, `event_time`, `event_value`, `gc_login_err`, `gc_login_type`, `gc_pay_init_err`, `gc_pay_init_type`, `gc_uuid`, `install_time`, `is_retargeting`, `media_source`, `sdk_version`, `te_ads_object`, `user_id`, `value_d`, `value_s`

### 命名与重复定义

- 线上大小写并存事件组：[["Launch", "launch"]]。保留精确事件名，需确认是否来自不同接入或应统一。
- 原文档同事件重复字段：{"charge": ["store_type"]}。
- 原事件名空格或说明混入：[{"event": "card_levelup", "source_row": 150, "raw_event": "card_levelup "}]。

### AppsFlyer 时钟口径差异

同条日志配对检查 7885 条 AppsFlyer 回调，其中 7885 条的接收时间减事件时间落在 28740～28860 秒（8小时上下60秒）。这提示两个时间字段存在时钟口径差异，不能直接把差值都解释为传输延迟。

|事件|同条日志的事件时间、接收时间、来源样本|
|---|---|
|af_login|`{"event_time":"2026-11-10 02:52:10.435","receipt_time":"2026-11-10 10:52:12.248","event_source":"SDK"}`|
|af_purchase|`{"event_time":"2026-11-10 02:57:54.807","receipt_time":"2026-11-10 10:58:12.583","event_source":"S2S"}`|
|gcsdk_pay_success|`{"event_time":"2026-11-10 03:13:47.056","receipt_time":"2026-11-10 11:13:50.043","event_source":"SDK"}`|
|install|`{"event_time":"2026-11-10 02:51:51.568","receipt_time":"2026-11-10 10:52:26.699","event_source":"SDK"}`|

建议确认 AppsFlyer 接入的时区转换与数数映射。在统一时钟前，跨来源按自然日统计、留存和延迟指标均可能受影响。本轮同时使用事件时间和接收时间排他上界，均为 2026-11-10 11:27:00（各自数仓时钟）；不是将两者视为同一时区。接收时间为 NULL 的记录不在此快照内。
#data_source_detail 仅用于确认来源，作为采集元数据排除出游戏业务属性表。

### charge 已有业务规则的全窗口检查

检查 7217 条 charge：shop 不在 1/2（含空）246 条，三类身份均缺失 0 条。
当前原表把 shop 写作“折扣”，说明示例为 95、80、100，而 validation.tc.json 要求 shop 只能为 1/2。两份定义存在冲突，因此上述数量仅表示不匹配现有规则，不直接判为业务实现错误。
项目 validation.tc.json 另要求 discount > 0，但当前 schema 缺少 discount，无法执行正数检查。需先确认 shop/discount 最新定义，再决定补报还是更新规则；未将缺字段当成通过。此检查不证明金额或重复支付正确。

### 收入与回调载荷类型

收入、币种和 event_value 按实际数仓类型记录，varchar 中的 JSON 不当作原生对象。event_value 为 `{}` 时仅表示字符串已上报，不等于存在业务载荷；是否要求各事件携带特定键需以 AppsFlyer 接入契约确认。

### 输入版本与历史保留

本次输入本身已有上一轮 Sample 和复核列。通过项目内布局适配副本生成新表，原输入文件保持原字节；适配前后逐单元格映射核对，并保留原有所有页签。最终 I/J/O 为本次实际类型、Sample 和复核，AC/AD 为原输入的历史 Sample/复核，原说明、程序反馈与5X验收分别保留在 K/M/N。原输入、适配副本与适配脚本哈希保存在证据 manifest 的 document_adapter 中。
