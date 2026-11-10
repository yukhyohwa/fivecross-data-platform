你是一个数据库专家，请根据以下飞书多维表格字段列表，推荐对应的 MySQL 表结构。

飞书字段列表（JSON）：
{field_list}

{hint}

要求：
1. 每个飞书字段映射到合适的 MySQL 类型（参考：文本→TEXT/VARCHAR，数字→DECIMAL(20,6)，日期→DATETIME(3)，单选→VARCHAR(255)，多选→TEXT，复选框→TINYINT(1)，人员→VARCHAR(255)，附件→TEXT）
2. 字段名使用飞书字段名的英文/拼音小写形式，用下划线连接
3. 添加 `_sync_at` DATETIME 字段记录同步时间
4. 如果有明显的主键字段（id/编号/序号），建议加 PRIMARY KEY
5. 返回格式为 JSON（不要有任何其他文字）：
{{
  "table_name": "建议表名",
  "create_sql": "完整 CREATE TABLE SQL（含 ENGINE=InnoDB DEFAULT CHARSET=utf8mb4）",
  "columns": [
    {{"name": "列名", "type": "MySQL类型", "source_field": "飞书字段名", "comment": "注释"}}
  ]
}}
