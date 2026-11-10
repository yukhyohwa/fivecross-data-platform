"""算法模型接口：AI 生成预测/算法模型代码 + 静态安全预检 + 人审保存 + 动态注册。

模型 agent 的完整链路：
- POST /generate  AI 生成代码（不落盘、不执行），返回 {code, problems} 供预览与人审；
- POST /save     人审通过后，先 precheck_code 静态预检，再落盘 code/<名>.py + code/<名>.py.json；
- GET  /list     列出已保存的模型能力（含 manifest 元数据）；
- POST /reload    重扫 code/ 目录，动态注册进 forecast.PREDICTION_CAPABILITIES。

安全边界：代码绝不自动执行；保存仅做静态 AST 预检（只允许 numpy/pandas/math/datetime/json/re），
运行时由 chat.py 只读取数后调用 func(df_hist, pred_end)，无文件/网络/进程权限。
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..deps import get_current_user, get_game, require_analysis_edit, require_analysis_delete
from ..services import forecast
from ..services.llm import resolve_model_for_task
from analysis import code_store
from analysis import knowledge_store as ks
from analysis import model_gen
from analysis import sql_store
from analysis.games import visible_to, current_owner_key, owner_key
from analysis.snapshot import drifted, fingerprint

router = APIRouter(prefix="/api/admin/models", tags=["models"])


def _drift(sources: list[dict]) -> list[str]:
    """返回溯源里「源已改动」的源名列表（供模型页漂移徽标）。"""
    stale = []
    for s in sources or []:
        if not isinstance(s, dict):
            continue
        kind, name = s.get("kind"), (s.get("name") or "").strip()
        if not kind or not name:
            continue
        if kind == "sql":
            cur = sql_store.read_sql(name)
        elif kind == "doc":
            cur = ks.read_doc(name)
        elif kind == "model":
            cur = code_store.read_code(name)
        else:
            continue
        if drifted(s, cur):
            stale.append(name)
    return stale


class ModelGenerate(BaseModel):
    description: str
    bound_sql_names: list[str] = []
    doc_names: list[str] = []
    existing: str = ""  # 已有代码（编辑既有模型时回传，供在其基础上修改完善）
    model: str | None = None


class ModelSave(BaseModel):
    name: str
    code: str
    desc: str = ""
    input: str = "sql"          # sql=自动取数 | upload=离线上传（暂不支持）
    granularity: str = "day"    # day | month
    sql: str = ""               # 取数 SQL 名（input=sql 时必填）
    hist_days: int | None = None
    hist_months: int | None = None
    horizon_days: int | None = None
    horizon_months: int | None = None
    window: int | None = None
    level: str = "通用"
    sources: list[dict] = []    # 生成时借用的 SQL/知识库溯源 [{kind, name, fingerprint}]
    transformed_sqls: dict[str, str | None] = {}  # 生成时对绑定 SQL 改造的专属修改 SQL {sql名: 改造后SQL|None}


class ModelAssociate(BaseModel):
    description: str
    model: str | None = None


class ModelPlan(BaseModel):
    description: str = ""
    code: str = ""
    sql: str = ""
    model: str | None = None


class ModelRename(BaseModel):
    old: str
    new: str


@router.post("/rename")
def rename_model(body: ModelRename, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    """原子重命名模型（审计建议 7）：.py + manifest（.py.json）+ 冻结 SQL（.sql）+
    _versions 版本库一并迁移，替代前端「存新名+删旧名」。内置能力不可改名。"""
    try:
        if forecast.is_builtin(body.old):
            raise ValueError(f"「{body.old}」为内置能力，不可重命名")
        existing = code_store.read_code_meta(body.old)
        if not visible_to(existing.get("level"), existing.get("game"), game["key"], existing.get("owner"), current_owner_key()):
            raise ValueError(f"「{body.old}」属于其他游戏或用户，无权重命名")
        code_store.rename_code(body.old, body.new)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    forecast.load_external_capabilities()
    return {"ok": True, "old": body.old, "new": body.new}


@router.post("/generate")
def generate_model(body: ModelGenerate, user: dict = Depends(get_current_user), game=Depends(get_game)):
    """据自然语言描述 + 绑定 SQL 头部注释 + 知识库口径，生成模型代码（预览，不落盘）。"""
    model = resolve_model_for_task("model", user, body.model)
    try:
        result = model_gen.generate_model(
            model,
            body.description,
            body.bound_sql_names,
            body.doc_names,
            body.existing,
        )
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"AI 调用失败：{exc}")
    return {
        "code": result["code"],
        "problems": result["problems"],
        "sources": result["sources"],
        "transformed_sqls": result.get("transformed_sqls", {}),
    }


@router.post("/associate")
def associate_model(body: ModelAssociate, user: dict = Depends(get_current_user), game=Depends(get_game)):
    """据描述：挑最匹配的取数 SQL + 推断调度/窗口参数（不落盘，供前端回填草稿）。"""
    model = resolve_model_for_task("model", user, body.model)
    try:
        result = model_gen.associate_model(model, body.description, sql_store.list_sql_files(game["key"]))
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"AI 调用失败：{exc}")
    return result


@router.post("/save")
def save_model(body: ModelSave, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    """人审保存：先静态预检，通过后落盘 .py + .py.json manifest。"""
    problems = model_gen.precheck_code(body.code)
    if problems:
        raise HTTPException(status_code=400, detail="代码未通过安全预检：" + "；".join(problems))

    if body.input == "sql" and not body.sql.strip():
        raise HTTPException(status_code=400, detail="input=sql 时「取数 SQL 名」必填，否则无法自动取数")

    try:
        name = body.name.strip()
        if not name:
            raise ValueError("模型名不能为空")
        if forecast.is_builtin(name):
            raise ValueError(f"「{name}」为内置能力，不可覆盖；请换用其他模型名")
        existing = code_store.read_code_meta(name)
        if not visible_to(existing.get("level"), existing.get("game"), game["key"], existing.get("owner"), current_owner_key()):
            raise ValueError(f"「{name}」属于其他游戏或用户，无权覆盖")
        code_store.write_code(name, body.code)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    meta: dict = {
        "name": body.desc or name,
        "desc": body.desc,
        "input": body.input,
        "granularity": body.granularity,
        "sql": body.sql.strip(),
        "level": body.level,
        "game": game["key"] if body.level != "通用" else None,
        "owner": owner_key(user) if body.level == "个人" else None,
    }
    for k, v in {
        "hist_days": body.hist_days,
        "hist_months": body.hist_months,
        "horizon_days": body.horizon_days,
        "horizon_months": body.horizon_months,
        "window": body.window,
    }.items():
        if v is not None:
            meta[k] = v
    if body.sources:
        meta["sources"] = body.sources

    # 专属修改 SQL：取数 SQL 对应改造件落盘 code/<名>.sql；无改造则清除旧冻结件
    transformed = (body.transformed_sqls or {}).get(body.sql.strip())
    if transformed and transformed.strip():
        code_store.write_model_sql(name, transformed)
        meta["sql_transformed"] = True
        meta["sql_source"] = body.sql.strip()
    else:
        code_store.delete_model_sql(name)
        meta.pop("sql_transformed", None)

    code_store.write_code_meta(name, meta)
    forecast.load_external_capabilities()
    return {"ok": True, "name": name}


@router.post("/{name}/plan")
def plan_model_sql(name: str, body: ModelPlan, user: dict = Depends(get_current_user), game=Depends(get_game)):
    """据描述+代码+绑定 SQL，判断取数 SQL 是否需为模型改造并产出专属 SQL 草稿（不落盘，仅供预览）。"""
    sql_name = (body.sql or "").strip()
    if not sql_name:
        return {"transformed_sql": None, "sources": []}
    model = resolve_model_for_task("model", user, body.model)
    try:
        transformed = model_gen.transform_bound_sqls(model, body.description, body.code, [sql_name])
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"AI 调用失败：{exc}")
    sources = []
    orig = sql_store.read_sql(sql_name)
    if orig.strip():
        sources.append({"kind": "sql", "name": sql_name, "fingerprint": fingerprint(orig)})
    return {"transformed_sql": (transformed or {}).get(sql_name), "sources": sources}


@router.post("/{name}/refresh")
def refresh_model(name: str, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    """手动刷新模型专属取数 SQL 快照：重跑改造判断，漂移时重写 code/<名>.sql 并更新溯源指纹。"""
    meta = code_store.read_code_meta(name)
    if not meta:
        raise HTTPException(status_code=404, detail="模型不存在")
    if not visible_to(meta.get("level"), meta.get("game"), game["key"], meta.get("owner"), current_owner_key()):
        raise HTTPException(status_code=403, detail="该模型属于其他游戏或用户，无权刷新")

    sql_name = (meta.get("sql") or "").strip()
    if not sql_name:
        return {"ok": True, "name": name, "drift": _drift(meta.get("sources", []))}

    code = code_store.read_code(name)
    model = resolve_model_for_task("model", user)
    try:
        transformed = model_gen.transform_bound_sqls(model, meta.get("desc", ""), code, [sql_name])
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"AI 调用失败：{exc}")
    transformed_sql = (transformed or {}).get(sql_name)

    # 重算该取数 SQL 的溯源指纹，其余源（文档等）保留
    sources = [s for s in (meta.get("sources") or []) if not (isinstance(s, dict) and s.get("kind") == "sql" and s.get("name") == sql_name)]
    orig = sql_store.read_sql(sql_name)
    if orig.strip():
        sources.append({"kind": "sql", "name": sql_name, "fingerprint": fingerprint(orig)})
    meta["sources"] = sources

    if transformed_sql and transformed_sql.strip():
        code_store.write_model_sql(name, transformed_sql)
        meta["sql_transformed"] = True
        meta["sql_source"] = sql_name
    else:
        code_store.delete_model_sql(name)
        meta.pop("sql_transformed", None)

    code_store.write_code_meta(name, meta)
    forecast.load_external_capabilities()
    return {"ok": True, "name": name, "drift": _drift(meta.get("sources", []))}


@router.get("")
def list_models(game=Depends(get_game)):
    """列出全部模型能力：内置（forecast.py）+ 外部（code/*.py），含 manifest 元数据与静态预检状态。"""
    models = []
    for cap in forecast.list_builtin_capabilities():
        models.append({
            "name": cap["id"],
            "meta": {k: v for k, v in cap.items() if k != "id"},
            "problems": [],
            "source": "builtin",
        })
    for fname in code_store.list_code_manifests():
        bare = fname[:-3] if fname.endswith(".py") else fname
        meta = code_store.read_code_meta(bare)
        if not visible_to(meta.get("level"), meta.get("game"), game["key"], meta.get("owner"), current_owner_key()):
            continue
        code = code_store.read_code(bare)
        sources = meta.get("sources", []) if isinstance(meta, dict) else []
        models.append({
            "name": bare,
            "meta": meta,
            "problems": model_gen.precheck_code(code),
            "source": "external",
            "sources": sources,
            "drift": _drift(sources),
        })
    return {"models": models}


@router.get("/{name}")
def read_model(name: str, game=Depends(get_game)):
    """读取单个模型：代码 + manifest 元数据 + 静态预检结果。内置能力返回只读元数据。"""
    if forecast.is_builtin(name):
        cap = forecast.PREDICTION_CAPABILITIES[name]
        return {
            "name": name,
            "meta": {k: v for k, v in cap.items() if k != "func"},
            "code": "",
            "problems": [],
            "source": "builtin",
        }
    meta = code_store.read_code_meta(name)
    if not visible_to(meta.get("level"), meta.get("game"), game["key"], meta.get("owner"), current_owner_key()):
        raise HTTPException(status_code=403, detail="该模型属于其他游戏或用户，无权访问")
    code = code_store.read_code(name)
    sources = meta.get("sources", []) if isinstance(meta, dict) else []
    return {"name": name, "meta": meta, "code": code, "problems": model_gen.precheck_code(code), "source": "external",
            "sources": sources, "drift": _drift(sources), "model_sql": code_store.read_model_sql(name)}


@router.delete("/{name}")
def delete_model(name: str, user: dict = Depends(require_analysis_delete), game=Depends(get_game)):
    """删除模型（.py + .py.json），并即时从能力表移除。内置能力不可删除。"""
    if forecast.is_builtin(name):
        raise HTTPException(status_code=400, detail="内置能力不可删除")
    existing = code_store.read_code_meta(name)
    if not visible_to(existing.get("level"), existing.get("game"), game["key"], existing.get("owner"), current_owner_key()):
        raise HTTPException(status_code=403, detail="该模型属于其他游戏或用户，无权删除")
    try:
        code_store.delete_code(name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    forecast.load_external_capabilities()
    return {"ok": True}


@router.post("/reload")
def reload_models(user: dict = Depends(get_current_user)):
    """重扫 code/ 目录并动态注册进 forecast 能力表（删除/新增文件后即时生效）。"""
    loaded = forecast.load_external_capabilities()
    return {"ok": True, "loaded": list(loaded.keys())}
