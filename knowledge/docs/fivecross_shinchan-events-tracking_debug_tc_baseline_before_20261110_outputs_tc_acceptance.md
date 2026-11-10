# 小新漏列事件、属性和Sample复核更新（2026-11-05）

本轮基于当前全部271个数仓根字段，递归展开为436个字段路径，按事件对2026-10-29～11-04的实际日志做非空覆盖和Sample聚合。原文件不覆盖，结果仍写入同一复核版。

- 主清单现有 **111个事件、1101行字段定义**。补入原文档未列的4个事件：`ad_play`、`board_tile_build`、`online_num`、`pvp_reward`。
- 原有事件补369行漏列属性，新事件补15行属性，合计384行；其中155行属性在本次104个实有事件中仅对应事件有非空值，标为“事件特有属性”。这表示当前实查覆盖，不声称未来或历史永远专属。
- 6个原先完全没有属性定义的事件，直接从原事件首行填入第一个属性，其余属性接在该事件下面，避免保留“未定义业务属性”的过期提示。实际插入378行。
- J列为“非空Sample”，I列实际类型保留，原属性说明顺移到K列、状态到L列、程序反馈到M列、5X验收到N列、复核状态到O列。
- 1101行字段中，991行有对应事件真实非空Sample，110行明确写了“没有事件”“没有属性”或“无非空Sample”。不使用其他事件样本代填，也不把0/false当空。
- 公共表现有47项，补入6项SDK公共定义及20项“公共属性候选”，并加G列实际类型、H列Sample、I列状态和Sample来源事件。公共候选须确认业务口径后才能作为公共层要求，不能因跨事件有值就直接判定为已确认公共属性。

## 分类与Sample口径

原有公共属性和明确SDK公共字段保留公共归属。`level`、`lid`、`role_id`等实查在至少90%非SDK业务事件有值的字段集中列为公共候选；其中`msg`、`topics`、`time`、`time_server`等也可能来自通用日志/采集链路，需要确认归属，不要求按游戏业务属性强制补报。其余有非空值的业务属性及SDK事件专属属性，补入所属事件。对象/对象组中漏列的子字段也逐行补齐。

每个Sample从对应事件、对应属性独立取一条非NULL且非空字符串/非空数组的实际值。不同属性的Sample可能来自不同日志，不代表同一条操作。复杂属性保留完整JSON文本；较长内容可在公式栏查看全文，单元格内显示高度有限。

数仓内部流水字段（如`#uuid`、`#kafka_offset`、`#dw_create_time`、`#te_event_id`、`#data_source`等）未混入游戏业务属性。小新身份口径继续保持 `#account_id=角色ID`、`fc_id=账号ID`，`role_id`等新发现字段仅作为候选，未改写其历史语义。

## 本轮证据

- `../data/evidence/tc/discovery.sql` / `.csv`：104个实有事件的436个路径覆盖与Sample，窗口2026-10-29～11-04。
- `../data/evidence/tc/discovery_map.json`：`n编号`是非空内容的事件行数，`s编号`是对应真实Sample；复杂字段在聚合后转JSON，子字段从实际对象结构中取值。
- `../data/evidence/tc/discovered_attributes.csv`：384行新增属性及所属事件、类型、覆盖事件数、填充数量、Sample。
- `../data/evidence/tc/discovery_validation.json`：已核对所有Sample与查询结果一致、全部观察到的业务路径均有归属、原数据和验收反馈保留、合并区域不重叠。

下方保留前一轮类型与缺失检查说明，字段列位置已同步更新。前一轮717行的统计为补充前范围，不等于本轮1101行范围。

---

# 小新逐字段实查验收（2026-11-05）

本版通过 `thinkingdata-events-validation` 的统一执行层复用现有 `fivecross-data-client` 连接数数，查询小新繁体 `ta.v_event_18`，替代上一版仅文档复核的结论。小新项目只保留配置、规则和验收产出，不维护连接及session实现。

## 表格如何看

