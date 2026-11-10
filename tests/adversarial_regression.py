# -*- coding: utf-8 -*-
"""对抗审查修复批回归测试（2026-10-21）：
T1 回收站闭环 + purge 防护（在用工件/中间目录/不存在条目）
T2 个人级隔离（列表过滤 / restore / purge / list_versions）
T3 恢复联动元数据（个人级 meta 回位，不回落到通用）
T4 rename 镜像残留预检（先拦后 purge 放行）
T5 聊天软删 trashed_at + 恢复自愈（双份崩溃残留）
T6 备份临时文件（无 .db.tmp 残留、失败不占当天名额）
"""
import json
import shutil
import sys
import time
from pathlib import Path

import requests

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # 仓库根（backend 与 analysis 都在这里）

BASE = "http://localhost:8000"
results = []


def check(name, cond, extra=""):
    results.append((name, bool(cond), extra))
    print(("PASS " if cond else "FAIL ") + name + (("  " + extra) if extra else ""))


# ── 进程内 token（生产 admin 密码已改，不走登录）──
from backend.ide_app.core import auth  # noqa: E402
from backend.ide_app.services import db_service  # noqa: E402
from backend import config  # noqa: E402
from analysis import sql_store, versioning  # noqa: E402

tok = {}
for label, uid in [("admin", "77577f56-356"), ("A", "f24b5ecf-f24"), ("B", "1eb6f941-ff5")]:
    t, *_ = auth.create_token(uid)
    tok[label] = t


def H(t):
    return {"Authorization": f"Bearer {t}"}


def get(path, t="admin"):
    return requests.get(BASE + path, headers=H(tok[t]), timeout=30)


def post(path, t="admin", body=None):
    return requests.post(BASE + path, headers=H(tok[t]), json=body or {}, timeout=60)


def delete(path, t="admin"):
    return requests.delete(BASE + path, headers=H(tok[t]), timeout=30)


def trash_items(t="admin"):
    r = get("/api/admin/versions/deleted", t)
    assert r.status_code == 200, f"list_deleted {r.status_code}: {r.text[:200]}"
    return {it["rel"]: it for it in r.json().get("items", [])}


def purge_rel(rel, t="admin"):
    r = delete("/api/admin/versions/deleted", t) if False else requests.delete(
        BASE + "/api/admin/versions/deleted", headers=H(tok[t]), json={"rel": rel}, timeout=30)
    return r


# ══ T1 回收站闭环 + purge 防护 ══
SQL1 = "__t1fix__.sql"
r = delete(f"/api/admin/sqls/{SQL1}")
r = post(f"/api/admin/sqls/{SQL1}", body={"sql": "select 1", "level": "通用"})
check("T1 保存 v1", r.status_code == 200 and r.json().get("ok"), f"HTTP {r.status_code}")
r = post(f"/api/admin/sqls/{SQL1}", body={"sql": "select 2", "level": "通用"})
check("T1 保存 v2", r.status_code == 200 and r.json().get("ok"), f"HTTP {r.status_code}")

# purge 防护：源仍在（未删）→ 404 且版本历史不丢（删除之前测）
r = purge_rel(f"sql/{SQL1}")
check("T1 purge 在用工件 404", r.status_code == 404, f"HTTP {r.status_code}")
r = get(f"/api/admin/versions?kind=sql&name={SQL1}")
check("T1 在用工件版本史仍在", r.status_code == 200 and len(r.json()["versions"]) >= 1,
      f"HTTP {r.status_code}")

r = delete(f"/api/admin/sqls/{SQL1}")
check("T1 删除", r.status_code == 200, f"HTTP {r.status_code}")
items = trash_items()
check("T1 回收站可见", f"sql/{SQL1}" in items, f"items={list(items)[:8]}")

