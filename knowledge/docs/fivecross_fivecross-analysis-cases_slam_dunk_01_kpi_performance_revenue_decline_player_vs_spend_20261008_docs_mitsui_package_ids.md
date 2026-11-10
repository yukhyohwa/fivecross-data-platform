# 殿堂三井禮包 SKU（TA 觀察映射）

活動開始：2026-09-24。來源：`ta.v_event_20` 的 PURCHASE `payload.productid`，觀察窗口 2026-09-24 至 2026-10-07。

從活動上線後新出現的連續 package 序列與購買集中度，辨識出四個禮包代碼：

- `package0146`
- `package0147`
- `package0148`
- `package0149`

實際觀察到的完整 SKU：

```text
com.denachina.g23002013.apk_tier14.package0148
com.denachina.g23002013.apk_tier20.package0148
com.denachina.g23002013.apk_tier27.package0148
com.denachina.g23002013.apk_tier53.package0148
com.denachina.g23002013.apk_tier55.package0148
com.denachina.g23002013.apk_tier60.package0149
com.denachina.g23002013.apple_tier10.package0147
com.denachina.g23002013.apple_tier14.package0148
com.denachina.g23002013.apple_tier20.package0148
com.denachina.g23002013.apple_tier27.package0146
com.denachina.g23002013.apple_tier27.package0148
com.denachina.g23002013.apple_tier53.package0148
com.denachina.g23002013.apple_tier55.package0148
com.denachina.g23002013.apple_tier60.package0149
com.denachina.g23002013.google_tier10.package0147
com.denachina.g23002013.google_tier14.package0148
com.denachina.g23002013.google_tier20.package0148
com.denachina.g23002013.google_tier27.package0146
com.denachina.g23002013.google_tier27.package0148
com.denachina.g23002013.google_tier53.package0148
com.denachina.g23002013.google_tier55.package0148
com.denachina.g23002013.google_tier60.package0149
```

狀態：高可信 TA 行為映射。現有本機 `dim_product.xlsx` 尚未包含 `package0146–0149`，因此商品中文名稱與「四個代碼是否全部屬於三井」仍需正式商品配置確認。報告會明確保留此限制。

## 活動幣與點券

三井活動期資源探查顯示以下兩個新活動幣與大量點券／鑽石消耗同事务出現：

- `item@141025152`：暫定轉盤幣。
- `item@141025153`：暫定特訓轉盤幣。

兩者為連續新 ID，結構與流川 `141025034/035`、宮城 `141025099/100` 一致，而且是 9/24 後與點券消耗關聯最大的兩個新道具，因此作為三井參與口徑，可信度高。現有本機 `dim_item.xlsx` 尚未收錄這兩個 ID，中文名稱及兩者順序仍需正式配置確認。

`item@141025156` 也在活動期出現高額點券關聯，但不納入轉盤參與；它可能是資料包或其他高價資源，待配置確認。
