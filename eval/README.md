# SQL 生成质量评估（eval）

对 SQL 生成链路做回归：给定「问题 → 期望 SQL 特征」，跑 `analysis.sql_gen.generate_sql`
并检查结果，用于在改动 schema 上下文 / 提示词 / 术语表后回归验证生成质量。

## 用法

在 `data_ai/` 目录下：

```bash
python -m eval.run_eval              # 跑全部用例
python -m eval.run_eval --only 充值  # 只跑 name 含「充值」的用例
python -m eval.run_eval --run-sql    # 额外把生成的 SQL 真跑一遍（需连库）
python -m eval.run_eval --model <m>  # 指定模型
```

结果打印到终端，并写入 `eval/report.json`。

## 用例格式（eval_cases.json）

每条：

```json
{
  "name": "用例名",
  "game": "kof",              // 游戏 key（决定目标库）
  "question": "自然语言问题",
  "expect_keywords": ["pf_kof", "price_cny_from_api"],   // 生成的 SQL 必须包含这些子串（小写比较）
  "expect_sql": "select ..."  // 可选：归一化后需包含这段 SQL
}
```

## 通过标准

- `expect_keywords` 全部出现在生成 SQL 中（大小写不敏感）；
- 若给了 `expect_sql`，归一化（压缩空白、转小写）后需包含该串；
- `--run-sql` 时额外要求 SQL 能执行成功。

## 建议

- 覆盖核心业务规则：按产品代码换库（kof / kof_sea）、币种列（price_cny / price_usd）、时区口径等。
- 改 `analysis/sql_gen`、`services/schema_context`、`analysis/glossary.py` 或术语表后，跑一遍做回归。
- 用例越多越能兜住回归；但每条会消耗一次 LLM 调用，按需维护。
