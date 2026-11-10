# 小新繁体坐骑喂养核查

统一维护启动发条的单次喂养（扣除数量 = 1）与一键喂养（扣除数量 > 1）。原三个项目已完成合并，历史 `archive/` 已删除，当前查询和匹配统一使用本目录的 `scripts/`、`sql/`。

## 当前口径

- 数据源：ThinkingData global `ta.v_event_18`，目标道具 `10213`（启动发条）。保留全用户。
- 消费区间：2026-10-14 00:00:00 至 2026-11-03 00:00:00，不含终点。时间沿用源事件时钟，不依赖运行机器时区。
- 合格消费：`item_change`、`change_source=25`、`type=2`，唯一非空事件 ID、唯一目标道具 payload，`before-after=diff>0`。
- 匹配键：`fc_id + role_id + server_id + before + after`。空身份键不参与匹配，但对应消费保留为待核。
- 时间窗口：**正负 1000 毫秒，包含边界**，按源时间精度比较，不把 1000.001ms 四舍五入成 1000ms。
- 一对一：所有分段、单次与一键记录一起处理。候选按绝对时间差、消费时间、消费 ID、喂养时间、喂养 ID 排序，再依次占用尚未匹配的两侧记录。**每条消费最多匹配一次，每条 `mount_levup` 最多匹配一次。**
- 采用原一键项目的确定性贪心规则，不声称求得最大匹配数。同余额前后值意味着同扣除数量，单次和一键不会借用不同扣除量的喂养记录。
- 喂养明细在消费窗口两端各扩展 1 秒，并将所有文件合并后匹配，覆盖跨午夜及查询分段边界。
- 角色名取整个统计窗口同身份键最早的 `new_role`，不再按下载分段分别找名字。

±1000ms 会减少时间偏移造成的漏配，但仅凭日志关联不能证明业务效果。无匹配表示“当前键及窗口内无对应喂养日志”，统一标为待核。扣 1 / 扣多于 1 是日志数量分类，不是独立认证的客户端按钮标识。

## 目录

```text
scripts/                共用查询生成、抓取、匹配、汇总和测试
sql/                    本轮有界只读 SQL
receipts/               本轮查询回执及输入哈希
outputs/current_20261102/       最终 Excel、角色汇总 CSV、每日汇总 CSV
data/raw/                      六份本轮原始查询明细
verification/current_20261102/  逐事件匹配记录、汇总及 Excel 回读核验
.cache/                        下载副本、匹配数据库、预览图及工作簿中间文件
session/                       浏览器会话，位于项目根目录
node_modules/                  共享依赖的目录链接，位于项目根目录
```

当前结果位于 `outputs/current_20261102/`：

- `role_summary.csv`：一个角色区服一行，同时列出单次、一键的有匹配／无匹配数量与事件数。
- `daily_summary.csv`：按日期、喂养类别统计。
- `小新繁体_坐骑单次与一键喂养核查_20261102_1000ms.xlsx`：合并后的角色名单、每日统计和口径说明。

`verification/current_20261102/event_matches.csv` 保存逐消费关联到唯一喂养 ID 的记录；同目录 `summary.json` 和 `workbook_verification.json` 保存实际结果、来源哈希及核验。选定的三份最终交付文件与脚本、SQL、README、查询回执一同纳入 Git；原始数据、核验明细、其他输出批次、缓存、会话和依赖已在本项目 `.gitignore` 中排除。

当前结果由本轮六个查询的完整事件明细重算，消费共 1,271,385 条。单次有匹配 39,874、无匹配待核 90,251；一键有匹配 909,979 条／27,592,726 个发条，无匹配待核 231,281 条／9,560,054 个发条。两侧最大复用次数均为 1；角色、每日和独立来源控制汇总一致。不能用旧版汇总表推算新窗口结果。

## 运行

在本目录运行，使用同级工作区 `fivecross-data-client/venv/Scripts/python.exe`。查询顺序执行，避免共享客户端冲突。

```powershell
$python = '..\..\..\..\fivecross-data-client\venv\Scripts\python.exe'
& $python scripts/prepare.py
& $python scripts/fetch.py items_part1 items_part2 mounts_part1 mounts_part2 controls registrations
& $python -m unittest discover -s scripts -p test_matching.py -v
& $python scripts/build.py
```

Excel 由 `scripts/build_workbook.mjs` 使用项目根目录 `node_modules` 中的共享依赖生成；随后运行 `scripts/verify_workbook.py` 独立回读全部角色与每日单元格，核对日期、文本 ID、唯一键及数量合计。Excel 位于 `outputs/`，核验记录位于 `verification/`。

若要按新口径单独复算 10 月 30 日 12:30 的截面：

```powershell
& $python scripts/build.py --end '2026-10-30 12:30:00' --label 20261030
```

这使用本轮重新抽取的事件明细，因此是旧时间窗口的新口径重算，不是恢复 10 月 30 日当时的数据快照。两个窗口互相重叠，结果不可相加。默认查询窗口固定至 11 月 2 日，不自动扩展至今天。

## 验证

导出带 `expected_rows`，拒绝截断及触达一百万行上限的结果。匹配前校验 SQL/CSV 哈希、跨分段事件 ID 唯一性、整数消耗及独立每日来源汇总。匹配表对消费、喂养两侧分别加唯一约束，并核验时间差和全部匹配键。角色汇总、每日汇总与事件明细对账。

## 合并状态

10 月 30 日单次、11 月 2 日单次及一键项目已统一为当前一套脚本和完整事件明细，原历史目录由用户删除。仍可用当前明细和上方参数重新计算旧时间窗口。当前工作不包含发奖或生产写入。
