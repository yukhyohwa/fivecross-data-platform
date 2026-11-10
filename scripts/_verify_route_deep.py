# -*- coding: utf-8 -*-
"""端到端验证：智能路由（普通模式识别探索性问题 → route_deep 事件，前端自动切深度分析）。

两条用例（live 后端 /api/chat，hanqiding 身份，游戏 rooc_am）：
  A. 探索性问题 → 必须出现 route_deep 事件且流随即结束
  B. 常规取数   → 绝不出现 route_deep，流越过对话理解进入检索/执行阶段
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # data_ai 根（backend 与 analysis 都在这里）

import json

import requests

from backend.ide_app.core.auth import create_token

UID = "f24b5ecf-f24"
access, _refresh, _exp = create_token(UID)
GAME = sys.argv[1] if len(sys.argv) > 1 else "rooc_am"

CASES = [
    ("exploratory", "为什么最近流水下降了，帮我找找原因", "route_deep 必须出现"),
    ("routine", "最近7天各国家流水趋势", "route_deep 绝不能出现"),
]


def run(question: str, expect_deep: bool) -> dict:
    resp = requests.post(
        "http://localhost:8000/api/chat",
        headers={"Authorization": f"Bearer {access}", "X-Game": GAME},
        json={"model": "", "message": question, "mode": "auto", "history": []},
        timeout=(30, 300),
        stream=True,
    )
    if resp.status_code != 200:
        return {"status": resp.status_code, "events": [], "deep": False, "detail": resp.text[:300]}
    events, stages = [], []
    seen_deep = False
    for raw in resp.iter_lines(decode_unicode=False):
        if not raw:
            continue
        line = raw.decode("utf-8", errors="replace").strip()
        if not line.startswith("data:"):
            continue
        try:
            ev = json.loads(line[len("data:"):].strip())
        except Exception:
            continue
        events.append(ev.get("type"))
        if ev.get("type") == "route_deep":
            seen_deep = True
        if ev.get("type") == "stage":
            stages.append(ev.get("message"))
        if not expect_deep:
            # 越过 route_deep 检查点（decide 之后）的事件才允许提前断开：
            # - 非「理解你的问题…/使用模型 …」的 stage（检索/命中/生成等）
            # - 或任何检索/确认/结果类事件（meta/candidates/answer/sql/data/done…）
            t = ev.get("type")
            m = ev.get("message") or ""
            post_decide = (
                t in ("candidates", "meta", "answer", "confirm", "sql", "data", "suggest",
                      "generate", "error", "done", "usage", "game_confirm", "forecast_confirm",
                      "ai_report_confirm", "rewrite_confirm", "generate_confirm")
                or (t == "stage" and m not in ("理解你的问题…",) and not m.startswith("使用模型 "))
            )
            if post_decide:
                break  # 已越过检查点且未见 route_deep → 判定不路由，提前断开省时间
    return {"status": resp.status_code, "events": events, "stages": stages, "deep": seen_deep, "detail": ""}


fail = 0
for label, question, expect in CASES:
    expect_deep = label == "exploratory"
    r = run(question, expect_deep)
    ok = (r["deep"] is expect_deep)
    print(f"[{label}] question={question}")
    print(f"  status={r['status']} route_deep={r['deep']} (expect {expect_deep})")
    print(f"  stages={r['stages'][:6]}")
    print(f"  events={r['events'][:12]}")
    if r["detail"]:
        print(f"  detail={r['detail'][:200]}")
    print(f"  RESULT: {'OK' if ok else 'FAIL'}")
    if not ok:
        fail += 1

print("OVERALL:", "FAIL" if fail else "OK")
sys.exit(1 if fail else 0)
