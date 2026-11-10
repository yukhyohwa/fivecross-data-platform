"""聊天记录存储：把每次对话保存为 chat_history/*.json，供「AI 生成知识库」复用。

软删（建议 10，2026-10-21）：删除改为移入 chat_history/trash/ 子目录（glob("*.json")
天然隔离回收站），30 天后才彻底删除；误删可在回收站恢复。
"""
import datetime
import json
import re
import secrets
import time
from pathlib import Path

from analysis.atomic import atomic_write_text

from .. import config

HISTORY_DIR = config.CHAT_HISTORY_DIR
TRASH_DIR = HISTORY_DIR / "trash"

_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")

# 缓存聊天仅保留最近 N 天，超过则自动清理
RETENTION_DAYS = 7

# 回收站保留 N 天（与版本库 30 天一致），超期彻底删除
TRASH_RETENTION_DAYS = 30


def _ensure_dir() -> Path:
    HISTORY_DIR.mkdir(parents=True, exist_ok=True)
    return HISTORY_DIR


def _trash_dir() -> Path:
    TRASH_DIR.mkdir(parents=True, exist_ok=True)
    return TRASH_DIR


def _validate_id(sid: str) -> str:
    if not _ID_RE.fullmatch(sid or ""):
        raise ValueError(f"非法会话 id：{sid}")
    return sid


def _path(sid: str) -> Path:
    return _ensure_dir() / f"{_validate_id(sid)}.json"


def _trash_path(sid: str) -> Path:
    return _trash_dir() / f"{_validate_id(sid)}.json"


def _default_title(messages: list[dict]) -> str:
    for m in messages:
        if m.get("role") == "user" and (m.get("text") or "").strip():
            return m["text"].strip()[:40]
    return "未命名对话"


def new_id() -> str:
    return time.strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(4)


def _owner_of(rec: dict) -> str:
    """历史记录未标 owner 的按 anonymous 归（向后兼容：旧数据仅匿名可见，不泄露他人）。"""
    return rec.get("owner") or "anonymous"


def save_session(messages: list[dict], title: str | None = None, usage: dict | None = None,
                 owner: str | None = None) -> dict:
    prune_old_sessions()
    sid = new_id()
    rec = {
        "id": sid,
        "title": (title or "").strip() or _default_title(messages),
        "saved_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "messages": messages,
        "owner": owner or "anonymous",
    }
    if usage:
        rec["usage"] = usage
    atomic_write_text(_path(sid), json.dumps(rec, ensure_ascii=False, indent=2), encoding="utf-8")
    return rec


def update_session(sid: str, messages: list[dict], title: str | None = None, usage: dict | None = None,
                   owner: str | None = None) -> dict:
    p = _path(sid)
    if not p.exists():
        raise ValueError("会话不存在")
    existing = json.loads(p.read_text(encoding="utf-8"))
    if owner and _owner_of(existing) != owner:
        raise PermissionError("无权修改该会话")
    rec = {
        "id": sid,
        "title": (title or "").strip() or _default_title(messages),
        "saved_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "messages": messages,
        "owner": owner or _owner_of(existing),
    }
    if usage:
        rec["usage"] = usage
    atomic_write_text(p, json.dumps(rec, ensure_ascii=False, indent=2), encoding="utf-8")
    return rec


def prune_old_sessions(days: int = RETENTION_DAYS) -> int:
    """删除 saved_at 早于 days 天的会话文件，返回删除数量。"""
    cutoff = time.time() - days * 86400
    removed = 0
    for p in _ensure_dir().glob("*.json"):
        try:
            rec = json.loads(p.read_text(encoding="utf-8"))
            dt = datetime.datetime.strptime(rec.get("saved_at", ""), "%Y-%m-%d %H:%M:%S")
            if dt.timestamp() < cutoff:
                p.unlink()
                removed += 1
        except Exception:
            continue
    return removed


def _messages_text(messages: list[dict]) -> str:
    """把会话消息拼成可全文检索的文本（用户问题 + AI 回答 + SQL）。"""
    parts = []
    for m in messages or []:
        for k in ("text", "answer", "sql"):
            v = m.get(k)
            if isinstance(v, str) and v.strip():
                parts.append(v)
    return " ".join(parts)


def list_sessions(q: str | None = None, owner: str | None = None) -> list[dict]:
    """列出会话；q 非空时按标题 + 消息全文做大小写不敏感的包含过滤；owner 非空时仅返回本人会话。"""
    prune_old_sessions()
    kw = (q or "").strip().lower()
    out = []
    for p in _ensure_dir().glob("*.json"):
        try:
            rec = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        if owner and _owner_of(rec) != owner:
            continue
        if kw:
            hay = " ".join([rec.get("title", ""), _messages_text(rec.get("messages", []))]).lower()
            if kw not in hay:
                continue
        out.append({
            "id": rec.get("id", p.stem),
            "title": rec.get("title", p.stem),
            "saved_at": rec.get("saved_at", ""),
            "message_count": len(rec.get("messages", [])),
            "usage": rec.get("usage"),
        })
    out.sort(key=lambda r: r["saved_at"], reverse=True)
    return out


