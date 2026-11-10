# FiveCross 游戏与数据源注册表

本表按当前业务确认的项目命名维护。`event_1` 是 `debug` 项目；其中存在死神数据，但不能将其命名为正式死神项目。

## 数数中国

| 项目 | 事件表 |
|---|---|
| Jump Assemble 中国 | `ta.v_event_4` |

## 数数海外

| 项目 | 事件表 |
|---|---|
| debug | `ta.v_event_1` |
| Crayon Shin-chan TW | `ta.v_event_18` |
| Crayon Shin-chan KR | `ta.v_event_24` |
| 乌龙派出所 | `ta.v_event_25` |
| Street Rivals | `ta.v_event_5` |
| Kuroko TW | `ta.v_event_10` |
| Kuroko JP | `ta.v_event_9` |
| Kuroko KR | `ta.v_event_12` |
| Slam Dunk TW | `ta.v_event_20` |
| Slam Dunk GL | `ta.v_event_21` |
| Slam Dunk KR | `ta.v_event_22` |
| Jump Assemble TW | `ta.v_event_23` |
| Saint Seiya TW | `ta.v_event_19` |
| Saint Seiya SEA | `ta.v_event_19` |
| Three Kingdoms | `ta.v_event_19` |
| Captain Tsubasa | `ta.v_event_19` |

`ta.v_event_19` 是共享事件项目，必须按产品 ID 分流：`23000113`、`60000001`、`65002004`、`65002005`。

## 阿里云中国

| App ID | 项目 |
|---:|---|
| `13002008` | 死神2[简] |
| `12000128` | 航海王[简] |
| `10000001` | 圣斗士星矢2[简] |
| `13002010` | 灌篮高手2[简] |
| `13001230` | 敢达决战[简] |
| `15002011` | 圣斗士星矢3[简体] |
| `13002023` | 足球小将[简] |
| `15002003` | 漫画群星：大集结[简] |

## 阿里云海外

| App ID | 项目 |
|---:|---|
| `23000113` | 圣斗士星矢 2 台湾 |
| `23002013` | 灌篮高手台湾 |
| `33002013` | 灌篮高手韩国 |
| `60000001` | 圣斗士星矢 2 东南亚 |
| `63002013` | 灌篮高手全球 |
| `65002004` | 新三国志全球 |
| `65002005` | 队长小翼全球 |
| `65002007` | Jump 早期 MOBA |

## 本地备份

本地备份只指外部 `fivecross-aliyun-backup` 文件目录，不是新的数据库连接。其当前登记项目与 App ID 与“阿里云海外”一致。
