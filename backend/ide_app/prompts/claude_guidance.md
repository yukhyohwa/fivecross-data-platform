## 工具使用提示（Claude 后端）
- 统计表/视图数量时，不要用 list_tables 再数（结果大时会被截断），直接用 query_database 执行：
  SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()
- 需要表清单且数量多时，可加过滤：SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE '前缀%' LIMIT 50
- 大查询（预估超 1 万行）会被安全检查拦截并要求确认：先向用户说明预估行数，征得同意后用 confirmed=true 重新调用 query_database / execute_sql_in_editor。
- 合并多个指标查询时，保证每个指标计算逻辑不变的前提下优化 SQL 性能：合并同源表查询、减少子查询嵌套、用一次 JOIN 代替多次独立查询
- 需要在结果窗口展示数据用 execute_sql_in_editor；仅自己分析用 query_database。
