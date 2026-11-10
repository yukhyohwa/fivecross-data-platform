# 灌篮高手中国（阿里云）数据查询规则

## 项目路由

- 项目 key：`slam_dunk_cn_ali`
- 数据源：AliCloud MaxCompute / ODPS，通过平台内置 `fivecross-data-client`
- `app_id` / `game_id`：`13002010`
- 查询区域：`china`

## 中国收入查询

中国项目的近期收入优先使用订单明细表 `dm_platform.daily_lcx_user_purchase`，不要使用海外 ThinkingData 事件表，也不要套用参考项目的 `pf_*` MySQL/StarRocks 视图。

推荐口径：

- 有效订单：`COALESCE(CAST(price_show AS DOUBLE), 0) > 0`
- 项目过滤：`CAST(app_id AS STRING) = '13002010'`
- 金额：`SUM(CAST(price_show AS DOUBLE))`
- 订单数：`COUNT(1)`
- 付费用户数：`COUNT(DISTINCT lcm_id)`
- 日期字段：`day`，通常为 `yyyyMMdd` 整数或字符串
- 查询前必须明确实际数据覆盖到哪一天；不要把当前日期直接宣称为数据最新日

示例：

```sql
SET odps.sql.hive.compatible = TRUE;
SELECT
  CAST(day AS STRING) AS day,
  SUM(CAST(price_show AS DOUBLE)) AS revenue,
  COUNT(1) AS orders,
  COUNT(DISTINCT lcm_id) AS payers
FROM dm_platform.daily_lcx_user_purchase
WHERE CAST(app_id AS STRING) = '13002010'
  AND CAST(day AS BIGINT) BETWEEN 20261103 AND 20261109
  AND COALESCE(CAST(price_show AS DOUBLE), 0) > 0
GROUP BY day
ORDER BY day;
```

`dm_platform.transaction_wallet` 是独立的钱包/充值流水指标，不能在未核验字段结构时替代 `daily_lcx_user_purchase` 的订单明细。中国项目不能执行以下参考平台视图：`dwd_all_games_purchase_i_rt_view`、`dim_kpi_target_view` 或任意 `pf_slam_dunk_cn_ali.*`。