# 恢复（联动 meta：恢复后 level 仍通用、meta json 回位）
r = post("/api/admin/versions/deleted/restore", body={"rel": f"sql/{SQL1}"})
check("T1 恢复", r.status_code == 200 and r.json().get("ok"), f"HTTP {r.status_code} {r.text[:200]}")
r = get(f"/api/admin/sqls/{SQL1}")
check("T1 恢复后 meta 联动", r.status_code == 200 and r.json().get("level") == "通用",
      f"HTTP {r.status_code} level={r.json().get('level') if r.status_code == 200 else '-'}")
from analysis import sql_store  # noqa: E402
check("T1 磁盘 meta json 回位", (sql_store.SQL_DIR / f"{SQL1}.json").is_file(), "")
check("T1 磁盘主件回位", (sql_store.SQL_DIR / SQL1).is_file(), "")

# 再删 → purge 成功
r = delete(f"/api/admin/sqls/{SQL1}")
r = purge_rel(f"sql/{SQL1}")
check("T1 purge 成功", r.status_code == 200 and r.json().get("removed", 0) >= 1,
      f"HTTP {r.status_code} {r.text[:200]}")
check("T1 purge 后镜像消失", not (versioning.VERSIONS_DIR / "sql" / SQL1).exists(), "")
purge_rel(f"sql/{SQL1}.json")  # 清理 meta 镜像行（历史运行残留一并清）

# purge 防护：中间目录 + 不存在条目
r = purge_rel("sql")
check("T1 purge 中间目录 404", r.status_code == 404, f"HTTP {r.status_code}")
from analysis import versioning  # noqa: E402
check("T1 中间目录树仍在", (versioning.VERSIONS_DIR / "sql").is_dir(), "")
r = purge_rel("sql/__no_such_artifact__.sql")
check("T1 purge 不存在条目 404", r.status_code == 404, f"HTTP {r.status_code}")

# ══ T2/T3 个人级隔离 + 恢复联动 meta ══
SQL2 = "__t2iso__.sql"
delete(f"/api/admin/sqls/{SQL2}", "A")
r = post(f"/api/admin/sqls/{SQL2}", "A", body={"sql": "select 3", "level": "个人"})
check("T2 A 存个人级", r.status_code == 200, f"HTTP {r.status_code} {r.text[:200]}")
r = delete(f"/api/admin/sqls/{SQL2}", "A")
check("T2 A 删除", r.status_code == 200, f"HTTP {r.status_code}")
items_b = trash_items("B")
check("T2 B 列表不含他人个人级", f"sql/{SQL2}" not in items_b, f"items={list(items_b)[:8]}")
r = post("/api/admin/versions/deleted/restore", "B", body={"rel": f"sql/{SQL2}"})
check("T2 B 恢复他人个人级 403", r.status_code == 403, f"HTTP {r.status_code}")
r = purge_rel(f"sql/{SQL2}", "B")
check("T2 B purge 他人个人级 403", r.status_code == 403, f"HTTP {r.status_code}")
# B 经 list_versions 枚举已删工件内容 → 403（镜像 owner 回溯）
r = get(f"/api/admin/versions?kind=sql&name={SQL2}", "B")
check("T2 B list_versions 他人个人级 403", r.status_code == 403, f"HTTP {r.status_code}")
r = post("/api/admin/versions/deleted/restore", "A", body={"rel": f"sql/{SQL2}"})
check("T2 A 恢复本人个人级", r.status_code == 200, f"HTTP {r.status_code} {r.text[:200]}")
r = get(f"/api/admin/sqls/{SQL2}", "A")
check("T3 恢复联动 meta 保个人级", r.status_code == 200 and r.json().get("level") == "个人",
      f"HTTP {r.status_code} level={r.json().get('level') if r.status_code == 200 else '-'}")
check("T3 恢复后 owner 未丢", r.status_code == 200 and bool(r.json().get("meta", {}).get("owner")), "")
r = get(f"/api/admin/versions?kind=sql&name={SQL2}", "B")
check("T2 B list_versions 恢复后仍 403", r.status_code == 403, f"HTTP {r.status_code}")
delete(f"/api/admin/sqls/{SQL2}", "A")
purge_rel(f"sql/{SQL2}", "A")
purge_rel(f"sql/{SQL2}.json", "A")

