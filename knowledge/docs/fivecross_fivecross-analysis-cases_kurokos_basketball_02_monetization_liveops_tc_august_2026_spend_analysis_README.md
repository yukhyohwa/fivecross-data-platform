# 黑子籃球 TC｜2026 年 8 月儲值與點券消耗

分析期間：2026-08-01 至 2026-08-30（含首尾）。資料源為 `ta.v_event_10`；黑名單排除 `cohort_20231116_224917` 與 `cohort_waternew`。

## 口徑

- 有效儲值：`charge`，排除 `COIN`、`kuroko_pay`、sandbox 及 `order_id = 11`，依當日匯率換算 USD。
- 點券：資源 ID `10000000`（不含免費點券 `19000000`）。
- 點券流向：一筆原子事件中消耗點券時，將同事件內正向產出的非貨幣道具視為流向商品；若單一事件產出多項道具，點券金額會分別關聯至各道具，因此為「關聯點券消耗」，不可加總為全服實際點券總量。
- 付費分層：依期間有效現金儲值額排序，以 `NTILE(10)` 切分；大 R 為前 10%，中 R 為後續 20%，小 R 為其餘 70%。

## 查詢與執行

在 `C:\Users\5xgames\Desktop\github\fivecross-analysis-cases\kurokos_basketball\02_monetization_liveops\tc_august_2026_spend_analysis` 執行：

```powershell
$python = "C:\Users\5xgames\Desktop\github\fivecross-data-client\venv\Scripts\python.exe"
& $python .\src\run_analysis.py all
```

也可將 `all` 換成 `00` 至 `05` 執行單一查詢。拉取結果會寫入 `data/raw/`，任務 JSON 會寫入 `data/tasks/`。

| 編號 | 內容 |
| --- | --- |
| 00 | 三位球員首周活躍與養成（獲取、天賦、覺醒） |
| 01 | 期間內儲值金額／占比 Top 10 商品 |
| 02 | 全部玩家關聯點券消耗 Top 10 商品 |
| 03 | 大／中／小 R 各自關聯點券消耗 Top 10 商品 |
| 04 | 大 R 關聯點券流向 Top 5 商品 |
| 05 | 全部玩家關聯點券流向 Top 5 商品 |
