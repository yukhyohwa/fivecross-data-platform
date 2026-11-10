"""聊天记录接口：保存 / 查看 / 删除对话，并可一键让 AI 生成 知识库/专项/SQL/订阅报告。"""
import json
import re

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..deps import get_current_user, get_game
from ..services import chat_history, kb_summarize, sql_cache, subscriptions
from ..services.llm import LLMNotConfigured, resolve_model_for_task
from analysis.atomic import atomic_write_text
from analysis import knowledge_store as ks
from analysis import sql_store
from analysis import kb_gen
from analysis.games import owner_key

router = APIRouter(prefix="/api/chat-history", tags=["chat_history"])

_ILLEGAL = re.compile(r'[\\/:*?"<>|]')


class Msg(BaseModel):
    role: str
    # 单字段上限 100k 字符：防超长 text/sql/answer 撑满共享 HISTORY_DIR 的盘（超限由 Pydantic 直接 422 拒收）
    text: str = Field(default="", max_length=100_000)
    sql: str | None = Field(default=None, max_length=100_000)
    answer: str | None = Field(default=None, max_length=100_000)
    charts: list | None = None
    tables: list | None = None
    meta: dict | None = None  # 本轮命中来源 {source, skill}（如 source=model 时记录预测能力名）
    usage: dict | None = None  # 本轮 token 用量 {prompt_tokens, completion_tokens, total_tokens, cost}
    process: list | None = None  # 本轮「运行过程」步骤 [{time, text}]（各阶段耗时与说明，历史回放用）


class SaveReq(BaseModel):
    title: str | None = None
    messages: list[Msg] = Field(..., max_length=500)  # 单会话最多 500 条：防巨 body 撑盘并拖慢 list 全量加载
    usage: dict | None = None  # 会话累计 token 用量（前端会话结束/切页时回传）


class ToKbReq(BaseModel):
    model: str
    kind: str = "docs"  # docs | skills | sql | report
    extra: str = ""
    level: str = "通用"  # 仅 kind == "docs" 时使用：通用 / 项目 / 个人


class RenameReq(BaseModel):
    title: str


def _clean_title(title: str) -> str:
    return _ILLEGAL.sub("_", (title or "").strip()).strip()[:80] or "AI生成文档"


def _unique_name(name: str, existing: list[str]) -> str:
    if name not in existing:
        return name
    i = 2
    while f"{name}-{i}" in existing:
        i += 1
    return f"{name}-{i}"


@router.get("")
def list_sessions(q: str | None = None, limit: int = 30, offset: int = 0,
                  user=Depends(get_current_user)):
    """列出会话（saved_at 倒序分页）；q 非空时走搜索，不分页返回全部命中。"""
    sessions = chat_history.list_sessions(q, owner=owner_key(user))
    if q:
        return {"sessions": sessions, "total": len(sessions), "truncated": False}
    limit = max(1, min(limit, 100))
    offset = max(offset, 0)
    page = sessions[offset:offset + limit]
    return {"sessions": page, "total": len(sessions),
            "truncated": offset + len(page) < len(sessions)}


@router.post("")
def save_session(body: SaveReq, user=Depends(get_current_user)):
    messages = [m.model_dump() for m in body.messages]
    if not messages:
        raise HTTPException(status_code=400, detail="没有可保存的对话内容")
    # 标题入口先清洗截断再入库；空标题留 None 由服务层回落默认标题（rename 已有 [:40] 先例，保存用 80 兼容历史标题）
    title = _clean_title(body.title or "")[:80] if (body.title or "").strip() else None
    return chat_history.save_session(messages, title, body.usage, owner=owner_key(user))


@router.put("/{sid}")
def update_session(sid: str, body: SaveReq, user=Depends(get_current_user)):
    messages = [m.model_dump() for m in body.messages]
    if not messages:
        raise HTTPException(status_code=400, detail="没有可保存的对话内容")
    # 标题入口先清洗截断再入库（口径与 save 一致）；空标题留 None 由服务层回落默认标题
    title = _clean_title(body.title or "")[:80] if (body.title or "").strip() else None
    try:
        return chat_history.update_session(sid, messages, title, body.usage, owner=owner_key(user))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    # 非本人与不存在同 404 同文案，不泄露他人会话存在性（与 rename 同口径）
    except PermissionError:
        raise HTTPException(status_code=404, detail="会话不存在")


