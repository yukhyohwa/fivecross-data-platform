"""未上线游戏分月流水预测（离线上传型占位）。

源自内置能力 prelaunch_monthly（10_未上线游戏分月流水预测）。该能力依赖离线上传的
《历史数据_新增留存ARPU.xlsx》+《新增前120日比例.csv》（未上线游戏无 DB 数据），
chat_bi 暂无上传取数链路。可在此实现 `def run(df_hist, pred_end, **params)` 以接入自动取数。
"""


def run(df_hist, pred_end, **params):
    raise NotImplementedError(
        "「未上线游戏分月流水预测」为离线上传型能力，暂不支持自动取数。"
        "请离线使用《历史数据_新增留存ARPU.xlsx》模板测算，或在此实现自动取数逻辑。"
    )
