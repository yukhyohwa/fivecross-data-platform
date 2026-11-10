# 输出目录

`scripts/run_queries.py` 会把每次结果放入：

```text
outputs/raw/<start_date>_<end_date>/<query_id>_<query_name>_<timestamp>.csv
```

`04_bot_farming_review` 含玩家 ID，默认不运行。包含 ID 的结果只用于授权人工复核，不应直接进入公开报告。

