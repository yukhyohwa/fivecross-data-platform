# 黑子的籃球｜覺醒卡碎片（1000015）現持有量分析

## 範圍

- 區服：JP（App 9）、繁中 / TC（App 10）、韓國 / KR（App 12）
- 資料來源：ThinkingData / Trino 的 `ta.v_event_9`、`ta.v_event_10`、`ta.v_event_12`
- 目標道具：覺醒卡碎片 `1000015`
- 分析窗口：以執行日前一日的完整資料分區為截止日往前推 3 個月；僅納入窗口內至少登入一次的玩家，所有事件掃描也限制在此窗口。這可避免當日資料持續入庫造成三份結果基數不一致。
- 黑名單：各區服的 `cohort_20231116_224917`、`cohort_waternew`

## 統計口徑

1. **目前持有數**：以每個 `uuid + gid` 在近 3 個月 `a_rst` 中，該道具最後一筆有效 `after` 作為角色目前庫存；窗口內沒有任何 `1000015` 流水的角色，持有數以 `0` 計。
2. **玩家粒度（問題 1–3）**：`uuid`（5x ID）。同一 `uuid` 若有多個 `gid`（role ID），碎片數會加總，避免同一玩家在付費分組被重複計算。
3. **五個持有區間**：`L1: 0`、`L2: 1–100`、`L3: 101–200`、`L4: 201–499`、`L5: 500+`。可在 `01_current_holding_summary_and_tiers.sql` 的 `Params` CTE 調整邊界。
4. **近 3 個月累計付費**：窗口內有效現金 `charge`，排除 `COIN`、`kuroko_pay`、sandbox 與 `order_id = '11'`；以每日幣別匯率換算 USD。
   - `> 1,000 USD`
   - `500–1,000 USD`
   - `0–499.99 USD`（含未付費玩家）

三個付費區間以 `uuid` 分組後再判斷，彼此完全互斥且覆蓋所有近 3 個月活躍玩家。若有效付費訂單缺少當日匯率，該筆不納入 USD 累計；查詢結果會輸出缺匯率訂單與玩家數，供核對。

## SQL 與執行順序

1. [01_current_holding_summary_and_tiers.sql](sql/01_current_holding_summary_and_tiers.sql)
   - 每個區服的玩家數、持有者數、全玩家 / 持有者平均持有量、五級分布。
2. [02_payment_tier_holding_summary.sql](sql/02_payment_tier_holding_summary.sql)
   - 三個互斥近 3 個月付費區間的人數與平均碎片持有量。
3. [03_recent_3_month_active_player_detail.sql](sql/03_recent_3_month_active_player_detail.sql)
   - 近三個月有登入的角色清單：區服、`gid`（role ID）、`uuid`（5x ID）、目前碎片數、最近登入時間與登入天數。

三份 SQL 都可獨立在 ThinkingData SQL IDE（Trino）執行。第 3 份使用 `CURRENT_DATE` 動態回推三個月；若需要固定分析截止日，可將 `Params.as_of_date` 改為指定日期。

也可使用本目錄的資料客戶端執行器一次跑完並保存 CSV：

```powershell
python scripts/run_queries.py
```

若需指定查詢，例如只跑 01 與 03：

```powershell
python scripts/run_queries.py --queries 01,03
```

設定檔範例為 `config/analysis.example.json`；輸出會寫入 `outputs/raw/<執行時間>/`。

## 已知限制與核對項目

- 目前庫存依賴近 3 個月 `a_rst` 有記錄目標道具的變動或快照；若角色的最後一筆目標道具快照早於窗口，或後端有不寫入 `a_rst` 的直接發放 / 修正流程，這份快速版會把該角色顯示為 `0`，需另行補入更早快照或權威庫存表。
- 問題 1–3 是 5x ID 粒度；問題 4 是角色粒度，故同一 `uuid` 若存在多個角色會列出多行，保留 `gid` 對照。
- 這個 case 只建立了可重跑 SQL，尚未連線執行，沒有附帶任何虛構結果。
