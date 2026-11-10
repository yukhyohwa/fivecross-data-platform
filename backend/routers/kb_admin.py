"""知识库接口：Skill / 文档的增删改 + AI 汇总生成 + XMind 解析 + 表结构知识库重建。复用 analysis/knowledge_store 的 CRUD。"""
import base64
import json

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..deps import get_current_user, get_game, require_analysis_edit, require_analysis_delete
from ..services import kb_summarize, table_schema, table_schema_gen, xmind_parse
from ..services.llm import LLMNotConfigured, resolve_model_for_task
from analysis import knowledge_store as ks
from analysis.games import visible_to, current_owner_key, owner_key

router = APIRouter(prefix="/api/admin/knowledge", tags=["kb_admin"])


class KbSave(BaseModel):
    content: str
    level: str = ks.DEFAULT_DOC_LEVEL
    confidentiality: str | None = None  # L1/L2/L3 机密档位；空 = 未分级


class SummarizeReq(BaseModel):
    model: str | None = None
    sources: list[dict]
    extra: str = ""
    existing: str = ""  # 已有文档内容（编辑既有文档时回传，供在其基础上修改完善）


class XmindParseReq(BaseModel):
    name: str
    data_b64: str


def _handlers(kind: str):
    if kind == "skills":
        return ks.list_skills, ks.read_skill, ks.write_skill, ks.delete_skill
    if kind == "docs":
        return ks.list_docs, ks.read_doc, ks.write_doc, ks.delete_doc
    raise HTTPException(status_code=404, detail=f"未知分类：{kind}")


def _kb_meta(kind: str, name: str) -> dict:
    return ks.read_skill_meta(name) if kind == "skills" else ks.read_doc_meta(name)


def _require_visible(kind: str, name: str, game_key: str, action: str = "访问"):
    """跨游戏/跨用户隔离：非通用知识库条目只对同族（family_key）可见；个人条目只对归属用户可见；跨族/跨人拒绝。"""
    meta = _kb_meta(kind, name)
    if not visible_to(meta.get("level"), meta.get("game"), game_key, meta.get("owner"), current_owner_key()):
        raise HTTPException(status_code=403, detail=f"「{name}」属于其他游戏或用户，无权{action}")


@router.get("/docs")
def list_docs_admin(game=Depends(get_game)):
    """知识库管理侧列表：只按 游戏/层级/归属 隔离，不做「知识库查询」权限点 + 机密档位过滤
    （那是聊天/Agent 取数口径，见 meta.knowledge / chat._visible_docs）。返回每篇文档的
    机密档位供管理页展示徽标。"""
    docs = ks.list_docs(game["key"])
    return {
        "docs": docs,
        "doc_levels": {n: ks.doc_level(n) for n in docs},
        "doc_confidentiality": {n: ks.read_doc_meta(n).get("confidentiality") for n in docs},
    }


@router.post("/summarize")
def summarize(body: SummarizeReq, user=Depends(get_current_user)):
    model = resolve_model_for_task("kb", user, body.model)
    try:
        draft, title = kb_summarize.summarize(model, body.sources, body.extra, body.existing)
    except LLMNotConfigured:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"AI 调用失败：{exc}")
    return {"draft": draft, "title": title}


@router.post("/parse-xmind")
def parse_xmind(body: XmindParseReq, user=Depends(get_current_user)):
    try:
        raw = base64.b64decode(body.data_b64)
        text = xmind_parse.parse(raw)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"解析失败：{exc}")
    return {"name": body.name, "text": text}


@router.get("/schema-status")
def schema_status(user=Depends(get_current_user)):
    """表结构知识库当前状态（只读，不重建、不建索引）。"""
    p = table_schema_gen.OUT_PATH
    if not p.exists():
        return {"exists": False, "path": str(p)}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        return {
            "exists": True,
            "path": str(p),
            "generated_at": data.get("generated_at"),
            "tables": len(data.get("tables") or []),
            "bytes": p.stat().st_size,
        }
    except Exception as exc:  # noqa: BLE001
        return {"exists": True, "path": str(p), "error": str(exc)}


@router.post("/rebuild-schema")
def rebuild_schema(user=Depends(require_analysis_edit)):
    """Retired: the old JoyTools/pf_ rebuild must never report success."""
    raise HTTPException(
        status_code=410,
        detail="旧表结构重建已停用；请从已验证 FiveCross schema manifest 离线生成。",
    )


class KbRename(BaseModel):
    kind: str
    old: str
    new: str


@router.post("/rename")
def rename_kb(body: KbRename, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    """原子重命名知识库文档（审计建议 7）：主文件 + 元数据 + _versions 版本库一并迁移，
    并同步订阅引用。专项改名走 /api/admin/skills/rename（含打包目录与笔记迁移）。
    """
    if body.kind != "docs":
        raise HTTPException(status_code=400, detail="仅文档支持改名（专项请走 /api/admin/skills/rename）")
    _require_visible(body.kind, body.old, game["key"], "重命名")
    try:
        ks.rename_doc(body.old, body.new)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    from ..services import subscriptions
    try:
        refs = subscriptions.rename_doc_refs(body.old, body.new)
    except Exception as exc:  # noqa: BLE001 —— 订阅迁移失败不阻断主改名
        return {"ok": True, "kind": body.kind, "old": body.old, "new": body.new, "refs": 0,
                "ref_error": str(exc)}
    return {"ok": True, "kind": body.kind, "old": body.old, "new": body.new, "refs": refs}


@router.get("/{kind}/{name}")
def read_kb(kind: str, name: str, user=Depends(get_current_user), game=Depends(get_game)):
    _, read_fn, _, _ = _handlers(kind)
    _require_visible(kind, name, game["key"])
    try:
        content = read_fn(name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    resp = {"kind": kind, "name": name, "content": content}
    if kind == "docs":
        resp["level"] = ks.doc_level(name)
        resp["confidentiality"] = ks.read_doc_meta(name).get("confidentiality")
    return resp


@router.post("/{kind}/{name}")
def save_kb(kind: str, name: str, body: KbSave, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    _, _, write_fn, _ = _handlers(kind)
    _require_visible(kind, name, game["key"], "覆盖")
    try:
        write_fn(name, body.content)
        if kind == "docs":
            level = ks.normalize_level(body.level)
            from backend.ide_app.services.permissions import normalize_confidentiality
            # 未显式传档位（不在 model_fields_set）→ 保留既有档位，避免清成未分级；显式传（含 null）按传值落盘
            if "confidentiality" not in body.model_fields_set:
                confidentiality = ks.read_doc_meta(name).get("confidentiality")
            else:
                confidentiality = normalize_confidentiality(body.confidentiality)
            ks.write_doc_meta(name, {
                "level": level,
                "game": game["key"] if level != "通用" else None,
                "owner": owner_key(user) if level == "个人" else None,
                "confidentiality": confidentiality,
            })
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"ok": True, "kind": kind, "name": name}


@router.delete("/{kind}/{name}")
def delete_kb(kind: str, name: str, user=Depends(require_analysis_delete), game=Depends(get_game)):
    _, _, _, delete_fn = _handlers(kind)
    _require_visible(kind, name, game["key"], "删除")
    try:
        delete_fn(name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"ok": True}
