"""专项（Skill）接口：一个专项 = 方法说明 + 关联的取数代码（SQL）与知识库文档。

复用 analysis/knowledge_store 的 skill 内容 CRUD；关联关系存 knowledge/skills/*.json。
"""
import difflib
import threading

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from .. import config
from ..deps import get_current_user, get_engine, get_game, require_analysis_edit, require_analysis_delete
from ..services import forecast, kb_summarize, schema_context, skill_bundle, subscriptions
from ..services.llm import LLMNotConfigured, complete_with_fallback, resolve_model_for_task
from analysis import kb_gen, skill_plan
from analysis import knowledge_store as ks
from analysis import sql_store
from analysis import code_store
from analysis.games import visible_to, current_owner_key, owner_key
from analysis.ai_client import INTERACTIVE_MAX_TOKENS
from analysis.sql_rewriter import rewrite_sql
from analysis.snapshot import fingerprint

router = APIRouter(prefix="/api/admin/skills", tags=["skills"])


def _require_visible(name: str, game_key: str, action: str = "访问"):
    """跨游戏/跨用户隔离：非通用专项只对同族（family_key）可见；个人专项只对归属用户可见；跨族/跨人拒绝。"""
    meta = ks.read_skill_meta(name)
    if not visible_to(meta.get("level"), meta.get("game"), game_key, meta.get("owner"), current_owner_key()):
        raise HTTPException(status_code=403, detail=f"专项「{name}」属于其他游戏或用户，无权{action}")


class SkillRename(BaseModel):
    old: str
    new: str


