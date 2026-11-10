# Jump TC — 特南克斯 D1–D3 商业与竞技表现（加入香吉士）

## 范围与交付

本版固定特南克斯 **2026-09-23—2026-09-25**，不延长统计期。商业比较为七期活动各自上线后的三个完整自然日：五条悟首发、佩恩、波风凑、朽木白哉、五条悟复刻、香吉士、特南克斯。五条悟首发与复刻保留两行，不按相同卡牌ID合并。

- `outputs/Jump_TC_特南克斯_D1-D3商业与竞技表现_20260923-20260925_含香吉士.pptx`：10页，商业对比页1、2、4均为七期活动，更新七期排名和结论。
- 同名 `.xlsx`：原结果表之外补充七期每日指标、七期累计付费分层、七期商业排名，保留明确日期、分母与收入定义。
- `outputs/verification_20260925_sanji.json`：构建输入、SHA256、结果排名。
- `outputs/validation_20260925_sanji.json`：独立SQL覆盖核对、PPT/XLSX读回核对、输出SHA256。
- `outputs/outline_20260925_sanji.json`：10页实际文字和表格。
- `outputs/render_sanji/`：Microsoft PowerPoint实机导出的10页PNG及拼图 `contact.png`；已检查全部页面，无明显重叠或截断。

旧D1报告及旧六期D1–D3报告保留，不覆盖。本次未提交或推送Git，也未改动周报配置、定时器或香吉士历史案例。

## 来源、活动映射与数据批次

源：ThinkingData Global / Trino `ta.v_event_23`；通过现有 `fivecross-data-client/venv` 和TA客户端运行。活动来源：`C:/Users/5xgames/Desktop/github/jumptw-weekly-report/config/report.yaml` 中的关键事件表。

| 活动 | 比较窗口 | 卡牌ID | 卡池ID |
|---|---|---:|---:|
| 五条悟首发 | 2026-06-24—2026-06-26 | 145 | 101 |
| 佩恩 | 2026-07-15—2026-07-17 | 144 | 102 |
| 波风凑 | 2026-08-12—2026-08-14 | 126 | 104 |
| 朽木白哉 | 2026-08-26—2026-08-28 | 164 | 105 |
| 五条悟复刻 | 2026-09-02—2026-09-04 | 145 | 106 |
| 香吉士 | 2026-09-09—2026-09-11 | 119 | 107 |
| 特南克斯 | 2026-09-23—2026-09-25 | 163 | 108 |

香吉士事件表标记为S级、首发，整期活动为9月9日至10月7日；本报告只取其9月9–11日。**没有将旧香吉士D1–D5导出当作D1–D3使用。**

2026-09-29重新执行商业SQL 01–03，全部七期统一D1–D3。日指标21行，累计付费分层42行，最后快照7行。另运行 `05_matched_coverage.sql` 独立核验：21个日窗口与7个三日窗口，活跃玩家、参与玩家、抽数均逐行与主查询一致。

本次新导出：
- `inputs/raw/01_jump_tc_trunks_01_20260925_sanji_20260929_104629.csv`
- `inputs/raw/02_jump_tc_trunks_02_20260925_sanji_20260929_104643.csv`
- `inputs/raw/03_jump_tc_trunks_03_20260925_sanji_20260929_104702.csv`
- `inputs/raw/05_jump_tc_trunks_05_20260925_sanji_20260929_104917.csv`

竞技SQL与时间不变，沿用 `inputs/raw/04_jump_tc_trunks_04_20260925_20260926_081838.csv`，未宣称本次重新查询。已断言新旧工作簿的竞技表及玩法名称来源逐单元格完全一致。商业新导出与9月26日旧导出略有变化，不能混用旧业务数字；变化原因未单独归因。

## 主要发现（全部由新查询计算）

| 指标 | 香吉士 D1–D3 | 特南克斯 D1–D3 |
|---|---:|---:|
| 窗口去重活跃玩家 | 10,946 | 10,247 |
| 窗口去重参与玩家 | 1,117 | 1,879 |
| 参与率 | 10.2% | 18.3% |
| 目标池抽数 | 38,491 | 77,533 |
| 参与玩家人均抽取 | 34.5 | 41.3 |
| 最后可用快照持有玩家 | 413 | 803 |
| 持有率（活跃分母） | 3.8% | 7.8% |
| 至少三觉玩家 | 157 | 274 |
| 三觉完成率（持有分母） | 38.0% | 34.1% |

