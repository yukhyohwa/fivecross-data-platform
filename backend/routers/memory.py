"""记忆管理 API（P4 融合）：data_ai 侧一等公民接口，复用 ide_backend 的 agent_memory 表。

与 /ide 子应用共享同一份 ide_data.db（同一 agent_memory 表、同一 user_id），
区别仅在于鉴权用 data_ai 的 get_current_user（匿名回落），前端可直接匿名使用。
"""
from datetime import datetime
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..deps import get_current_user
from ..services.ide_bridge import MemoryManager, anonymous_uid, db_service
from .. import config

router = APIRouter(prefix="/api/memory", tags=["memory"])


class MemoryCreate(BaseModel):
    content: str
    category: str = "data_note"
    scope: str = "private"  # "private" | "global"
    mem_type: str = "日常"  # 记忆增强：日常|专项|SQL|知识库|算法
    bind_name: str = ""     # 记忆增强：绑定的资产名（日常为空）


class MemoryUpdate(BaseModel):
    content: Optional[str] = None
    category: Optional[str] = None
    scope: Optional[str] = None
    mem_type: Optional[str] = None
    bind_name: Optional[str] = None


class ShareMemoryBody(BaseModel):
    ids: List[int]
    target_user_ids: List[str]


class ImportRequest(BaseModel):
    items: List[dict] = []


@router.get("")
def list_memories(
    scope: Optional[str] = None,
    category: Optional[str] = None,
    user: dict = Depends(get_current_user),
):
    uid = anonymous_uid(user)
    items = db_service.get_memories(user_id=uid, scope=scope or "private", category=category)
    return {"items": items}


@router.get("/search")
def search_memories_route(
    keyword: str,
    scope: Optional[str] = None,
    user: dict = Depends(get_current_user),
):
    uid = anonymous_uid(user)
    items, total = db_service.search_memories(user_id=uid, keyword=keyword, scope=scope)
    return {"items": items, "total": total}


@router.post("")
def create_memory_route(body: MemoryCreate, user: dict = Depends(get_current_user)):
    uid = anonymous_uid(user)
    memory_id = db_service.create_memory(
        user_id=uid, scope=body.scope, category=body.category,
        content=body.content, source="manual",
        mem_type=body.mem_type, bind_name=body.bind_name,
    )
    return {"id": memory_id, "message": "记忆已保存"}


@router.put("/{memory_id}")
def update_memory_route(memory_id: int, body: MemoryUpdate, user: dict = Depends(get_current_user)):
    uid = anonymous_uid(user)
    mem = db_service.get_memory_by_id(memory_id)
    if not mem or mem["user_id"] != uid:
        raise HTTPException(status_code=403, detail="无权修改该记忆")
    db_service.update_memory(memory_id, content=body.content, category=body.category, scope=body.scope,
                             mem_type=body.mem_type, bind_name=body.bind_name)
    return {"message": "记忆已更新"}


@router.delete("/{memory_id}")
def delete_memory_route(memory_id: int, user: dict = Depends(get_current_user)):
    uid = anonymous_uid(user)
    mem = db_service.get_memory_by_id(memory_id)
    if not mem or mem["user_id"] != uid:
        raise HTTPException(status_code=403, detail="无权删除该记忆")
    db_service.delete_memory(memory_id)
    return {"message": "记忆已删除"}


# ── 供深度分析 Agent 调用的轻量端点（也可被前端复用）──

@router.get("/context")
def memory_context(
    user_input: str = "",
    user: dict = Depends(get_current_user),
):
    """返回注入 system prompt 的记忆片段（深度分析 Agent 启动时使用）。"""
    uid = anonymous_uid(user)
    text = MemoryManager.build_memory_context(uid, user_input)
    return {"context": text}


@router.post("/hit/{memory_id}")
def hit_memory(memory_id: int):
    """命中一次记忆（hit_count + 1），供 Agent 检索命中后调用。"""
    db_service.increment_memory_hit(memory_id)
    return {"message": "ok"}