@router.post("/rename")
def rename_skill(body: SkillRename, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    """原子重命名专项（审计 P1-15）：主文件/目录打包 + 元数据 + 笔记 + _versions 版本库一并迁移，
    订阅引用同步改名——替代前端「先存新名再删旧名」（删失败会静默丢版本/快照历史）。

    注意：本路由须声明在 /{name} 之前，否则「rename」会被当成专项名捕获。
    """
    _require_visible(body.old, game["key"], "重命名")
    try:
        ks.rename_skill(body.old, body.new)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    try:
        refs = subscriptions.rename_skill_refs(body.old, body.new)
    except Exception as exc:  # noqa: BLE001 —— 订阅迁移失败不阻断主改名，但要回给调用方
        return {"ok": True, "old": body.old, "new": body.new,
                "warning": f"订阅引用迁移失败（{exc}），请到订阅报告页手动更新"}
    return {"ok": True, "old": body.old, "new": body.new, "subscriptions_updated": refs}


def _fallback_prov(key: str, content: str) -> dict:
    """为「保留现有快照但溯源缺失」的键补一条最小溯源（极端兜底）。"""
    return {"source": key, "fingerprint": fingerprint(content), "mode": "follow",
            "content_fingerprint": fingerprint(content)}


def _dedup_append(cur: str, addition: str) -> tuple[str, str]:
    """追加笔记去重（按「行/要点」粒度）：与已有笔记中任一行完全相同或高度相似
    （>0.9 的改写式重复）的新行跳过，其余以空行分隔追加；整段完全命中则整体跳过。
    返回 (合并后文本, 实际新增部分)——调用方据后者判断文件是否真的变了。

    整段子串包含会把「旧要点复述 + 新要点」的混合输出整段误追加（已覆盖内容重复沉淀），
    也可能把恰好被包含的新表述整段误丢，故改为行级比对。
    """
    clean = (addition or "").strip()
    if not clean:
        return (cur or "").strip(), ""
    cur_trim = (cur or "").strip()
    if not cur_trim:
        return clean, clean
    if clean in cur_trim:
        return cur_trim, ""
    existing_lines = [ln.strip() for ln in cur_trim.splitlines() if ln.strip()]

    def _covered(line: str) -> bool:
        if line in existing_lines or line in cur_trim:
            return True  # 完全相同 / 新表述完全被已有文本包含（如只输出标题句）
        for el in existing_lines:
            if len(line) < 6 or len(el) < 6:
                continue  # 短行不做相似度判断（噪声大）
            if difflib.SequenceMatcher(None, line, el).ratio() > 0.9:
                return True  # 改写式重复：措辞不同但高度相似
        return False

    new_lines = [ln for ln in (l.strip() for l in clean.splitlines()) if ln and not _covered(ln)]
    if not new_lines:
        return cur_trim, ""
    return cur_trim + "\n\n" + "\n".join(new_lines), "\n".join(new_lines)


_notes_locks: dict[str, threading.Lock] = {}
_notes_locks_guard = threading.Lock()


def _notes_lock(name: str) -> threading.Lock:
    """按专项名取笔记写锁：读改写（读 cur → 去重追加 → 整文件覆盖）并发时后写覆盖先写，
    会静默丢失新增要点；uvicorn 同步端点跑在线程池，threading.Lock 足够。"""
    with _notes_locks_guard:
        lock = _notes_locks.get(name)
        if lock is None:
            lock = _notes_locks[name] = threading.Lock()
        return lock


def _write_bundle(name: str, content: str, sql_names: list[str], doc_names: list[str],
                  forecast_binding, level: str, game_key: str | None,
                  rewrite: bool = True, only_drifted: bool = False,
                  confidentiality: str | None = None) -> tuple[dict, dict, dict]:
    """构建内嵌快照 + 溯源，整包写入专项目录，返回 (sqls, models, knowledge) 供保存提示。

    rewrite=False 时跳过 LLM 改写/精简，直接冻结原始内容——用于「保存」这种必须即时、
    确定性落盘的高频路径；LLM 适配由 /refresh、/plan 显式触发（默认 True）。

    only_drifted=True（增量刷新）：只对「源已漂移」的 SQL/文档重跑 LLM 改写，
    其余键复用现有快照与溯源（保留本地改编、不无谓重跑 LLM），显著提速刷新。
    """
    model = config.task_model("skill")
    states = ks.skill_snapshot_states(name) if only_drifted else {}

    def _needs_rewrite(kind: str, key: str) -> bool:
        if not only_drifted:
            return True
        st = (states.get(kind) or {}).get(key)
        if st is None:
            return True  # 溯源里没有（新增绑定 / 首次快照）→ 需要重写
        return st.get("state") in ("drifted", "both")

    sql_rewrite = [s for s in sql_names if _needs_rewrite("sql", s)]
    doc_rewrite = [d for d in doc_names if _needs_rewrite("knowledge", d)]

    sqls, prov_sql = skill_bundle.build_sql_snapshots(model, sql_rewrite, content, rewrite=rewrite)
    knowledge, prov_knowledge = skill_bundle.build_knowledge_snapshots(model, doc_rewrite, rewrite=rewrite)
    models, prov_models, pred_sql = skill_bundle.build_model_snapshot(forecast_binding)

    # 预测取数 SQL 一并冻结（独立于常规步骤 SQL），同样遵循增量判断
    if pred_sql and pred_sql not in sql_names and _needs_rewrite("sql", pred_sql):
        psql, pprov = skill_bundle.build_sql_snapshots(model, [pred_sql], content, rewrite=rewrite)
        sqls.update(psql)
        prov_sql.update(pprov)

    # 保留现有快照 + 溯源（不丢本地改编、不重跑 LLM）：
    # - only_drifted：未被重写的键（无漂移/已改编）保留；
    # - 非改写保存（rewrite=False）：build_sql_snapshots 对「源不在全局 SQL 库、只存在于
    #   本专项内嵌快照」的键（融合导入的 pin 内容等）读不到源会直接丢弃，导致
    #   write_skill_bundle 剪枝把内嵌快照文件一并删掉（对抗审查：frozen-save 轮确认的
    #   「保存后内嵌快照丢失」根因）。这里同样以内嵌件保留，普通保存不再丢快照。
    if only_drifted or not rewrite:
        old_prov = ks.read_skill_provenance(name) or {}
        for s in sql_names:
            if s in sqls:
                continue
            snap = ks.read_skill_sql(name, s)
            if snap.strip():
                sqls[s] = snap
                prov_sql[s] = (old_prov.get("sql") or {}).get(s) or _fallback_prov(s, snap)
        for d in doc_names:
            if d in knowledge:
                continue
            doc = ks.read_skill_knowledge(name, d)
            if doc.strip():
                knowledge[d] = doc
                prov_knowledge[d] = (old_prov.get("knowledge") or {}).get(d) or _fallback_prov(d, doc)
        if pred_sql and pred_sql not in sql_names and pred_sql not in sqls:
            snap = ks.read_skill_sql(name, pred_sql)
            if snap.strip():
                sqls[pred_sql] = snap
                prov_sql[pred_sql] = (old_prov.get("sql") or {}).get(pred_sql) or _fallback_prov(pred_sql, snap)

    meta = {
        "sqls": sql_names,
        "docs": doc_names,
        "level": level,
        "game": game_key if level != "通用" else None,
        "owner": current_owner_key() if level == "个人" else None,
        "forecast": forecast_binding,
        "online": ks.online_on_save(name),
        "confidentiality": confidentiality,
    }
    provenance = {"sql": prov_sql, "models": prov_models, "knowledge": prov_knowledge}
    if rewrite:
        # 记录「快照最近一次被 LLM 改写时的方法说明指纹」，供刷新判断是否需要全量重写
        provenance["__skill__"] = {"fingerprint": fingerprint(content)}
    ks.write_skill_bundle(name, content, meta, sqls=sqls, models=models,
                          knowledge=knowledge, provenance=provenance)
    return sqls, models, knowledge


def _write_frozen_bundle(name: str, content: str, meta: dict, sqls: dict, models: dict,
                         knowledge: dict, provenance: dict) -> None:
    """用预计算的快照直接写专项目录（生成流程阶段二已改造/冻结，这里只落盘）。"""
    ks.write_skill_bundle(name, content, meta, sqls=sqls, models=models,
                          knowledge=knowledge, provenance=provenance)


def _forecast_method(forecast_binding) -> str | None:
    if isinstance(forecast_binding, dict):
        return forecast_binding.get("method")
    if isinstance(forecast_binding, str):
        return forecast_binding
    return None


def _frozen_text(name: str, kind: str, key: str) -> str:
    if kind == "sql":
        return ks.read_skill_sql(name, key)
    if kind == "knowledge":
        return ks.read_skill_knowledge(name, key)
    if kind == "model":
        return ks.read_skill_model(name, key)
    raise ValueError(f"未知冻结件类型：{kind}")


def _source_text(kind: str, key: str) -> str:
    if kind == "sql":
        return sql_store.read_sql(key)
    if kind == "knowledge":
        return ks.read_doc(key)
    if kind == "model":
        return code_store.read_code(key)
    raise ValueError(f"未知冻结件类型：{kind}")


def _rewrite_code(model: str, code: str, instruction: str, user: dict | None = None) -> str:
    raw, _ = complete_with_fallback(
        model=model,
        messages=[
            {"role": "system", "content": "你是资深算法工程师。根据用户要求改写下面的模型代码，只输出改写后的完整 Python 代码，不要任何解释或前后缀。"},
            {"role": "user", "content": f"# 当前代码\n\n{code or ''}\n\n# 改写要求\n\n{instruction}\n\n请输出改写后的完整代码。"},
        ],
        max_tokens=INTERACTIVE_MAX_TOKENS,
        user=user,
    )
    return (raw or "").strip()


class SkillSave(BaseModel):
    content: str = ""
    sqls: list[str] = []
    docs: list[str] = []
    level: str = ks.DEFAULT_SKILL_LEVEL
    forecast: str | dict | None = None
    frozen: dict | None = None  # 生成流程预计算的快照 {sqls, knowledge, models, provenance}，提供则跳过阶段二改造
    confidentiality: str | None = None  # L1/L2/L3 机密档位；空 = 未分级


class SkillGenerate(BaseModel):
    description: str
    model: str | None = None
    existing: str = ""  # 已有专项方法说明（编辑既有专项时回传，供在其基础上修改完善）
    note_skill: str | None = None  # 专项笔记自动沉淀目标（生成/调整时把提炼笔记追加到该专项；留空不沉淀）


class SkillPlan(BaseModel):
    content: str = ""  # 编辑器当前专项文本
    model: str | None = None
    level: str = ks.DEFAULT_SKILL_LEVEL
    forecast: str | dict | None = None  # 当前已选的预测绑定（优先于 plan 建议）


class SnapshotEdit(BaseModel):
    kind: str  # sql | model | knowledge
    key: str   # 源名（冻结件键）
    content: str  # 就地编辑后的冻结内容


class SnapshotAi(BaseModel):
    kind: str
    key: str
    instruction: str  # 用户改写需求描述
    model: str | None = None
    content: str | None = None    # 草稿态：当前冻结件内容（未保存专项时就地改写用）
    skill_text: str | None = None  # 草稿态：当前专项文本（未保存专项时用）


class SnapshotDelete(BaseModel):
    kind: str  # sql | model | knowledge
    key: str   # 冻结件键（源名）


class Associate(BaseModel):
    description: str
    model: str | None = None
    existing_sqls: list[str] = []
    existing_docs: list[str] = []


@router.post("/generate")
def generate_skill(body: SkillGenerate, user: dict = Depends(get_current_user), game=Depends(get_game)):
    """据自然语言描述生成专项方法说明 + 建议关联的 SQL/文档（供专项页「AI 生成」）。"""
    model = resolve_model_for_task("skill", user, body.model)
    sql_names = sql_store.list_sql_files(game["key"])
    doc_names = ks.list_docs(game["key"])
    # 只把「可自动取数」的预测能力（input=sql）交给 AI 选择，离线上传型（upload）不参与绑定
    fcaps = [c for c in forecast.visible_capabilities(game["key"]) if c.get("input") == "sql"]
    # 专项笔记自动沉淀（去掉「专项笔记」独立按钮后）：生成/调整专项时 LLM 顺带提炼
    # 口径/经验/已知数据坑（增量——已有笔记喂给 LLM，只输出新增要点），自动追加到该专项的
    # 笔记槽（右下「内嵌快照」区可查看/编辑，报告生成时随方法说明注入）。
    # 仅对已落盘且可见、有编辑权的专项沉淀；笔记环节失败不回滚生成主流程
    # （预检整体兜底：非法名称经 _validate_name 抛 ValueError 等都不应让 /generate 500）。
    can_note = False
    try:
        if body.note_skill and body.note_skill.strip() and (ks.read_skill(body.note_skill) or "").strip():
            from backend.ide_app.services.permissions import has_perm
            if has_perm(user, "analysis_edit"):
                _require_visible(body.note_skill, game["key"], action="记笔记")
                can_note = True
    except HTTPException:
        can_note = False
    except Exception:  # noqa: BLE001 —— 非法名 ValueError/知识库异常等均不阻断生成主流程
        can_note = False
    existing_notes = ks.read_skill_notes(body.note_skill) if can_note else ""
    try:
        result = kb_summarize.summarize_skill(model, body.description, sql_names, doc_names, body.existing, fcaps, existing_notes)
    except LLMNotConfigured:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"AI 调用失败：{exc}")

    note_added = ""
    if can_note:
        try:
            note = (result.get("note") or "").strip()
            if note:
                # 写盘前复核专项仍存在且可见（LLM 调用期间可能被改名/删除），避免孤儿笔记文件；
                # 返回的 note 只报「实际新增部分」——去重后无新增（同描述重复生成）则为空，
                # 前端据此决定是否提示「已自动记入专项笔记」
                with _notes_lock(body.note_skill):
                    if (ks.read_skill(body.note_skill) or "").strip():
                        _require_visible(body.note_skill, game["key"], action="记笔记")
                        merged, added = _dedup_append(ks.read_skill_notes(body.note_skill), note)
                        if added:
                            ks.write_skill_notes(body.note_skill, merged)
                            note_added = added
        except Exception:  # noqa: BLE001 —— 笔记沉淀是伴随能力，失败不影响生成返回
            note_added = ""
    return {
        "draft": result["content"],
        "title": result["title"],
        "sqls": result["sqls"],
        "docs": result["docs"],
        "forecast": result.get("forecast"),
        "note": note_added,
    }


