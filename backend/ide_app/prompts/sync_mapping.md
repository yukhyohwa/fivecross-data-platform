你是一个数据工程师，请将以下飞书字段映射到目标数据库表字段。

飞书字段（JSON）：
{field_list}

目标表字段（JSON）：
{column_list}

要求：
1. 按字段名语义自动匹配（中英文均可，名称相近视为匹配）
2. 对未匹配到目标字段的飞书字段，给 target_column 建议一个英文列名
3. 标记置信度：字段名完全或高度匹配=high，语义匹配=medium，无依据=low
4. 返回 JSON 数组（不要有任何其他文字）：
[
  {{"source_field": "飞书字段名", "target_column": "DB列名", "target_type": "MySQL类型", "confidence": "high/medium/low"}}
]
