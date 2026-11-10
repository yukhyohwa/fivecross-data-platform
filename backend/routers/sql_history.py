"""按 AI 会话存的 SQL 执行记录（SQL 编辑器「历史记录」侧栏）。

复用 ide_data.db（db_service._conn），每条记录绑定 user_id + game + session_id。
前端 SQL 编辑器用同一个 session_id 关联「AI·SQL编辑」对话与「历史记录」侧栏：
新建对话 → 换新 session_id → 历史跟着清空/切换。

只读落库，供 SQL 编辑器回放「这一轮对话里都执行了哪些 SQL」。
"""
from fastapi import APIRouter, Depends
from pydantic import BaseModel

from ..deps import get_current_user, get_game
from ..services.ide_bridge import anonymous_uid, db_service

router = APIRouter(prefix="/api/sql-history", tags=["sql_history"])

_TABLE = """
CREATE TABLE IF NOT EXISTS sql_exec_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    game TEXT NOT NULL DEFAULT '',
    session_id TEXT NOT NULL DEFAULT '',
    sql TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'ok',
    row_count INTEGER NOT NULL DEFAULT 0,
    duration_ms REAL NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
)
"""


def _conn():
    c = db_service._conn()
    c.execute(_TABLE)
    c.commit()
    return c


class HistoryRecord(BaseModel):
    session_id: str = ""
    sql: str
    status: str = "ok"
    row_count: int = 0
    duration_ms: float = 0


@router.get("")
def list_history(
    session_id: str | None = None,
    limit: int = 200,
    user=Depends(get_current_user),
    game=Depends(get_game),
):
    c = _conn()
    uid = anonymous_uid(user)
    if session_id:
        rows = c.execute(
            "SELECT id, session_id, game, sql, status, row_count, duration_ms, created_at "
            "FROM sql_exec_history WHERE user_id=? AND session_id=? ORDER BY id DESC LIMIT ?",
            (uid, session_id, int(limit)),
        ).fetchall()
    else:
        rows = c.execute(
            "SELECT id, session_id, game, sql, status, row_count, duration_ms, created_at "
            "FROM sql_exec_history WHERE user_id=? ORDER BY id DESC LIMIT ?",
            (uid, int(limit)),
        ).fetchall()
    return {"items": [dict(r) for r in rows]}


@router.post("")
def add_history(
    body: HistoryRecord,
    user=Depends(get_current_user),
    game=Depends(get_game),
):
    c = _conn()
    uid = anonymous_uid(user)
    cur = c.execute(
        "INSERT INTO sql_exec_history (user_id, game, session_id, sql, status, row_count, duration_ms) "
        "VALUES (?,?,?,?,?,?,?)",
        (uid, game.get("key", ""), body.session_id or "", body.sql, body.status, body.row_count, body.duration_ms),
    )
    c.commit()
    return {"id": cur.lastrowid}


@router.delete("")
def clear_history(session_id: str | None = None, user=Depends(get_current_user)):
    c = _conn()
    uid = anonymous_uid(user)
    if session_id:
        c.execute("DELETE FROM sql_exec_history WHERE user_id=? AND session_id=?", (uid, session_id))
    else:
        c.execute("DELETE FROM sql_exec_history WHERE user_id=?", (uid,))
    c.commit()
    return {"ok": True}
