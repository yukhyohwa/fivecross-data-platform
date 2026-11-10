"""对抗审查二轮修复批冒烟（本地 127.0.0.1:8000，token 仅进程内使用、绝不打印）。"""
import json
import sys

import requests

BASE = "http://127.0.0.1:8000"
results = []


def check(name, cond, extra=""):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + (("  " + extra) if extra and not cond else ""))


# 登录拿 token（进程内，不打印）
r = requests.post(f"{BASE}/api/auth/login", json={"username": "admin", "password": "admin123"}, timeout=15)
if r.status_code != 200:
    # 本地 admin 密码可能已改：走进程内 create_token（不打印 token）。
    # 注意 create_token(user_id: str) 收的是 id 字符串——传 dict 会让 sub 变成 dict，
    # get_user_by_id 解析不出用户 → 静默回落匿名（本地 AUTH_ENABLED=false 时冒烟全程匿名跑）。
    from backend.ide_app.core.auth import create_token
    from backend.ide_app.services import db_service
    row = db_service._conn().execute(
        "SELECT id FROM users WHERE username='admin'").fetchone()
    tok = create_token(row[0])[0]
else:
    tok = r.json()["access_token"]
H = {"Authorization": f"Bearer {tok}"}


def sse_events(text):
    return [json.loads(line[6:]) for line in text.splitlines() if line.startswith("data: ")]


# 1. 深度哨兵 ask 短流：game_select + final 带编号选项行
r = requests.post(f"{BASE}/api/agent/chat/stream", json={
    "message": "最近7天各国家流水趋势", "history": []},
    headers={**H, "X-Game": "__any__"}, timeout=60)
check("deep sentinel ask 200", r.status_code == 200, str(r.status_code))
evs = sse_events(r.text)
types = [e["type"] for e in evs]
check("deep sentinel types", types[:3] == ["game_select", "question", "final"], str(types[:4]))
fin = evs[-1] if evs else {}
check("deep sentinel final numbered", fin.get("type") == "final" and "1." in fin.get("reply", ""),
      str(fin.get("reply", ""))[:80])

# 2. 普通聊天哨兵 ask 卡
r = requests.post(f"{BASE}/api/chat", json={
    "model": "", "message": "最近7天各国家流水趋势", "mode": "auto", "preset_skill": None,
    "chart_type": "auto", "docs": [], "context_report": None, "history": [], "confirm": None},
    headers={**H, "X-Game": "__any__"}, timeout=120)
check("chat sentinel ask 200", r.status_code == 200, str(r.status_code))
evs2 = sse_events(r.text)
t2 = [e["type"] for e in evs2]
check("chat sentinel game_select", "game_select" in t2, str(t2[:6]))

# 3. export-csv 伪造嵌套条目跳过 + 合法条目导出
r = requests.post(f"{BASE}/api/chat/export-csv", json={
    "sql": "", "name": "smoke", "sqls": [
        {"sql": {"nested": 1}, "db": "pf_ro_hmt", "label": "bad"},
        {"sql": "SELECT 1", "db": "pf_ro_hmt", "label": "hmt"},
    ]}, headers={**H, "X-Game": "__any__"}, timeout=60)
check("export-csv non-string skip 200", r.status_code == 200, str(r.status_code))
body = r.content.decode("utf-8-sig") if r.status_code == 200 else ""
check("export-csv csv ok", "地区" in body and "hmt" in body and "bad" not in body, body[:120])

# 4. gap-whitelist 只读列表：未知专项名不 500（GET 不落盘，避免 POST 写临时白名单文件）
r = requests.get(f"{BASE}/api/chat/gap-whitelist", params={"skill": "不存在专项名smoke"},
                 headers=H, timeout=30)
check("gap-whitelist unknown skill no-500", r.status_code in (200, 403, 404), str(r.status_code))

# 5. gap 只读列表 + 游戏列表
r = requests.get(f"{BASE}/api/games", headers=H, timeout=15)
check("games 200", r.status_code == 200, str(r.status_code))

failed = [n for n, ok in results if not ok]
print("\nSMOKE RESULT:", "ALL PASS" if not failed else f"FAILED: {failed}")
sys.exit(1 if failed else 0)