- 香吉士人均抽取为七期第2，参与率及抽数均第7；特南克斯人均抽取第1，参与率第5、抽数第4。
- 加入香吉士后，三觉完成率最高为香吉士38.0%，特南克斯34.1%排第2；这不等于香吉士整体持有覆盖更高。
- 特南克斯日活为6,359 / 6,941 / 7,822，日参与玩家739 / 925 / 1,046，日抽数39,437 / 19,721 / 18,154。窗口抽数与每日抽数相加口径不同，不能断言二者相等。

## 指标定义及限制

- 账户：`COALESCE(fc_sdk_common.lcx_id,sdkcommon.lcx_id,#account_id)`；排除 `internal_users / is_water / is_water_mod / suspicious_ip`。
- 窗口活跃为三日内至少登录一次的去重账户；参与为该人群在同一窗口的对应卡池参与账户；窗口抽数包含其窗口内未登录日的抽卡。每日指标只与当日登录账户相交。三日独立人数不等于日独立人数之和。
- 历史累计有效充值分层截止各期D3；PURCHASE排除沙盒，扣除匹配的免费钱包金额，再按日汇率折算USD，继承案例已验证逻辑。
- 收入是各日活跃账户的全游戏有效购买收入，不是卡池归因收入；每日付费人数之和是人次，不是窗口去重付费人数。
- 持有/养成取各期D1–D3最后可用 `daily_role_card_snapshot`，不是保证D3日末同一时刻扫描。三觉为本体+三次觉醒、四份英雄投入；持有率分母为活跃，觉醒完成率分母为持有。
- 竞技：真人局、英雄等级≥8、`card_awake`非零元素≥1、`card_super_slot`非零元素≥2；英雄出场次数非独立玩家数。
- 排位先对全体35名合格英雄分别计算胜率/MVP率原始排名，再展示关键事件A/S卡12位。特南克斯1,864次出场，胜率排名15、MVP率排名32。
- 漫斗先按各玩法全英雄排名，再展示最多5位关键事件A/S卡。单人乱斗名次1–4胜、双人乱斗名次1–2胜，其他所示玩法以第1名计胜，依据 `fivecross-sql-lib/games/jump_assemble/trino/ja_tc_arena_mvp_svp_stats.sql`。
- 所有公开竞技结果仅九种玩法，不展示 `game_type=8`，源查询行保留审计。未设置最低样本量，应结合出场次数解读。

## 复现本次结果

在案例目录运行准备脚本，然后在数据客户端目录执行任务。业务任务使用 `_sanji` 独立后缀，避免误取旧 `_gojo1` 或D1–D5文件。

```text
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/prepare_sql.py --end-date 2026-09-25
cd C:/Users/5xgames/Desktop/github/fivecross-data-client
venv/Scripts/python.exe main.py fetch --task trunks_case_01.json
venv/Scripts/python.exe main.py fetch --task trunks_case_02.json
venv/Scripts/python.exe main.py fetch --task trunks_case_03.json
venv/Scripts/python.exe main.py fetch --task trunks_case_05_sanji.json
cd C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/jump_assemble/01_monetization/s_class_trunks_monetization_d1_available_20260924
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/build_case.py --end-date 2026-09-25
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/verify_sanji.py
```

每项任务必须有新的CSV且读回验证；退出码0不能独立证明成功导出。04不需要为本次商业扩充重跑。05与 `verify_sanji.py` 明确锁定本次D1–D3范围，未来变更日期需同步修改。

## 验证状态

- PPTX实际打开10页；第1、2、4页7条活动数据与XLSX全部显示数值一致。
- XLSX：七期比较7行、养成7行、匹配分层42行、每日21行；香吉士9月9–11日与特南克斯9月23–25日日期断言通过。
- 独立SQL28行逐一核验日/窗口活跃、参与、抽数通过；分层活跃总数与快照人口核对通过。
- 全部幻灯片形状边界通过；Microsoft PowerPoint导出10页PNG，逐页视觉检查无明显截断/重叠。LibreOffice/poppler未安装，已用PowerPoint替代。第9页沿用宽松行高，不影响内容。