- H列保留原“属性类型（必填）”，在其后插入I列“实际属性类型（数数实查）”。I列逐字段显示实际数仓类型，或“没有事件”“没有属性”。
- L列“状态”直接写逐字段验收结论。公共属性与事件内重复定义的行，明确写“公共事件属性，可删除”；可删除的是文档中的事件专属重复定义，不能停传公共层的数据。
- O列“复核状态”写每个事件的实际条数、没有属性的清单、类型错误清单，以及缺失/部分缺值的公共属性。有值数量按行统计，零是有效数值，不作为缺失。
- 原始文件不覆盖。原属性说明、程序反馈和5X验收记录保留；本版L列替换为本次字段结论。原“暂不需要”的字段在新状态中保留该范围提示。

## 查询范围与含义

事件存在性窗口：2026-10-06～2026-11-04，共30个完整分区日。字段填充情况窗口：2026-10-29～2026-11-04，共7个完整分区日。类型来自2026-11-05实际查询的数仓schema。

“没有事件”表示30日窗口中没有该精确名称的上报，不证明历史从未上报或没有开发。“没有属性（数仓无字段/子字段）”表示当前schema未定义。“没有属性（本事件全空）”表示该字段虽然在共享事件表存在，但本事件近7日未观测到有效值。

数组非空与子字段值单独统计。嵌套字段通过真实 array(row)/row 结构逐层解析并查询，未沿用旧脚本忽略嵌套字段的处理。字段计数为“多少条事件带有值”，不等于嵌套元素个数；部分元素缺值还需另外逐元素验收。空数组可表示无资源变化，不自动判为业务错误。

实际类型是数仓SQL类型，不声称是SDK上传前的原始JSON类型。例如数值统一入double可以正常；varchar中的内容即便是JSON，数仓类型仍是字符串。完整原生类型见 `../data/evidence/tc/actual_schema.csv`，包括对象组各子字段的结构。

公共属性缺值按小新自己的公共表列出，同时参考乌龙表检查客户端SDK环境属性。安装/未登录事件、服务器/公会事件等有不同适用范围，O列实查缺值并不等同所有字段在这些场景都应强制必填。小新身份口径始终为 `#account_id=角色ID`、`fc_id=账号ID`，未要求迁移。

## 实查结果

- 已检查107个事件块、717个字段定义行（含重复定义和原标暂不需要的字段）。
- 30日未观测到的清单项：7个，即 credit_buy,chat,speed_up,lamp_lev,card_awken,martial_break,limited_get  已经记录在 active_reward。最后一项在事件名中混入说明，应按原备注合并到active_reward。
- 有近7日事件样本的字段中，数仓无字段/子字段19行，本事件全空34行，文档类型与有值字段数仓类型不一致24行。这些计数包含原标暂不需要项，不是强制整改数量。
- `refund_order` 30日有639条，近7日有103条；并非没有事件。`cfg_id`没有字段，`product_id`在退款事件中近7日全空，二者原表均标暂不需要。
- 当前日志还包含主清单未列的事件：ad_play,board_tile_build,online_num,pvp_reward。

## 明确的字段类型差异

|事件|字段|文档类型|实际数仓类型|
|---|---|---|---|
|new_role|fcsdk_info|对象组|varchar|
|login|fcsdk_info|对象组|varchar|
|charge|fcsdk_info|对象组|varchar|
|open_toysbox|times|数组|double|
|title_up|title|列表|double|
|toy_cultivate|elder2|对象组|row(id double, "level" double, name varchar, quality double, unique_id double)|
|toy_incubate|son_toy|对象组|array(varchar)|
|pvp_chapter|attr_info|对象组|array(varchar)|
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

## 可复查证据

- `../data/evidence/tc/actual_schema.sql` / `.csv`：当前271个数仓列及完整类型。
- `../data/evidence/tc/actual_inventory.sql` / `.csv`：30日所有事件实际条数与首末分区。
- `../data/evidence/tc/actual_fields.sql` / `.csv`：7日按事件分组的字段存在/非空计数，包含嵌套字段。
- `../data/evidence/tc/actual_field_map.json`：SQL中n编号表示非NULL的事件行数，v编号表示非空内容行数；无v编号的字段与n相同。
- `../data/evidence/tc/field_acceptance.csv`：逐字段结论、文档类型、原生数仓类型和分子分母。

本次验证覆盖事件存在性、实际存储类型和字段填充情况；触发是否符合业务、同次操作是否重复上报、金额是否正确及流水算术需要操作级测试，不能仅由这些聚合结果证明通过。
