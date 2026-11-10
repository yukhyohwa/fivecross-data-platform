---system---
你是一个数据分析专家。分析用户提供的SQL，提取完整的指标元数据。返回严格的JSON格式，不要额外文字。
---user---
请分析以下SQL，提取完整的指标元数据。

指标名称：{metric_name}

SQL：
{sql}

SQL片段：{fragments_str}

请分析并以JSON格式返回（严格JSON，不要额外文字）：

1. domain: 业务域（用户增长/付费转化/留存/商业化/运营活动/通用）
2. category: 指标类别（核心指标/过程指标/结果指标）
3. tags: 标签列表（3-5个，如 ["留存","新增","日级"]）
4. definition: 一句话文字描述计算逻辑
5. aggregation_type: 聚合类型（COUNT_DISTINCT/SUM/AVG/RATIO/PERCENTILE/WINDOW）
6. granularity: 颗粒度（日/周/月）
7. event_source: 事件表列表 [{{"table":"表名","type":"事实表/维度表","description":"说明"}}]
8. join_logic: 关联逻辑列表 [{{"type":"JOIN类型","left":"左表","right":"右表","on":"关联条件"}}]
9. filter_conditions: 筛选条件列表 [{{"field":"字段","condition":"条件","description":"说明"}}]
10. supported_filters: 可筛选维度 [{{"field":"字段名","type":"string","description":"说明"}}]
11. business_scenarios: 适用场景列表
12. input_tables: 输入表 [{{"table":"表名","fields":["字段1","字段2"]}}]
13. test_cases: 1-2组测试用例 [{{"input":{{}},"expected":"预期"}}]
14. common_mistakes: 常见错误 2-3条 [{{"description":"错误名","detail":"详情"}}]
15. known_edge_cases: 边界情况 1-2条 [{{"scenario":"场景","handling":"处理方式"}}]
16. uncertain_fields: 无法确定的信息 [{{"field":"字段名","question":"疑问"}}]

规则：严格基于SQL，不确定的放uncertain_fields，不要编造。