@router.post("/{name}/plan")
def plan_skill_snapshots(name: str, body: SkillPlan, user: dict = Depends(get_current_user), game=Depends(get_game)):
    """读专项文本 → 规划 SQL（已有→改写 / 缺失→生成）→ 产出可人审的快照草稿包（不落盘）。"""
    _require_visible(name, game["key"])
    model = resolve_model_for_task("skill", user, body.model)
    sql_names = sql_store.list_sql_files(game["key"])
    doc_names = ks.list_docs(game["key"])
    fcaps = [c for c in forecast.visible_capabilities(game["key"]) if c.get("input") == "sql"]
    try:
        engine = get_engine()
        schema_text, ref_docs, _src = schema_context.build_sql_context(
            engine, game["db"], game=game["key"], question=body.content
        )
        # 对抗审查（frozen-save 轮）：本专项内嵌快照里「源不在全局 SQL 库」的 SQL 必须
        # 恒定计为 existing（否则被误判 missing、从零 LLM 生成覆盖已验证快照）；
        # build_planned_snapshot 里这些键按内嵌件冻结（只重盖章，不 LLM 改写）。
        bound_sqls = {
            s: text for s in ks.read_skill_meta(name).get("sqls") or []
            if (text := ks.read_skill_sql(name, s)).strip()
        }
        plan = skill_plan.plan_skill(model, body.content, sql_names, doc_names, fcaps, bound_sqls=bound_sqls)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"规划失败：{exc}")

    existing_docs = [d["name"] for d in plan["docs"] if d["status"] == "existing"]
    step_names = [s["name"] for s in plan["sqls"]]
    # 绑定优先级：用户已选的预测绑定 > plan 建议
    forecast_binding = body.forecast or (plan["forecast"]["method"] if plan["forecast"] else None)
    try:
        bundle = skill_bundle.build_planned_snapshot(
            model, plan["content"], plan["sqls"], schema_text, ref_docs, existing_docs, forecast_binding,
            embedded_sqls=bound_sqls,
        )
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"生成快照失败：{exc}")

    return {
        "content": plan["content"],
        "sqls": step_names,
        "docs": existing_docs,
        "forecast": forecast_binding,
        "plan": plan,
        "frozen": {
            "sqls": bundle["sqls"],
            "knowledge": bundle["knowledge"],
            "models": bundle["models"],
            "provenance": bundle["provenance"],
        },
    }


