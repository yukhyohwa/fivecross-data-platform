# 黑子的籃球 TC｜昨日付費拉高排查（2026-08-25）

## 要回答的問題

1. 昨天付費最高的玩家是哪些？
2. 他們分別買了哪些儲值商品？
3. 若玩家當天的儲值訂單確實有增加付費點券，這些玩家的付費點券當日消耗在哪些場景、同事件獲得了什麼？

## 範圍與口徑

- 區域：黑子的籃球繁中（TC），ThinkingData App 10。
- 日期：`2026-08-25`，Asia/Shanghai 自然日；以 `$part_date` 篩選。
- 玩家粒度：`#user_id`；`uuid`、`role_name` 僅供辨識與閱讀。
- 有效現金儲值：`charge`，且排除 `COIN`、`kuroko_pay`、sandbox 訂單與 `order_id = '11'`。依日期與幣別連結 `ta_dim.ta_exchange` 換算 USD。
- 黑名單：排除 `user_result_cluster_10` 的 `cohort_20231116_224917`、`cohort_waternew`。
- 高付費玩家：以有效現金儲值 USD 降冪的前 50 名；可修改每份 SQL 的 `Params.top_n`。
- 付費點券：道具 ID `10000000`；免費點券／躍之星 ID `19000000`，不列為付費點券流向。

## 執行順序與產出

1. [01_top_payers.sql](sql/01_top_payers.sql)：高付費玩家排行、個人昨日有效現金儲值、訂單／事件數與佔比。
2. [02_top_payer_products.sql](sql/02_top_payer_products.sql)：上述玩家的商品 ID、商品名稱、購買事件數、訂單數與商品儲值金額。
3. [03_paid_stamps_outflow.sql](sql/03_paid_stamps_outflow.sql)：僅保留「當日 `charge` 事件中 `a_rst` 真的增加 `10000000`」的高付費玩家；列出當日付費點券消耗事件及該事件正向獲得的道具。

三份 SQL 可在 ThinkingData SQL IDE（Trino）獨立執行。先跑 01 確認付費集中度與玩家清單，再跑 02、03 查看購買內容與點券去向。

也可使用本機既有的 `fivecross-data-client` 一次執行並保留 CSV：

```powershell
python scripts/run_queries.py
```

執行器預設讀取 `config/analysis.example.json`；如資料客戶端位址不同，複製它為 `analysis.json` 後調整 `data_client_root`，再加上 `--config config/analysis.json`。原始結果會寫入 `outputs/raw/<執行時間>/`。

## 讀取結果時的注意事項

- 商品名稱以 `ta_dim.dim_10_0_12842` 對應；無維表名稱時輸出商品 ID，避免把未知商品誤命名。
- `有效儲值事件數` 是事件列數；`不同訂單數` 是可用 `order_id` 的去重數。若兩者差距異常大，先檢查支付事件是否存在重送或空訂單號。
- 缺少當日／幣別匯率的訂單不會進入 USD 排行，避免錯誤地以 1:1 計價；如發現大盤金額與既有 KPI 不一致，先核對 `ta_exchange` 完整性。
- 點券資產沒有「來源批次」標記。SQL 3 僅能證明：玩家當天購得付費點券，且當天發生付費點券消耗；**不能**精確聲稱某一筆消耗必然使用剛買的那一批點券。
- SQL 3 將每次點券消耗聚合到事件層並把同事件獲得道具串列，避免「一筆點券消耗對多個獲得道具」時重複加總點券。若 `同事件獲得道具` 為空，代表該事件的產出不在 `a_rst`，需依事件名再查事件專屬欄位。

## 來源依據

- SQL 邏輯：`fivecross-sql-lib/games/kurokos_basketball/GAME_LOGIC_RULES.md`
- 既有 TC 參考：`kb_tc_daily_top_paying_users_breakdown_20260808.sql`、`kb_tc_daily_top_paying_users_stamps_consumption_20260808.sql`
