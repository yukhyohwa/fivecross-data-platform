# Slam Dunk Item Flow Since 2026-08-01

灌篮高手台湾（TC）、全球（GL）、韩国（KR）三个版本的指定道具获得流水查询项目。

## Scope

- 时间范围：2026-07-30 至 2026-08-20（含首尾）
- 道具：
  - `930000002`：集结水晶
  - `930000003`：集结币
- 数据源：ThinkingData / Trino
  - TC：`ta.v_event_20`
  - GL：`ta.v_event_21`
  - KR：`ta.v_event_22`
- 当前口径：道具获得流水（`diff > 0`）
- 输出粒度：玩家角色、区服、道具、发生时间、发生事件

## Output fields

| 字段 | 说明 |
|---|---|
| 地区版本 | TW / GL / KR |
| role_id | 玩家角色 ID |
| zone_id | 区服 ID |
| 获取时间 | 道具获得时间 |
| 发生事件名 | 触发本次道具变化的事件名 |
| 道具ID | 指定道具 ID |
| 获取数量 | 本次获得数量 |
| 点券消耗 | 同一事件事务内消耗的点券 |
| 免费点券消耗 | 同一事件事务内消耗的免费点券 |
| 钻石消耗 | 同一事件事务内消耗的钻石 |

## Project structure

```text
slam_dunk_item_flow_since_20260801/
├── README.md
├── sql/
│   └── sd_item_flow_since_20260801.sql
├── scripts/
│   └── run_query.py
├── tasks/
│   └── sd_item_flow_since_20260801.json
├── docs/
│   └── data_logic.md
└── output/
```

## Run

确保海外数数登录态及环境变量已经配置，然后执行：

```bash
python scripts/run_query.py
```

脚本会调用本地 `fivecross-data-client`，查询结果导出到本项目的 `output/` 目录。

## Caveats

- 当前 SQL 只保留道具获得记录，不包含道具消耗记录。
- `发生事件名` 使用事件表字段 `"$part_event"`。
- 三个版本的 `a_rst` 结构不同，SQL 已按 TC / GL / KR 分支分别解析，不能合并成一套 JSON 解析逻辑。
- 如需“截至某日持有数量”，需要进一步使用资源流水中的 `after_val` 或快照数据，不等同于本项目的获得流水。