@router.get("")
def list_skills(game=Depends(get_game)):
    skills = []
    for n in ks.list_skills(game["key"]):
        meta = ks.read_skill_meta(n)
        skills.append({
            "name": n,
            "sqls": meta["sqls"],
            "docs": meta["docs"],
            "level": ks.skill_level(n),
            "code": code_store.code_for_skill(n),
            "online": ks.skill_online(n),
            "confidentiality": meta.get("confidentiality"),
        })
    return {"skills": skills}


@router.get("/forecast-capabilities")
def forecast_capabilities(game=Depends(get_game)):
    """列出可绑定的预测/算法能力（供专项页「关联预测能力」下拉选择）。"""
    return {"capabilities": forecast.visible_capabilities(game["key"])}


@router.get("/{name}")
def read_skill(name: str, game=Depends(get_game)):
    _require_visible(name, game["key"])
    try:
        meta = ks.read_skill_meta(name)
        content = ks.read_skill(name)
        level = ks.skill_level(name)
        code_name = code_store.code_for_skill(name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    method = _forecast_method(meta.get("forecast"))
    return {
        "name": name,
        "content": content,
        "sqls": meta["sqls"],
        "docs": meta["docs"],
        "level": level,
        "game": meta["game"],
        "forecast": meta.get("forecast"),
        "code": code_name,
        "code_content": code_store.read_code(code_name) if code_name else "",
        "bundle": ks.is_skill_bundle(name),
        "online": ks.skill_online(name),
        "confidentiality": meta.get("confidentiality"),
        "embedded_sqls": {s: ks.read_skill_sql(name, s) for s in meta["sqls"]},
        "embedded_docs": {d: ks.read_skill_knowledge(name, d) for d in meta["docs"]},
        "embedded_models": {method: ks.read_skill_model(name, method)} if method else {},
        "provenance": ks.read_skill_provenance(name),
        "snapshot_states": ks.skill_snapshot_states(name),
        "drift": ks.skill_drift(name),
        "notes": ks.read_skill_notes(name),
    }


class SkillNotes(BaseModel):
    content: str = ""


@router.get("/{name}/notes")
def get_skill_notes(name: str, game=Depends(get_game)):
    """读专项笔记（增补知识槽）：全局知识库之外、仅本专项生效的补充口径/经验。"""
    _require_visible(name, game["key"])
    return {"name": name, "notes": ks.read_skill_notes(name)}


@router.post("/{name}/notes")
def set_skill_notes(name: str, body: SkillNotes, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    """写专项笔记（覆盖写；置空清空）。报告生成时与全局知识库/专项方法一起注入。

    只允许对已落盘专项写笔记：不存在的名字会生成孤儿笔记文件，将来同名专项被创建时
    静默激活、注入所有游戏的报告提示词（跨用户潜伏内容注入），故先校验存在性。
    """
    try:
        if not (ks.read_skill(name) or "").strip():
            raise HTTPException(status_code=404, detail=f"专项「{name}」不存在，请先保存专项再写笔记")
        _require_visible(name, game["key"], "覆盖")
        ks.write_skill_notes(name, body.content)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"ok": True, "name": name}


@router.post("/{name}")
def save_skill(name: str, body: SkillSave, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    level = ks.normalize_skill_level(body.level)
    game_key = game["key"]
    from backend.ide_app.services.permissions import normalize_confidentiality
    # 关联/生成快照/刷新等内部保存路径不传 confidentiality（不在 model_fields_set 里），
    # 此时保留既有档位，避免把已设档位静默清成未分级；显式传（含 null）则按传值落盘。
    if "confidentiality" not in body.model_fields_set:
        confidentiality = ks.read_skill_meta(name).get("confidentiality")
    else:
        confidentiality = normalize_confidentiality(body.confidentiality)
    _require_visible(name, game_key, "覆盖")
    try:
        if body.frozen:
            meta = {
                "sqls": body.sqls,
                "docs": body.docs,
                "level": level,
                "game": game_key if level != "通用" else None,
                "owner": owner_key(user) if level == "个人" else None,
                "forecast": body.forecast,
                "online": ks.online_on_save(name),
                "confidentiality": confidentiality,
            }
            _write_frozen_bundle(
                name, body.content, meta,
                sqls=body.frozen.get("sqls") or {},
                models=body.frozen.get("models") or {},
                knowledge=body.frozen.get("knowledge") or {},
                provenance=body.frozen.get("provenance") or {"sql": {}, "models": {}, "knowledge": {}},
            )
            sqls = body.frozen.get("sqls") or {}
            models = body.frozen.get("models") or {}
            knowledge = body.frozen.get("knowledge") or {}
        else:
            # 保存只做「即时落盘」，不做 LLM 改写/精简（rewrite=False），避免网关超时拖慢保存；
            # 需要 LLM 适配时走「刷新快照 /refresh」或「生成快照方案 /plan」。
            sqls, models, knowledge = _write_bundle(
                name, body.content, body.sqls, body.docs, body.forecast, level, game_key, rewrite=False,
                confidentiality=confidentiality,
            )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {
        "ok": True,
        "name": name,
        "bundle": ks.is_skill_bundle(name),
        "summary": {
            "model": _forecast_method(body.forecast),
            "models": sorted(models.keys()),
            "knowledge": sorted(knowledge.keys()),
            "sqls": sorted(sqls.keys()),
        },
    }


@router.post("/{name}/snapshot/edit")
def snapshot_edit(name: str, body: SnapshotEdit, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    """就地写回某个冻结件（SQL / 模型 / 知识），不改 provenance、不改其它冻结件。"""
    _require_visible(name, game["key"], "编辑")
    if not ks.is_skill_bundle(name):
        raise HTTPException(status_code=400, detail="该专项不是目录打包形态，无法就地编辑快照")
    try:
        ks.write_skill_piece(name, body.kind, body.key, body.content)
        ks.mark_skill_piece_adapted(name, body.kind, body.key, body.content)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"ok": True, "name": name, "kind": body.kind, "key": body.key}


@router.post("/{name}/snapshot/ai")
def snapshot_ai(name: str, body: SnapshotAi, user: dict = Depends(get_current_user), game=Depends(get_game)):
    """按「源头 + 描述」就地改写某个冻结件，返回新内容（人审后经 /snapshot/edit 写回）。"""
    _require_visible(name, game["key"], "改写")
    if body.kind not in ("sql", "knowledge", "model"):
        raise HTTPException(status_code=400, detail=f"未知冻结件类型：{body.kind}")
    model = resolve_model_for_task("skill", user, body.model)
    # 草稿态（未保存专项）：优先用请求里带的内容/文本，不读盘
    skill_text = body.skill_text if body.skill_text is not None else ks.read_skill(name)
    frozen = body.content if body.content is not None else _frozen_text(name, body.kind, body.key)
    source = _source_text(body.kind, body.key)
    try:
        if body.kind == "sql":
            new, _ = rewrite_sql(model, frozen or source, [body.instruction], skill_text or None)
        elif body.kind == "knowledge":
            new, _ = kb_summarize.summarize(
                model, [{"name": body.key, "content": source or frozen}],
                extra=body.instruction, existing=frozen,
            )
        else:  # model
            new = _rewrite_code(model, frozen or source, body.instruction, user)
    except LLMNotConfigured:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"AI 改写失败：{exc}")
    return {"ok": True, "kind": body.kind, "key": body.key, "content": new}


@router.post("/{name}/snapshot/delete")
def snapshot_delete(name: str, body: SnapshotDelete, user: dict = Depends(require_analysis_delete), game=Depends(get_game)):
    """删除某个冻结件快照及其溯源记录（不改 meta 关联，运行回退全局源）。"""
    _require_visible(name, game["key"], "删除")
    if not ks.is_skill_bundle(name):
        raise HTTPException(status_code=400, detail="该专项不是目录打包形态，无法删除快照")
    try:
        ks.delete_skill_piece(name, body.kind, body.key)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"ok": True, "name": name, "kind": body.kind, "key": body.key}


