# 黑子的籃球 TC｜LAST GAME 綠間首五日取得與養成

原目录名为 `new_card`；现按实际分析对象命名为 `tc_lg_midorima_acquisition_cultivation_20260819_20260823`，归入球员养成与资源。SQL 与原始 Excel 均保留。

## 分析範圍

- 區域：黑子的籃球繁中（TC）
- 球員：LAST GAME 綠間
- 卡牌 ID：`99300603`
- 統計期間：2026-08-19 00:00:00 ～ 2026-08-23 23:59:59（Asia/Shanghai 自然日）
- 資料源：ThinkingData `ta.v_event_10`
- 去重主鍵：`#user_id`

## 查詢結果

| 指標 | 玩家數 | 占新獲取玩家 |
|---|---:|---:|
| 新獲取玩家 | 317 | 100.0% |
| 天賦達 60% | 42 | 13.2% |
| 天賦達 80% | 12 | 3.8% |
| 覺醒 I | 131 | 41.3% |
| 覺醒 II | 97 | 30.6% |
| 覺醒 III | 52 | 16.4% |
| 覺醒 IV | 47 | 14.8% |
| 覺醒 V | 25 | 7.9% |
| 覺醒 VI | 24 | 7.6% |

## 統計口徑

1. **新獲取玩家**：在統計期間將 `a_rst` 展開後，`id = 99300603` 且 `diff > 0` 的不重複 `#user_id`。
2. **天賦達標**：僅限新獲取玩家；以 `card_skillrune` 事件中該卡牌的期間最高 `talent_rate` 判定。60% 與 80% 均為「大於等於」門檻，屬累計人數。
3. **覺醒達標**：僅限新獲取玩家；以 `cardstunt_levelup` 事件中該卡牌的期間最高 `awaken_skill_level` 判定。覺醒 I～VI 均為「大於等於」門檻，屬累計人數。
4. **黑名單排除**：排除 `user_result_cluster_10` 中 `cohort_20231116_224917` 與 `cohort_waternew` 的使用者。

## 檔案

- `黑子TC_LAST_GAME綠間_2026-08-19至2026-08-23.xlsx`：可直接閱讀的分析結果、口徑、原始匯總與 SQL。
- `lg_midorima_20260819_20260823.sql`：ThinkingData / Trino 可重跑 SQL。

## 重跑方式

在 ThinkingData SQL IDE 執行 `lg_midorima_20260819_20260823.sql`。若要改期間，請同步更新 SQL 中 `Params` CTE 的 `start_date`、`end_date`、`start_ts` 與 `end_ts`，避免分區日期與事件時間範圍不一致。