# ── Import/Export ──

@router.get("/export")
def export_memories(
    ids: str = "",
    scope: Optional[str] = None,
    category: Optional[str] = None,
    user: dict = Depends(get_current_user),
):
    uid = anonymous_uid(user)
    id_list = [int(x.strip()) for x in ids.split(",") if x.strip()] if ids else None
    if id_list is not None and not id_list:
        raise HTTPException(status_code=400, detail="ids 参数格式错误")

    if id_list:
        items = db_service.get_memories_by_ids(uid, id_list)
    else:
        items = db_service.get_memories(user_id=uid, scope=scope or "private", category=category)
        strip_keys = {"id", "user_id", "key", "source", "hit_count", "created_at", "updated_at"}
        for item in items:
            for k in strip_keys:
                item.pop(k, None)

    return {
        "type": "memories",
        "version": 1,
        "exported_at": datetime.utcnow().isoformat() + "Z",
        "count": len(items),
        "items": items,
    }


@router.post("/import")
def import_memories(body: ImportRequest, user: dict = Depends(get_current_user)):
    uid = anonymous_uid(user)
    if len(body.items) > 200:
        raise HTTPException(status_code=400, detail="单次导入最多 200 条")
    created = 0
    errors = []
    for idx, item in enumerate(body.items):
        try:
            scope = item.get("scope", "private")
            if scope not in ("private", "global"):
                scope = "private"
            content = str(item.get("content") or "").strip()[:4000]
            if not content:
                # 对抗验证 2026-10-21：空内容入库产生永不得分的空行，占召回池名额——计入 errors
                raise ValueError("内容为空")
            db_service.create_memory(
                user_id=uid,
                scope=scope,
                category=item.get("category", "data_note"),
                content=content,
                source="import",
                mem_type=item.get("mem_type", "日常"),
                bind_name=item.get("bind_name", ""),
            )
            created += 1
        except Exception as e:  # noqa: BLE001 —— 部分成功模式
            errors.append({"index": idx, "error": str(e)})
    return {"created": created, "errors": errors, "total": len(body.items)}


@router.post("/share")
def share_memories(body: ShareMemoryBody, user: dict = Depends(get_current_user)):
    """复制记忆到目标用户（记忆只做复制，不做引用）。

    安全（对抗审查 2026-10-21）：目标用户必须真实存在且数量受限；
    共享记忆剥离 bind_name——资产绑定是共享者私有的资产关联，复制过去
    会借 bind 命中 +4 恒进对方召回 top10，构成跨用户提示注入放大面。
    对抗验证 2026-10-21 收口：ids 去重防重复副本挤占；生产鉴权模式
    （AUTH_ENABLED=true）下未登录的匿名分享一律拒绝。
    """
    uid = anonymous_uid(user)
    if config.auth_enabled() and uid == "anonymous":
        # 生产模式未认证用户无真实身份，向真实用户分享构成提示注入通道
        raise HTTPException(status_code=403, detail="请先登录后再分享记忆")
    # 去重 + 上限 20 + 存在性校验（users 表）
    targets = [t for t in dict.fromkeys(body.target_user_ids) if t and t != uid][:20]
    valid_targets = [t for t in targets if db_service.get_user_by_id(t)]
    received_targets = set()
    count = 0
    for target_uid in valid_targets:
        for mid in dict.fromkeys(body.ids[:200]):
            mem = db_service.get_memory_by_id(mid)
            if not mem or mem["user_id"] != uid:
                continue
            db_service.create_memory(
                user_id=target_uid, scope=mem["scope"], category=mem["category"],
                content=mem["content"], source="shared",
                mem_type=mem.get("mem_type", "日常"), bind_name="",
            )
            count += 1
            received_targets.add(target_uid)
    return {"shared": count, "targets": len(received_targets)}