# ══ T4 rename 镜像残留预检 ══
S_A, S_B = "__t4a__.sql", "__t4b__.sql"
delete(f"/api/admin/sqls/{S_A}")
delete(f"/api/admin/sqls/{S_B}")
post(f"/api/admin/sqls/{S_A}", body={"sql": "select 4", "level": "通用"})
post(f"/api/admin/sqls/{S_B}", body={"sql": "select 5", "level": "通用"})
delete(f"/api/admin/sqls/{S_B}")
r = post("/api/admin/sqls/rename", body={"old": S_A, "new": S_B})
check("T4 残留未清时 rename 400", r.status_code == 400, f"HTTP {r.status_code} {r.text[:200]}")
check("T4 拦截后旧名原样", (sql_store.SQL_DIR / S_A).is_file(), "")
purge_rel(f"sql/{S_B}")
purge_rel(f"sql/{S_B}.json")
r = post("/api/admin/sqls/rename", body={"old": S_A, "new": S_B})
check("T4 清残留后 rename 成功", r.status_code == 200 and r.json().get("ok"),
      f"HTTP {r.status_code} {r.text[:200]}")
delete(f"/api/admin/sqls/{S_B}")
purge_rel(f"sql/{S_B}")

# ══ T5 聊天软删 trashed_at + 恢复自愈 ══
from backend.services import chat_history  # noqa: E402

r = post("/api/chat-history", "A", body={
    "title": "__t5fix__", "messages": [{"role": "user", "content": "hi"},
                                        {"role": "assistant", "content": "hello"}]})
check("T5 保存会话", r.status_code == 200, f"HTTP {r.status_code} {r.text[:200]}")
sid = r.json().get("id") or r.json().get("sid")
check("T5 拿到 sid", bool(sid), f"{r.text[:200]}")
r = delete(f"/api/chat-history/{sid}", "A")
check("T5 软删", r.status_code == 200, f"HTTP {r.status_code} {r.text[:200]}")
r = get("/api/chat-history/trash", "A")
trashed = [s for s in r.json().get("sessions", []) if s.get("id") == sid]
check("T5 回收站含 trashed_at", len(trashed) == 1 and bool(trashed[0].get("trashed_at")),
      f"trashed_at={trashed[0].get('trashed_at') if trashed else '-'}")
# 自愈：模拟「写回收站与删源两步间崩溃」双份残留（主目录复制一份回收站内容）
main_p = chat_history._path(sid)
trash_p = chat_history._trash_path(sid)
shutil.copy(trash_p, main_p)
r = post(f"/api/chat-history/{sid}/restore", "A")
check("T5 双份残留自愈恢复", r.status_code == 200, f"HTTP {r.status_code} {r.text[:200]}")
r = get(f"/api/chat-history/{sid}", "A")
check("T5 恢复后 trashed_at 已摘", r.status_code == 200 and "trashed_at" not in (r.json() or {}),
      f"HTTP {r.status_code}")
delete(f"/api/chat-history/{sid}", "A")
requests.delete(BASE + f"/api/chat-history/{sid}/purge", headers=H(tok["A"]), timeout=30)

# ══ T6 备份临时文件 ══
try:
    db_service.backup_db_daily()
    tmp_left = list(db_service.BACKUP_DIR.glob("*.db.tmp"))
    check("T6 每日备份后无 .db.tmp 残留", not tmp_left, f"tmp={[p.name for p in tmp_left]}")
except Exception as e:  # noqa: BLE001
    check("T6 每日备份调用不抛", False, f"{e}")

print("\n=== 汇总 ===")
failed = [r for r in results if not r[1]]
for name, ok, extra in results:
    if not ok:
        print("FAIL:", name, extra)
print(f"{len(results) - len(failed)}/{len(results)} PASS")
sys.exit(1 if failed else 0)