@router.put("/{sid}/rename")
def rename_session(sid: str, body: RenameReq, user=Depends(get_current_user)):
    """重命名会话标题；不存在与非本人一律 404 同文案，不泄露他人会话存在性。"""
    try:
        rec = chat_history.get_session(sid, owner=owner_key(user))
    except (FileNotFoundError, PermissionError):
        raise HTTPException(status_code=404, detail="会话不存在")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    raw = (body.title or "").strip()
    if not raw:
        raise HTTPException(status_code=400, detail="标题不能为空")
    title = _clean_title(raw)[:40]
    rec["title"] = title
    # 只改 title，其余原样写回：saved_at 不动，避免「最近聊天」因改名而重排
    atomic_write_text(chat_history.HISTORY_DIR / f"{sid}.json",
                      json.dumps(rec, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True, "title": title}


@router.get("/trash")
def list_trashed(user=Depends(get_current_user)):
    """回收站列表（建议 10）：软删的会话保留 30 天可恢复。注意须声明在 /{sid} 之前，
    否则「trash」会被当成会话 id 捕获。"""
    return {"sessions": chat_history.list_trashed(owner=owner_key(user))}


@router.get("/{sid}")
def get_session(sid: str, user=Depends(get_current_user)):
    try:
        return chat_history.get_session(sid, owner=owner_key(user))
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="会话不存在")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    # 非本人与不存在同 404 同文案，不泄露他人会话存在性（与 rename 同口径）
    except PermissionError:
        raise HTTPException(status_code=404, detail="会话不存在")


@router.delete("/{sid}")
def delete_session(sid: str, user=Depends(get_current_user)):
    try:
        chat_history.delete_session(sid, owner=owner_key(user))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    # 非本人与不存在同 404 同文案，不泄露他人会话存在性（与 rename 同口径）
    except PermissionError:
        raise HTTPException(status_code=404, detail="会话不存在")
    return {"ok": True}


@router.post("/{sid}/restore")
def restore_session(sid: str, user=Depends(get_current_user)):
    """回收站恢复（建议 10）：把软删会话移回正常列表（saved_at 刷新为现在，重新计入保留期）。"""
    try:
        chat_history.restore_session(sid, owner=owner_key(user))
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="回收站中不存在该会话")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except PermissionError:
        raise HTTPException(status_code=404, detail="回收站中不存在该会话")
    return {"ok": True}


@router.delete("/{sid}/purge")
def purge_session(sid: str, user=Depends(get_current_user)):
    """回收站彻底删除（不可恢复）。"""
    try:
        chat_history.purge_session(sid, owner=owner_key(user))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except PermissionError:
        raise HTTPException(status_code=404, detail="回收站中不存在该会话")
    return {"ok": True}


@router.post("/{sid}/to-kb")
def to_kb(sid: str, body: ToKbReq, user=Depends(get_current_user), game=Depends(get_game)):
    """两阶段第一步：AI 生成草稿并回传预览，**不落盘**；用户确认后经 /to-kb/confirm 保存。"""
    if body.kind not in ("docs", "skills", "sql", "report"):
        raise HTTPException(status_code=400, detail="kind 只能是 docs / skills / sql / report")
    try:
        rec = chat_history.get_session(sid, owner=owner_key(user))
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="会话不存在")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    # 非本人与不存在同 404 同文案，不泄露他人会话存在性（与 rename 同口径）
    except PermissionError:
        raise HTTPException(status_code=404, detail="会话不存在")

    messages = rec["messages"]
    game_key = game["key"]
    # P1-4：与其它生成入口同口径，经任务→模型/温度单一入口（kb=知识库摘要生成，结构化）
    model = resolve_model_for_task("kb", user, body.model)

    try:
        if body.kind == "sql":
            sql_text = kb_summarize.summarize_to_sql(model, messages, body.extra)
            base = _clean_title(rec.get("title") or "AI生成SQL").removesuffix(".sql")
            name = _unique_name(base, [n[: -len(".sql")] for n in sql_store.list_sql_files(game_key)])
            fields = kb_gen.annotate_fields(model, sql_text, sql_store.fields_from_sql(sql_text))
            return {"ok": True, "phase": "draft", "kind": "sql", "name": name + ".sql",
                    "draft": sql_text, "fields": fields}

        if body.kind == "report":
            cfg = kb_summarize.summarize_to_subscription(model, messages)
            # 过滤到真实存在的专项/文档/SQL 引用（仅预览；确认时再过滤一次，防落盘期间引用被删）
            skill = cfg.get("skill") if cfg.get("skill") in ks.list_online_skills(game_key) else None
            sqls = [s for s in (cfg.get("sqls") or []) if s in sql_store.list_sql_files(game_key)]
            docs = [d for d in (cfg.get("docs") or []) if d in ks.list_docs(game_key)]
            return {"ok": True, "phase": "draft", "kind": "report",
                    "subscription": {
                        "name": cfg.get("name") or "AI订阅",
                        "skill": skill,
                        "sqls": sqls,
                        "docs": docs,
                        "extra_prompt": cfg.get("extra_prompt") or "",
                    }}

        draft, title = kb_summarize.summarize_chat(model, messages, body.kind, body.extra)
    except LLMNotConfigured:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"AI 调用失败：{exc}")

    name = _clean_title(title)
    existing = ks.list_skills(game_key) if body.kind == "skills" else ks.list_docs(game_key)
    name = _unique_name(name, existing)
    return {"ok": True, "phase": "draft", "kind": body.kind, "name": name, "title": title, "draft": draft}