@router.post("/{name}/associate")
def associate_skill(name: str, body: Associate, user: dict = Depends(get_current_user), game=Depends(get_game)):
    """据描述就地建议关联 SQL / 文档 / 预测能力（不改方法说明）。"""
    _require_visible(name, game["key"])
    model = resolve_model_for_task("skill", user, body.model)
    sql_names = sql_store.list_sql_files(game["key"])
    doc_names = ks.list_docs(game["key"])
    fcaps = [c for c in forecast.visible_capabilities(game["key"]) if c.get("input") == "sql"]
    try:
        result = kb_gen.suggest_associations(
            model, body.description, sql_names, doc_names, fcaps,
            existing_sqls=body.existing_sqls, existing_docs=body.existing_docs,
        )
    except LLMNotConfigured:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"AI 调用失败：{exc}")
    return result


@router.post("/{name}/refresh")
def refresh_skill(name: str, user: dict = Depends(require_analysis_edit), game=Depends(get_game)):
    """手动刷新：对漂移源重新改写 + 冻结（不自动触发）。仅对目录打包专项生效。

    增量判断：若专项方法说明（skill.md）自上次改写后没变，则只重写「源已漂移」的 SQL/文档
    （通常只有 1-2 个），其余复用现有快照；方法说明变了才全量重写（否则快照会停在旧口径）。
    """
    _require_visible(name, game["key"], "刷新")
    if not ks.is_skill_bundle(name):
        raise HTTPException(status_code=400, detail="该专项为扁平旧格式，请先重新保存以启用快照")
    meta = ks.read_skill_meta(name)
    content = ks.read_skill(name)
    prov = ks.read_skill_provenance(name) or {}
    last_adapted = (prov.get("__skill__") or {}).get("fingerprint")
    only_drifted = last_adapted == fingerprint(content)
    try:
        _write_bundle(name, content, meta["sqls"], meta["docs"], meta.get("forecast"),
                      ks.skill_level(name), meta.get("game"), rewrite=True, only_drifted=only_drifted)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"ok": True, "name": name, "drift": ks.skill_drift(name)}


class SkillOnline(BaseModel):
    online: bool


@router.post("/{name}/online")
def set_skill_online(name: str, body: SkillOnline, user=Depends(require_analysis_edit), game=Depends(get_game)):
    """上线/下线专项：下线后对聊天/自由对话/Agent 不可见（不可点名、不可选、不可引用），
    专项管理侧仍可见可编辑——用于「新建专项调试期暂不开放给用户，调试确认后手动上线」。"""
    _require_visible(name, game["key"], "上线/下线")
    try:
        # 先验存在性：对不存在的名字写 online 会留下孤儿 meta（将来同名专项被创建时
        # 静默继承该状态），与 notes 端点同口径先挡 404
        if not ks.skill_exists(name):
            raise HTTPException(status_code=404, detail=f"专项「{name}」不存在，请先保存专项")
        ks.set_skill_online(name, body.online)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"ok": True, "name": name, "online": body.online}


@router.delete("/{name}")
def delete_skill(name: str, user=Depends(require_analysis_delete), game=Depends(get_game)):
    _require_visible(name, game["key"], "删除")
    try:
        ks.delete_skill(name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"ok": True}