def get_session(sid: str, owner: str | None = None) -> dict:
    p = _path(sid)
    if not p.exists():
        raise FileNotFoundError(sid)
    rec = json.loads(p.read_text(encoding="utf-8"))
    if owner and _owner_of(rec) != owner:
        raise PermissionError("无权访问该会话")
    return rec


def delete_session(sid: str, owner: str | None = None) -> None:
    """软删（建议 10）：移入 chat_history/trash/ 子目录，30 天后才彻底删除。

    list_sessions 的 glob("*.json") 不扫子目录，回收站与正常列表天然隔离；
    误删可经 restore_session 恢复。
    """
    p = _path(sid)
    if not p.exists():
        return
    rec = json.loads(p.read_text(encoding="utf-8"))
    if owner and _owner_of(rec) != owner:
        raise PermissionError("无权删除该会话")
    rec["trashed_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    dst = _trash_path(sid)
    if dst.exists():
        # 同名已在回收站（旧软删遗留）：仅同归属人可覆盖，防他人同名会话被顺手清掉（对抗审查）
        old = json.loads(dst.read_text(encoding="utf-8"))
        if _owner_of(old) != _owner_of(rec):
            raise PermissionError("回收站已有同名会话，无权覆盖")
        dst.unlink()
    # 先写回收站、再删源（对抗审查）：写失败不丢源；两步间崩溃最多产生双份，
    # restore_session 对同归属人双份自愈。
    atomic_write_text(dst, json.dumps(rec, ensure_ascii=False, indent=2), encoding="utf-8")
    p.unlink()


def prune_trash(days: int = TRASH_RETENTION_DAYS) -> int:
    """回收站保留期清理：删除进入回收站（trashed_at，进入回收站时刻）早于 days 天的
    会话；老条目无 trashed_at 字段时按文件 mtime 兜底。返回删除数量。"""
    cutoff = time.time() - days * 86400
    removed = 0
    for p in _trash_dir().glob("*.json"):
        try:
            ts = None
            try:
                rec = json.loads(p.read_text(encoding="utf-8"))
                raw = rec.get("trashed_at")
                if raw:
                    ts = time.mktime(time.strptime(raw, "%Y-%m-%d %H:%M:%S"))
            except (json.JSONDecodeError, ValueError, OSError):
                pass
            if ts is None:
                ts = p.stat().st_mtime  # 老条目兜底：mtime ≈ 写入回收站时刻
            if ts < cutoff:
                p.unlink()
                removed += 1
        except OSError:
            continue
    return removed


def list_trashed(owner: str | None = None) -> list[dict]:
    """回收站列表（建议 10）；owner 非空时仅返回本人会话。顺带做保留期清理。"""
    prune_trash()
    out = []
    for p in _trash_dir().glob("*.json"):
        try:
            rec = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        if owner and _owner_of(rec) != owner:
            continue
        out.append({
            "id": rec.get("id", p.stem),
            "title": rec.get("title", p.stem),
            "saved_at": rec.get("saved_at", ""),
            "trashed_at": rec.get("trashed_at", ""),
            "message_count": len(rec.get("messages", [])),
        })
    out.sort(key=lambda r: r["saved_at"], reverse=True)
    return out


def restore_session(sid: str, owner: str | None = None) -> None:
    """回收站恢复：从 trash/ 移回主目录，并把 saved_at 更新为现在——
    主目录保留期 7 天按 mtime 之外的时间算（prune 读 saved_at），不刷新会
    刚恢复就被 prune_old_sessions 再次清掉。

    主目录已有同名会话时（对抗审查）：同归属人视为「源与回收站双份」崩溃残留
    （delete_session 写回收站与删源两步间崩溃），回收站份作废继续恢复；
    不同归属人抛错，防覆盖他人会话。
    """
    p = _trash_path(sid)
    if not p.exists():
        raise FileNotFoundError(sid)
    rec = json.loads(p.read_text(encoding="utf-8"))
    if owner and _owner_of(rec) != owner:
        raise PermissionError("无权恢复该会话")
    dst = _path(sid)
    if dst.exists():
        old = json.loads(dst.read_text(encoding="utf-8"))
        if _owner_of(old) != _owner_of(rec):
            raise ValueError("同名会话已存在，无法恢复")
        dst.unlink()  # 崩溃残留自愈：与回收站份同归属同内容，删残余后继续
    rec.pop("trashed_at", None)
    rec["saved_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    atomic_write_text(dst, json.dumps(rec, ensure_ascii=False, indent=2), encoding="utf-8")
    p.unlink()


def purge_session(sid: str, owner: str | None = None) -> None:
    """回收站彻底删除（不可恢复）。"""
    p = _trash_path(sid)
    if not p.exists():
        return
    if owner and _owner_of(json.loads(p.read_text(encoding="utf-8"))) != owner:
        raise PermissionError("无权删除该会话")
    p.unlink()
