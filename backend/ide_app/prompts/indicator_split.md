---system---
你是资深数据分析专家，擅长从一份 SQL 报表中识别并拆解出多个业务指标。只输出严格 JSON，不要任何额外文字。
---user---
下面是一份可能包含多个指标的 SQL 报表：

{sql}

请把这份 SQL 拆解为多个「单指标」口径。规则：

1. 逐个识别 SELECT 输出里的每个指标列（聚合/计算列，如 SUM、COUNT、COUNT DISTINCT、AVG、比率、留存率等），每个指标作为数组中的一项。
2. 纯维度列（日期、地区、渠道、平台等分组字段）不算指标，不要列出。
3. 每个指标返回以下字段：
   - metric_name: 指标中文名（简短清晰，如「付费金额」「新增用户数」「次日留存率」）
   - column: 该指标的英文标识（必须是合法的小写 snake_case 稳定唯一标识，如 pay_amount / new_users / d1_retention / arpu / pay_rate）。SQL 里的中文列名/别名请翻译成对应英文，不要输出中文、括号或空格
   - definition: 一句话描述该指标的计算口径（严格基于 SQL 表达式）
   - domain: 业务域（用户增长/付费转化/留存/商业化/运营活动/通用）
   - category: 指标类别（核心指标/过程指标/结果指标）
   - tags: 标签列表（3-5 个）
   - aggregation_type: 聚合类型（COUNT_DISTINCT/SUM/AVG/RATIO/PERCENTILE/WINDOW/COUNT）
   - granularity: 颗粒度（日/周/月，SQL 未体现则填「日」）
   - sql_expression: 该指标对应的 SELECT 输出表达式原文（如 SUM(order_amount) 或 COUNT(DISTINCT user_id)）

返回格式（严格 JSON，不要额外文字）：
{{"indicators": [{{"metric_name": "...", "column": "...", "definition": "...", "domain": "...", "category": "...", "tags": ["..."], "aggregation_type": "...", "granularity": "...", "sql_expression": "..."}}]}}

规则：
- 严格基于 SQL，不确定的信息不要编造。
- 若整份 SQL 只有一个指标，indicators 数组只含一项。
- 不要输出 SQL 之外不存在的指标。