class ToKbConfirmReq(BaseModel):
    kind: str  # docs | skills | sql | report
    model: str = ""
    name: str = ""
    title: str = ""
    draft: str = ""
    fields: list = []
    subscription: dict = {}


@router.post("/to-kb/confirm")
def to_kb_confirm(body: ToKbConfirmReq, user=Depends(get_current_user), game=Depends(get_game)):
    """两阶段第二步：把第一步预览确认过的草稿落盘。

    写入口闸门：docs/skills/sql 需 analysis_edit（与各管理页保存同口径）；report（订阅）沿用订阅接口口径。
    """
    from backend.ide_app.services.permissions import has_perm

    if body.kind not in ("docs", "skills", "sql", "report"):
        raise HTTPException(status_code=400, detail="kind 只能是 docs / skills / sql / report")
    if body.kind != "report" and not has_perm(user, "analysis_edit"):
        raise HTTPException(status_code=403, detail="仅可查看：无「新增/修改」专项·知识库·SQL·算法 的权限")
    if not (body.draft or "").strip() and body.kind != "report":
        raise HTTPException(status_code=400, detail="草稿内容为空")

    game_key = game["key"]

    if body.kind == "sql":
        sql_text = body.draft.strip()
        base = _clean_title(body.name or body.title or "AI生成SQL").removesuffix(".sql")
        name = _unique_name(base, [n[: -len(".sql")] for n in sql_store.list_sql_files(game_key)])
        fields = body.fields or []
        if not fields and body.model:
            try:
                fields = kb_gen.annotate_fields(body.model, sql_text, sql_store.fields_from_sql(sql_text))
            except Exception:
                fields = []
        sql_store.write_sql(name + ".sql", sql_text)
        # 审计 P2-15：SQL 草稿确认落盘后按 game 失效 SQL 生成缓存，避免重复提问命中旧结果
        sql_cache.invalidate(game_key)
        sql_store.write_sql_meta(name + ".sql", {"modifications": [], "level": "个人", "game": None, "fields": fields, "owner": owner_key(user)})
        return {"ok": True, "kind": "sql", "name": name + ".sql"}

    if body.kind == "report":
        cfg = body.subscription or {}
        skill = cfg.get("skill") if cfg.get("skill") in ks.list_online_skills(game_key) else None
        sqls = [s for s in (cfg.get("sqls") or []) if s in sql_store.list_sql_files(game_key)]
        docs = [d for d in (cfg.get("docs") or []) if d in ks.list_docs(game_key)]
        rec2 = subscriptions.save_subscription({
            "name": cfg.get("name") or "AI订阅",
            "skill": skill,
            "sqls": sqls,
            "docs": docs,
            "extra_prompt": cfg.get("extra_prompt") or "",
            "source": "chat",
            "game": game_key,
        }, owner=owner_key(user))
        return {"ok": True, "kind": "report", "subscription": rec2}

    name = _clean_title(body.name or body.title)
    if not name:
        raise HTTPException(status_code=400, detail="缺少名称")
    existing = ks.list_skills(game_key) if body.kind == "skills" else ks.list_docs(game_key)
    name = _unique_name(name, existing)
    write_fn = ks.write_skill if body.kind == "skills" else ks.write_doc
    write_fn(name, body.draft)
    # 审计 P2-15：知识库/专项落盘会改变 SQL 生成的口径输入，同样按 game 失效生成缓存
    sql_cache.invalidate(game_key)
    if body.kind == "docs":
        # 需求：聊天/历史提炼出的知识只进个人知识库
        ks.write_doc_meta(name, {
            "level": ks.normalize_level("个人"),
            "game": None,
            "owner": owner_key(user),
        })
    elif body.kind == "skills":
        # 需求：聊天/历史制作的专项只进个人专项；新建默认下线（调试确认后再到专项管理手动上线）
        ks.write_skill_meta(name, {"sqls": [], "docs": [], "level": ks.normalize_skill_level("个人"), "game": None, "owner": owner_key(user), "online": False})
    return {"ok": True, "kind": body.kind, "name": name}
