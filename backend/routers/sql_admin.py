"""SQL 数据接口：sql/*.sql 的新增/编辑/删除 + 试运行 + 根据描述生成。复用 analysis/sql_store 的 CRUD。"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..deps import get_current_user, get_engine, get_game, require_analysis_edit, require_analysis_delete
from ..services import games, schema_context, sql_cache, sql_checks, sql_gen
from ..services.llm import LLMNotConfigured, resolve_model_for_task
from ..services.ide_bridge import db_service
from ..services.table import df_to_table
from analysis import sql_store
from analysis.games import visible_to, current_owner_key, owner_key
from analysis.db import run_raw_sql
from analysis.sql_rewriter import validate_sql
from analysis.snapshot import drifted

router = APIRouter(prefix="/api/admin/sqls", tags=["sql_admin"])


class SqlSave(BaseModel):
    sql: str
    meta: dict = {}
    level: str = sql_store.DEFAULT_SQL_LEVEL
    sources: list[dict] = []  # 生成时借用的知识库文档溯源 [{kind, name, fingerprint}]


class SqlRun(BaseModel):
    sql: str


class SqlGenerate(BaseModel):
    description: str
    model: str | None = None
    docs: list[str] = []
    existing: str = ""  # 已有 SQL（编辑既有 SQL 时回传，供在其基础上修改完善）


class SqlFormat(BaseModel):
    sql: str



@router.get("")
def list_sqls(game=Depends(get_game)):
    sqls = []
    for n in sql_store.list_sql_files(game["key"]):
        row = {"name": n, **sql_store.read_sql_meta(n), "level": sql_store.sql_level(n)}
        # 一拆多：一个 SQL 文件对应多条子指标（按 source_sql 反查）
        row["indicators"] = [
            {"id": i.get("id"), "metric_id": i.get("metric_id"),
             "metric_name": i.get("metric_name", ""), "status": i.get("status", "")}
            for i in db_service.get_indicators_by_source_sql(n)
        ]
        sqls.append(row)
    return {"sqls": sqls}


@router.post("/generate")
def generate_sql(body: SqlGenerate, user: dict = Depends(get_current_user), game=Depends(get_game)):
    """根据自然语言描述生成一条只读 SQL（供 SQL数据页「根据描述写 SQL」）。"""
    from analysis import knowledge_store as ks

    model = resolve_model_for_task("sql", user, body.model)
    engine = get_engine()
    schema_text, ref_docs, _src = schema_context.build_sql_context(
        engine, game["db"], game=game["key"], question=body.description, user=user
    )
    # 自动识别的口径文档 + 用户额外勾选的文档（去重）
    auto_names = {name for name, _ in ref_docs}
    doc_texts = ref_docs + [
        (d, ks.read_doc(d)) for d in body.docs if d in ks.list_docs(game["key"]) and d not in auto_names
    ]
    try:
        sql, raw = sql_gen.generate_sql(model, schema_text, body.description, doc_texts, existing=body.existing)
    except LLMNotConfigured:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"SQL 生成失败：{exc}")
    # 溯源：记录生成时借用的知识库文档（原样指纹），供保存时写入 sources + 页面漂移徽标
    from analysis.snapshot import provenance_entry
    sources = [provenance_entry("doc", name, content) for name, content in doc_texts if content.strip()]
    return {"sql": sql, "raw": raw, "sources": sources}


@router.post("/run")
def run_sql(body: SqlRun, user: dict = Depends(get_current_user), game=Depends(get_game)):
    # 只读护栏：试运行只允许 SELECT/WITH 查询，拒绝写语句 / 文件写出 / 多语句（防任意 SQL 执行）
    try:
        sql = validate_sql(body.sql)
    except ValueError as exc:
        return {"ok": False, "error": str(exc)}
    try:
        df = run_raw_sql(get_engine(), games.apply_sql(sql, game["db"]), max_rows=50000)
    except Exception as exc:
        return {"ok": False, "error": str(exc)}
    try:
        table = df_to_table(df)
    except Exception as exc:
        return {"ok": False, "error": f"结果转表格失败（可能含重复列名）：{exc}"}
    return {"ok": True, "table": table}


@router.post("/format")
def format_sql(body: SqlFormat):
    """SQL 格式化：关键字大写 + 缩进重排（编辑器「格式化」按钮）。"""
    import sqlparse
    formatted = sqlparse.format(
        body.sql, reindent=True, keyword_case='upper', use_space_around_operators=True
    )
    return {"ok": True, "sql": formatted}


class SqlRename(BaseModel):
    old: str
    new: str


@router.post("/rename")
def rename_sql(body: SqlRename, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    """原子重命名 SQL（审计建议 7）：主文件 + 元数据 + _versions 版本库一并迁移，
    并同步订阅引用与派生指标（source_sql/metric_id），替代前端「存新名+删旧名」。

    注意：本路由须声明在 /{name} 之前，否则「rename」会被当成 SQL 名捕获。
    """
    try:
        existing = sql_store.read_sql_meta(body.old)
        if not visible_to(existing.get("level"), existing.get("game"), game["key"], existing.get("owner"), current_owner_key()):
            raise HTTPException(status_code=403, detail=f"「{body.old}」属于其他游戏或用户，无权重命名")
        sql_store.rename_sql(body.old, body.new)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    # 派生指标同步（source_sql + 内嵌文件名的 metric_id）；失败不阻断主改名
    try:
        ind = db_service.rename_sql_indicators(body.old, body.new)
    except Exception as exc:  # noqa: BLE001
        return {"ok": True, "old": body.old, "new": body.new, "indicators": 0, "refs": 0,
                "ref_error": f"派生指标同步失败：{exc}"}
    # 订阅引用同步（sqls 列表）；失败不阻断主改名
    from ..services import subscriptions
    try:
        refs = subscriptions.rename_sql_refs(body.old, body.new)
    except Exception as exc:  # noqa: BLE001
        return {"ok": True, "old": body.old, "new": body.new, "indicators": ind, "refs": 0,
                "ref_error": str(exc)}
    sql_cache.invalidate(game["key"])
    return {"ok": True, "old": body.old, "new": body.new, "indicators": ind, "refs": refs}


@router.get("/{name}")
def read_sql(name: str, game=Depends(get_game)):
    try:
        meta = sql_store.read_sql_meta(name)
        if not visible_to(meta.get("level"), meta.get("game"), game["key"], meta.get("owner"), current_owner_key()):
            raise HTTPException(status_code=403, detail="该 SQL 属于其他游戏或用户，无权访问")
        sql = sql_store.read_sql(name)
        level = sql_store.sql_level(name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    from analysis import knowledge_store as ks
    sources = meta.get("sources", [])
    stale = [
        s.get("name") for s in sources
        if isinstance(s, dict) and s.get("kind") == "doc"
        and drifted(s, ks.read_doc(s.get("name") or ""))
    ]
    return {"name": name, "sql": sql, "meta": meta, "level": level, "game": meta.get("game"),
            "sources": sources, "drift": stale}


@router.post("/{name}")
def save_sql(name: str, body: SqlSave, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    try:
        existing = sql_store.read_sql_meta(name)
        if not visible_to(existing.get("level"), existing.get("game"), game["key"], existing.get("owner"), current_owner_key()):
            raise HTTPException(status_code=403, detail=f"「{name}」属于其他游戏或用户，无权覆盖")
        # 审计 P1-5：落盘前先过质量预检（validate_sql 只读闸门 + EXPLAIN 干跑）。
        # 预检失败不阻断保存（保持原保存行为不变），problems 随响应返回由前端警告展示，
        # 对齐算法模型的 problems 体验——执行路径另有只读闸门兜底。
        try:
            problems = sql_checks.precheck_sql(body.sql, get_engine(), game["db"])
        except Exception as exc:
            # 预检本身异常也不阻断保存，仅计入 problems
            problems = [f"保存预检执行失败：{exc}"]
        sql_store.write_sql(name, body.sql)
        # 审计 P2-15：SQL 资产写盘成功后按 game 失效 SQL 生成缓存，避免后续重复提问命中旧结果
        sql_cache.invalidate(game["key"])
        # 合并既有元数据：普通保存（body.meta 为空）不得清掉 sources/version/modifications/confidentiality
        # 等既有字段；body.meta 显式携带的键覆盖既有值（含显式置空）。
        meta = {**existing, **(body.meta or {})}
        level = sql_store.normalize_sql_level(body.level)
        meta["level"] = level
        meta["game"] = game["key"] if level != "通用" else None
        meta["owner"] = owner_key(user) if level == "个人" else None
        # 机密等级（L1/L2/L3 / 未分级）：只在 body.meta 显式携带时落盘，非法/空 → None（未分级）
        if "confidentiality" in meta:
            from backend.ide_app.services.permissions import normalize_confidentiality
            meta["confidentiality"] = normalize_confidentiality(meta.get("confidentiality"))
        if body.sources:
            meta["sources"] = body.sources
        if not meta.get("fields"):
            meta["fields"] = sql_store.fields_from_sql(body.sql)
        sql_store.write_sql_meta(name, meta)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    # problems：保存前质量预检结果（空列表 = 通过）；向后兼容——旧调用方按 ok/name 解析不受影响
    return {"ok": True, "name": name, "problems": problems}


@router.delete("/{name}")
def delete_sql(name: str, user=Depends(require_analysis_delete), game=Depends(get_game)):
    try:
        existing = sql_store.read_sql_meta(name)
        if not visible_to(existing.get("level"), existing.get("game"), game["key"], existing.get("owner"), current_owner_key()):
            raise HTTPException(status_code=403, detail=f"「{name}」属于其他游戏或用户，无权删除")
        sql_store.delete_sql(name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"ok": True}
