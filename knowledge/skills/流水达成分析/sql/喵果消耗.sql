-- ============================================================
-- 【步骤名】最近2周喵果消耗对比
-- 【归属章节】🔍 明细下钻 ⑤ 喵果消耗
-- 【粒度】周/商品（月卡溢出 vs 外显主动）
-- 【输出列】类型, 商品名称, 上一完整周消耗喵果, 最近完整周消耗喵果
-- 【图表】堆叠柱状
-- 【参考知识库】数据指标知识库
-- ============================================================

WITH base AS (
  SELECT
    date,
    CASE WHEN goodsname IS NULL THEN '基础功能消耗' ELSE '外显主动消耗' END AS consume_type,
    CASE WHEN goodsname IS NULL THEN reason_name ELSE goodsname END AS goods_name,
    imoney
  FROM pf_rooc_am.dws_coremoney_consume_flow_view
  WHERE moneytype = 103
    AND date >= date_trunc('week', current_date()) - interval 14 day
    AND date < date_trunc('week', current_date())
),
goods_money AS (
  SELECT consume_type, goods_name,
         SUM(CASE WHEN date >= date_trunc('week', current_date()) - interval 7 day
                   AND date < date_trunc('week', current_date())
                  THEN imoney ELSE 0 END) AS cur_money,
         SUM(CASE WHEN date >= date_trunc('week', current_date()) - interval 14 day
                   AND date < date_trunc('week', current_date()) - interval 7 day
                  THEN imoney ELSE 0 END) AS prev_money
  FROM base
  GROUP BY consume_type, goods_name
),
card AS (
  SELECT '基础功能消耗' AS consume_type, '合计' AS goods_name,
         SUM(cur_money) AS cur_money, SUM(prev_money) AS prev_money
  FROM goods_money
  WHERE consume_type = '基础功能消耗'
),
non_card_total AS (
  SELECT '外显主动消耗' AS consume_type, '合计' AS goods_name,
         SUM(cur_money) AS cur_money, SUM(prev_money) AS prev_money
  FROM goods_money
  WHERE consume_type = '外显主动消耗'
),
non_card AS (
  SELECT consume_type, goods_name, cur_money, prev_money
  FROM goods_money
  --WHERE consume_type = '外显主动消耗'
)
SELECT
  consume_type AS "类型",
  goods_name AS "商品名称",
  prev_money AS "上一完整周消耗喵果",
  cur_money AS "最近完整周消耗喵果"
FROM (
  SELECT * FROM card
  UNION ALL
  SELECT * FROM non_card_total
  UNION ALL
  SELECT * FROM non_card
) t
ORDER BY cur_money DESC;
