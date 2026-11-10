"""DataFrame → 前端表格载荷的共享工具。"""
import json

import pandas as pd

MAX_TABLE_ROWS = 500


def df_to_table(df: pd.DataFrame, max_rows: int = MAX_TABLE_ROWS) -> dict:
    head = df.head(max_rows)
    payload = json.loads(head.to_json(orient="split", date_format="iso"))
    return {
        "columns": payload["columns"],
        "rows": payload["data"],
        "total_rows": int(len(df)),
    }
