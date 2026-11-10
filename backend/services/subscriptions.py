"""报告订阅存储：把「订阅」保存为 subscriptions/*.json。

一个订阅 = 报告模板：绑定专项（可选）+ 取数代码（SQL 文件名）+ 知识库文档，
订阅报告页里选起止日期即可重复生成报告（三模型流水线）并保存。
"""
import json
import re
import secrets
import time

from analysis.atomic import atomic_write_text

from .. import config

SUB_DIR = config.SUBSCRIPTION_DIR

_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")


def _ensure_dir():
    SUB_DIR.mkdir(parents=True, exist_ok=True)
    return SUB_DIR


def _validate_id(sid: str) -> str:
    if not _ID_RE.fullmatch(sid or ""):
        raise ValueError(f"非法订阅 id：{sid}")
    return sid


def _path(sid: str):
    return _ensure_dir() / f"{_validate_id(sid)}.json"


def new_id() -> str:
    return time.strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(4)


def _owner_of(rec: dict) -> str:
    """订阅未标 owner 的按 anonymous 归（向后兼容：旧数据仅匿名可见，不泄露他人）。"""
    return rec.get("owner") or "anonymous"


def save_subscription(data: dict, owner: str | None = None) -> dict:
    sid = data.get("id") or new_id()
    rec = {
        "id": sid,
        "name": (data.get("name") or "").strip() or "未命名订阅",
        "skill": data.get("skill") or None,
        "sqls": data.get("sqls") or [],
        "docs": data.get("docs") or [],
        "extra_prompt": data.get("extra_prompt") or "",
        "created_at": data.get("created_at") or time.strftime("%Y-%m-%d %H:%M:%S"),
        "source": data.get("source") or "manual",
        "game": data.get("game"),
        "owner": owner or data.get("owner") or "anonymous",
    }
    atomic_write_text(_path(sid), json.dumps(rec, ensure_ascii=False, indent=2), encoding="utf-8")
    return rec


def list_subscriptions(owner: str | None = None) -> list[dict]:
    out = []
    for p in _ensure_dir().glob("*.json"):
        try:
            rec = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        if owner and _owner_of(rec) != owner:
            continue
        out.append({
            "id": rec.get("id", p.stem),
            "name": rec.get("name", p.stem),
            "skill": rec.get("skill"),
            "sqls": rec.get("sqls", []),
            "docs": rec.get("docs", []),
            "extra_prompt": rec.get("extra_prompt", ""),
            "created_at": rec.get("created_at", ""),
            "source": rec.get("source", "manual"),
            "game": rec.get("game"),
        })
    out.sort(key=lambda r: r["created_at"], reverse=True)
    return out


def get_subscription(sid: str, owner: str | None = None) -> dict:
    p = _path(sid)
    if not p.exists():
        raise FileNotFoundError(sid)
    rec = json.loads(p.read_text(encoding="utf-8"))
    if owner and _owner_of(rec) != owner:
        raise PermissionError("无权访问该订阅")
    return rec


def delete_subscription(sid: str, owner: str | None = None) -> None:
    p = _path(sid)
    if not p.exists():
        return
    if owner and _owner_of(json.loads(p.read_text(encoding="utf-8"))) != owner:
        raise PermissionError("无权删除该订阅")
    p.unlink()


def rename_skill_refs(old: str, new: str) -> int:
    """专项改名后同步订阅引用（审计 P1-15）：把 skill=旧名 的订阅改成新名，避免改名后订阅断链。

    返回更新条数；原子写（atomic_write_text），单条失败抛错由调用方兜底。
    """
    updated = 0
    for p in _ensure_dir().glob("*.json"):
        try:
            rec = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        if rec.get("skill") != old:
            continue
        rec["skill"] = new
        save_subscription(rec, owner=rec.get("owner"))
        updated += 1
    return updated


def rename_sql_refs(old: str, new: str) -> int:
    """SQL 改名后同步订阅引用（审计建议 7）：sqls 列表里的旧名换成新名，避免订阅断链。"""
    updated = 0
    for p in _ensure_dir().glob("*.json"):
        try:
            rec = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        sqls = rec.get("sqls") or []
        if old not in sqls:
            continue
        rec["sqls"] = [new if s == old else s for s in sqls]
        save_subscription(rec, owner=rec.get("owner"))
        updated += 1
    return updated


def rename_doc_refs(old: str, new: str) -> int:
    """文档改名后同步订阅引用（审计建议 7）：docs 列表里的旧名换成新名，避免订阅断链。"""
    updated = 0
    for p in _ensure_dir().glob("*.json"):
        try:
            rec = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        docs = rec.get("docs") or []
        if old not in docs:
            continue
        rec["docs"] = [new if d == old else d for d in docs]
        save_subscription(rec, owner=rec.get("owner"))
        updated += 1
    return updated
