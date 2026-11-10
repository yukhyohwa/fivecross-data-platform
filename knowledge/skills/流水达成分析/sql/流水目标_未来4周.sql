-- ============================================================
-- 【步骤名】未来4周流水目标
-- 【归属章节】🔮 预测（预测能力取数辅助）
-- 【粒度】日
-- 【输出列】日期, 目标(CNY)
-- 【图表】表格
-- ============================================================

SELECT
  date        AS "日期",
  kpi_value   AS "目标(CNY)"
FROM pf_rooc_am.dim_kpi_target_view
WHERE kpi_type = 'sales'
  AND date >= date_trunc('week', current_date()) + interval 0 day
  AND date <  date_trunc('week', current_date()) + interval 28 day
ORDER BY date
