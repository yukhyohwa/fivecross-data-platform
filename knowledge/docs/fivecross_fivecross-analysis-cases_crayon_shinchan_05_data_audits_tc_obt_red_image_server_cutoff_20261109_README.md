# 小新繁中 OBT 红色影像分服截止流水

按服务器批次规定的截止日期，查询角色的 `shop_buy` 和 `active_reward` 红色影像道具流水。2026-11-09 版本保留原 1001–1052 服，追加图中第9天的 1053–1058 服。最终 Excel 位于 `outputs/小新繁中_红色影像分服截止流水_20261109.xlsx`。

## 服务器与截止时间

以下日期均为当天 **00:00:00，不含该时刻**，不延伸到当天晚上，也不根据当前日期重新计算。

| 服务器 | 截止日期 | 原图口径 |
| --- | --- | --- |
| 1001–1019 | 2026-10-25 | 第12天 |
| 1020–1027 | 2026-10-26 | 第12天 |
| 1028–1034 | 2026-10-27 | 第12天 |
| 1035–1040 | 2026-10-28 | 第12天 |
| 1041–1045 | 2026-10-29 | 第12天 |
| 1046–1047 | 2026-10-30 | 第12天 |
| 1048–1049 | 2026-10-31 | 第12天 |
| 1050 | 2026-11-01 | 第12天 |
| 1051–1052 | 2026-11-02 | 第12天 |
| 1053–1054 | 2026-10-31 | 新增，第9天 |
| 1055–1056 | 2026-11-01 | 新增，第9天 |
| 1057 | 2026-11-02 | 新增，第9天 |
| 1058 | 2026-11-03 | 新增，第9天 |

## 数据与统计口径

- 事件表：繁体 App18 `ta.v_event_18`；道具名称维表：`ta_dim.dim_18_0_52781`。不使用 `item_change`。
- 角色标识取 `#account_id`。角色创建名、服务器 ID 取该角色首次 `new_role`；事件 `fc_id` 缺失时回退创角记录。创角关联每个角色只保留一行，不放大事件条数。
- 服务器原始字段存在 `1001.0` 形式，先从原始数值转换为 BIGINT 再转文本，不能先转文本再直接转 BIGINT。
- `shop_buy` 展开 `shop_item`，以 `item_id` 过滤，以 `num` 统计数量。该结构通常是支付／消耗项，不能直接解释为买到的红色影像。
- `active_reward` 展开 `a_rst`，以 `id` 过滤，数量优先取 `diff`，缺失时取 `after-before`。
- 两个事件都在展开分支的 `WHERE` 中仅保留下面20个ID，不再输出其他道具或“是否红色影像”列。不额外限制正负数量，不增加黑名单过滤。
- ID：110033–110048、120019、120020、170001、170002。
- 结果按角色、创建名、fc_id、服务器、道具ID／名称、事件、截止时间汇总。包含道具明细条数、原始事件道具数量、缺数量条数、最早时间和最后时间。
- 道具明细条数是数组展开条数，不是去重订单数；两类事件数量不可直接相加解释为获得数。任一条数量缺失时该组数量留空，不静默按零计算。
- 最早／最后时间按事件原始时间比较，不额外做时区偏移。缺少有效创角记录或不属于指定服务器的事件不输出；无符合记录的服务器不补零。

## 文件与复跑

| 文件 | 用途 |
| --- | --- |
| sql/01_items.sql | 本 case 实际执行的完整 SQL，内含13批截止时间 |
| fetch.py | 独立取数入口，串行调用现有 fivecross-data-client，核验新导出文件并保存雜湊 |
| config.json | 外部 data client 路径，不含凭证 |
| prepare_excel.py | 检查来源雜湊、道具ID、去重粒度、各服截止时间，生成工作簿输入 |
| workbook.mjs | 使用共享 artifact-tool 生成可筛选 Excel 和预览 |
| validate_excel.py | 只读回读 Excel，逐格核对数据、时间格式、截止表和筛选表 |
| outputs/ | 最新正式 Excel |

在本文件夹依次运行：

```powershell
$env:PYTHONIOENCODING='utf-8'
$env:PYTHONDONTWRITEBYTECODE='1'
$casePython='C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe'
& $casePython fetch.py 01_items
& $casePython prepare_excel.py
node workbook.mjs
& $casePython validate_excel.py
```

Python 需 pandas 和 openpyxl（只用于读回核验）。Node 需共享 `@oai/artifact-tool`；可将本文件夹的 `node_modules` 建为指向 Codex 共享依赖的 Windows junction，不复制依赖包。数据库凭证继续由外部 data client 管理，不写入本 case。

`data/raw/` 保存本次 SQL 快照、原始 CSV、抓取元数据和日志，包含玩家ID，不提交 Git。`build/` 保存输入 JSON、来源核验、Excel核验和预览，属于可重建中间文件，也不提交 Git。最终 Excel 包含此次需求明确要求的角色ID、名称和 fc_id，应仅提供给有权限的业务人员。

SQL 库同步文件：`fivecross-sql-lib/games/crayon_shinchan/trino/cs_act/cs_tc_act_red_image_shop_reward_server_cutoff_obt.sql`。修改截止表后需同步此处 `sql/01_items.sql`；工作簿截止说明会从实际执行 SQL 自动生成。
