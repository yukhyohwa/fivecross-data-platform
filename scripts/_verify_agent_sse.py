# -*- coding: utf-8 -*-
"""端到端验证：live 后端 /api/agent/chat/stream（深度分析）流式 SSE 中文编码。
以 hanqiding 身份复现用户场景：Joydata 报表问题 + ROOC南北美(rooc_am)。"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # data_ai 根（backend 与 analysis 都在这里）

import json

import requests

from backend.ide_app.core.auth import create_token

UID = "f24b5ecf-f24"
access, _refresh, _exp = create_token(UID)

QUESTION = sys.argv[1] if len(sys.argv) > 1 else "取一下 Sales by Pay_type 最近3天的数据"
GAME = sys.argv[2] if len(sys.argv) > 2 else "rooc_am"

MOJI = ("æ", "ã", "ç", "é", "å", "è", "ï¼", "è®¢", "æ¯")

resp = requests.post(
    "http://localhost:8000/api/agent/chat/stream",
    headers={"Authorization": f"Bearer {access}", "X-Game": GAME},
    json={"message": QUESTION},
    timeout=(30, 420),
    stream=True,
)
print("status:", resp.status_code)
if resp.status_code != 200:
    print(resp.text[:500])
    sys.exit(1)

bad = 0
deltas = []
events = {}
for raw in resp.iter_lines(decode_unicode=False):
    if not raw:
        continue
    line = raw.decode("utf-8", errors="replace").strip()
    if not line.startswith("data:"):
        continue
    payload = line[len("data:"):].strip()
    try:
        ev = json.loads(payload)
    except Exception:
        continue
    t = ev.get("type")
    events[t] = events.get(t, 0) + 1
    text = ""
    if t == "answer":
        text = ev.get("delta") or ev.get("text") or ""
        if text:
            deltas.append(text)
    elif t == "final":
        text = ev.get("reply") or ""
        if text and text not in deltas:
            deltas.append(text)
    elif t in ("progress", "plan_text", "tool_done", "error", "tool_start"):
        text = json.dumps(ev, ensure_ascii=False)
    for s in MOJI:
        if s in text:
            bad += 1
            print("MOJIBAKE:", repr(text[:160]))
            break

answer = "".join(deltas)
print("events:", events)
print("--- answer ---")
print(answer[:2500])
print("---")
print("RESULT:", "FAIL (mojibake)" if bad else "OK")
