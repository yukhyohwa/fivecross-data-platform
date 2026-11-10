# Jump TC｜大路飞 117 抽卡发放核对

## 当前口径

本项目输出活动时段内**所有实际抽中 117 的记录**，不限制累计抽数，也不要求存在 `hero_add` 记录。

- 游戏版本：Jump Assemble TC OBT
- 卡池：`110`
- 目标卡牌：大路飞 `117`
- 活动窗口：`2026-10-07 05:00:00` 至 `2026-10-07 09:30:00`（含首尾）
- 入选条件：`active_gacha.add_item_id` 包含 `117`
- 输出粒度：每个实际抽中 117 的抽卡事件一行；同一账号多次抽中会有多行
- 抽数仅作为结果字段展示，不参与筛选

完整名单为 `outputs/大路飞117_完整抽中名单_1007_0500至0930.csv`。该名单由 2026-10-08 17:45:10 导出的冻结原始数据构建，包含 220 条命中记录、171 个角色。

`hero_add` 仅用于辅助核对首次获得事件。重复卡通常不会新增角色，因此“未匹配”不能直接解释为发放失败，也不能直接作为补偿名单。

## 目录

```text
sql/01_all_actual_hits.sql
tasks/01_all_actual_hits.json
scripts/build_audit.py
outputs/raw/luffy_all_actual_hits_20261008_174510.csv
outputs/大路飞117_完整抽中名单_1007_0500至0930.csv
outputs/manifest.json
```

## 本地重建

在本项目目录运行：

```powershell
python scripts/build_audit.py
```

也可以指定同结构的完整事件导出与结果路径：

```powershell
python scripts/build_audit.py --events PATH_TO_EVENTS.csv --output PATH_TO_RESULT.csv
```

脚本会从原始事件中重新筛选全部命中记录，校验结果行数与角色集合，并检查已知累计 39 抽的角色 `10517506` 仍在名单中，避免再次误加 40 抽门槛。

## 重新查询

`sql/01_all_actual_hits.sql` 与 `tasks/01_all_actual_hits.json` 都会先从实际抽卡结果动态找出命中 117 的角色，再获取这些角色的抽卡、`hero_add` 与 117 快照。SQL 中没有累计抽数门槛，也没有固定角色名单。

原始文件和结果包含账号标识及角色名，仅应保存在授权的内部环境。
