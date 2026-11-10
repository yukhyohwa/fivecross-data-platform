"""报告缺口自动修复：把「报告缺口与补数建议」落成三类可执行动作。

1. sql/modify —— 缺数据但已有 SQL（硬编码日期 / 口径）：
   - 硬编码日期 → 自动改写为相对日期/占位符，同步修「全局 SQL」与「专项快照」，guard_rewrite 兜底；
   - 其它口径 → LLM 改写草稿，人审后保存（写全局 + 同步快照）。
2. sql/create —— 缺 SQL：LLM 生成全局 SQL 草稿 → 人审 → 写全局 + 绑专项 + 写快照 + 记父链接。
3. kb —— 缺知识库：扫现有知识库，已有未绑定则直接绑定；真缺则登记进「缺口登记册」抑制反复汇报，并反写提醒。

缺口登记册存专项运行记忆（run.json）的 gaps 键，签名 = sha256(type|action|target|issue 归一)[:16]，
状态 ∈ fixed / known / draft，用于标注已处理缺口，避免每次运行重复汇报同一问题。
"""
from __future__ import annotations

import hashlib
import re
from datetime import datetime

from analysis import code_store
from analysis import kb_gen
from analysis import knowledge_store as ks
from analysis import model_gen
from analysis import sql_store
from analysis.games import visible_to, current_owner_key
from analysis.snapshot import fingerprint
from analysis.sql_gen import generate_sql
from analysis.sql_rewriter import (
    rewrite_sql, detect_hardcoded_dates, guard_rewrite, validate_sql,
)

from . import forecast
from . import schema_context, sql_cache

_NOTE_HEADING = "## 📌 数据缺口登记"
_STOP_TOKENS = {
    "知识库", "文档", "补充", "说明", "口径", "需要", "一个", "相关", "的", "报告",
    "分析", "数据", "专项", "该", "可", "建立", "新建", "新增", "修改", "现有",
    "目前", "以及", "或者", "可以", "存在", "已", "有", "无", "请", "为", "用于", "及",
}


# ---- 缺口签名与登记册（run.json 的 gaps 键，横切三类缺口）----

def gap_signature(gap: dict) -> str:
    """稳定签名：同一缺口跨次运行签名一致，用于登记册去重/标注。"""
    key = "|".join([
        str(gap.get("remedy_type") or ""),
        str(gap.get("remedy_action") or ""),
        str(gap.get("remedy_target") or ""),
        re.sub(r"\s+", "", str(gap.get("issue") or "")),
    ])
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]


def _load_registry(skill: str | None) -> dict:
    if not skill:
        return {}
    mem = ks.read_skill_memory(skill)
    reg = mem.get("gaps") if isinstance(mem.get("gaps"), dict) else {}
    return reg


def _save_registry(skill: str | None, registry: dict) -> None:
    if not skill:
        return
    mem = ks.read_skill_memory(skill)
    mem["gaps"] = registry
    ks.write_skill_memory(skill, mem)


def mark_gap(skill: str | None, gap: dict, status: str) -> str:
    sig = gap_signature(gap)
    if not skill:
        return sig
    reg = _load_registry(skill)
    reg[sig] = {
        "status": status,
        "type": gap.get("remedy_type"),
        "issue": gap.get("issue"),
        "detail": gap.get("remedy_detail"),
        "severity": gap.get("severity"),
        "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }
    _save_registry(skill, reg)
    return sig


def annotate_gaps(skill: str | None, gaps: list[dict]) -> list[dict]:
    """给每条缺口附上签名与登记状态（fixed/known/new），供前端决定按钮与置灰。

    白名单（ignored）条目整体跳过，后续运行不再出现。
    """
    reg = _load_registry(skill)
    out = []
    for g in gaps:
        g = dict(g)
        sig = gap_signature(g)
        status = reg.get(sig, {}).get("status", "new")
        if status == "ignored":
            continue
        g["_sig"] = sig
        g["status"] = status
        out.append(g)
    return out


# ---- 白名单（用户标记「不需要处理」的缺口，抑制反复出现）----

def whitelist_gap(skill: str | None, gap: dict) -> dict:
    """把一条缺口加入白名单（status=ignored）：annotate_gaps 会整条跳过，后续运行不再出现。"""
    if not skill:
        return {"ok": False, "message": "未关联专项，无法加入白名单；请先在该专项下运行缺口分析。"}
    sig = mark_gap(skill, gap, "ignored")
    return {"ok": True, "sig": sig}


def list_whitelist(skill: str | None) -> list[dict]:
    """列出白名单（status=ignored）条目，供前端查看/删除。"""
    reg = _load_registry(skill)
    out = []
    for sig, rec in reg.items():
        if rec.get("status") == "ignored":
            out.append({
                "sig": sig,
                "issue": rec.get("issue") or "",
                "type": rec.get("type") or "",
                "detail": rec.get("detail") or "",
                "severity": rec.get("severity") or "",
                "updated_at": rec.get("updated_at") or "",
            })
    out.sort(key=lambda r: r.get("updated_at") or "", reverse=True)
    return out


def remove_whitelist(skill: str | None, sig: str) -> dict:
    """从白名单移除一条（删除登记）：下次运行该缺口可能再次出现。"""
    if not skill:
        return {"ok": False, "message": "未关联专项。"}
    if not sig:
        return {"ok": False, "message": "缺少条目签名 sig。"}
    reg = _load_registry(skill)
    if sig not in reg:
        return {"ok": False, "message": "白名单中未找到该条目。"}
    del reg[sig]
    _save_registry(skill, reg)
    return {"ok": True}


# ---- 小工具 ----

def _sql_name(name: str | None) -> str:
    name = (name or "").strip()
    if not name:
        return ""
    return name if name.endswith(".sql") else name + ".sql"


def _sql_target_visible(name: str, game_key: str) -> tuple[bool, str]:
    """写既有 SQL 目标前的可见性校验（对抗审查三轮 F0）：个人级仅归属用户、
    项目级仅同族（family_key 匹配）可改；不存在/无 meta 的旧资产按通用级共享放行。

    此前 gap 接口族在 skill 缺省路径按客户端可控的 remedy_target/draft.name 裸写全局
    SQL——持任一游戏权限即可覆写他人个人级 SQL（guard_rewrite 只查丢表/丢时区，不查归属）。
    """
    meta = sql_store.read_sql_meta(name)
    if not visible_to(meta.get("level"), meta.get("game"), game_key,
                      meta.get("owner"), current_owner_key()):
        return False, f"《{name}》属于其他游戏或用户，无权修改。"
    return True, ""


def _append_skill_note(skill: str, line: str) -> None:
    """把一条缺口登记追加进专项笔记（增补槽，不影响全局库/专项方法），去重。"""
    notes = ks.read_skill_notes(skill)
    if _NOTE_HEADING not in notes:
        notes = notes.rstrip() + ("\n\n" if notes.strip() else "") + _NOTE_HEADING + "\n"
    if line in notes:
        return
    ks.write_skill_notes(skill, notes.rstrip() + "\n- " + line + "\n")


def _propose_sql_name(gap: dict) -> str:
    """从缺口建议里推导新 SQL 文件名（含 .sql），并清理非法字符。"""
    detail = gap.get("remedy_detail") or ""
    m = re.search(r"新增\s*SQL[：:]\s*([^\s，,。；;]+)", detail)
    name = (m.group(1).strip() if m else re.sub(r"[\s，,。；;：:、]+", "", gap.get("issue") or "")) or "缺口补充"
    name = re.sub(r'[\\/:*?"<>|]', "", name)[:24]
    return name if name.endswith(".sql") else name + ".sql"


def _scan_existing_doc(gap: dict, game_key) -> str | None:
    """扫现有知识库找匹配文档：先精确撞名，再按有意义词元保守匹配，无把握返回 None。"""
    docs = ks.list_docs(game_key) or []
    if not docs:
        return None
    target = (gap.get("remedy_target") or "").strip()
    if target:
        t = target[:-3] if target.endswith(".md") else target
        for d in docs:
            if (d[:-3] if d.endswith(".md") else d) == t:
                return d
    text = f"{(gap.get('remedy_detail') or '')} {(gap.get('issue') or '')}"
    tokens = [t for t in re.findall(r"[一-鿿]{2,}|[A-Za-z][A-Za-z0-9_]{2,}", text)]
    tokens = [t for t in tokens if t not in _STOP_TOKENS and t.lower() not in _STOP_TOKENS]
    best: tuple[str, int] | None = None
    for d in docs:
        dn = d[:-3] if d.endswith(".md") else d
        score = sum(len(t) for t in tokens if t.lower() in dn.lower())
        if score and (best is None or score > best[1]):
            best = (d, score)
    return best[0] if best and best[1] >= 4 else None


_WINDOW_RE = re.compile(r"interval\s+['\"]?\s*(\d+)\s*['\"]?\s*(day|week|month|year|hour)s?\b", re.IGNORECASE)


def _windows(sql: str) -> list[tuple[str, str]]:
    """按出现顺序提取 SQL 里的相对时间窗口 `interval N unit`，返回 [(unit, N), ...]。"""
    return [(m.group(2).lower(), m.group(1)) for m in _WINDOW_RE.finditer(sql or "")]


def _strip_windows(sql: str) -> str:
    """去掉所有 `interval N unit` 后的正文（用于判断改动是否『只是窗口数值变了』）。"""
    return _WINDOW_RE.sub("", sql or "")


def _align_windows(snapshot: str, global_before: str, global_final: str) -> str | None:
    """确定性把快照里的相对时间窗口数值对齐到全局改写后的数值。

    仅当 global_before → global_final 的差异是『纯窗口数值变化』（去掉窗口后正文一致、
    窗口单元顺序一致）时，才把快照里出现的相同旧 (unit,N) 替换为新 N；否则返回 None，
    交由 LLM 改写 / 镜像全局兜底。这样即使 LLM 没改对，快照的窗口口径也能与全局保持一致。
    """
    before = _windows(global_before)
    after = _windows(global_final)
    if not before or not after or len(before) != len(after):
        return None
    if [u for u, _ in before] != [u for u, _ in after]:
        return None
    if _strip_windows(global_before) != _strip_windows(global_final):
        return None
    mapping: dict[tuple[str, str], str] = {}
    for (unit, old), (_, new) in zip(before, after):
        if old != new:
            mapping[(unit, old)] = new
    if not mapping:
        return None
    out = snapshot
    for (unit, old), new in mapping.items():
        pat = re.compile(
            r"interval\s+['\"]?\s*" + re.escape(old) + r"\s*['\"]?\s*" + unit + r"s?\b",
            re.IGNORECASE,
        )
        out = pat.sub(lambda m: m.group(0).replace(old, new, 1), out)
    return out


def _skill_text(skill: str | None) -> str:
    """读专项方法说明全文（供改写时作为口径约定注入），读不到返回空串。"""
    if not skill:
        return ""
    try:
        return ks.read_skill(skill) or ""
    except Exception:
        return ""


def _sync_snapshot(skill: str | None, name: str, model: str | None,
                   global_before: str, global_final: str, prompt: str) -> None:
    """把改写结果同步进专项快照（若存在）。

    优先做确定性的『相对时间窗口数值对齐』（窗口改动不依赖 LLM 也能同步到快照）；
    否则用同一修改要求 + 专项方法说明独立改写快照，护栏不过则镜像全局。
    """
    if not skill:
        return
    prov = ks.read_skill_provenance(skill)
    if not isinstance((prov.get("sql") or {}).get(name), dict):
        return
    snap = ks.read_skill_sql(skill, name)
    if not snap.strip():
        return
    new_snap = _align_windows(snap, global_before, global_final)
    if new_snap is not None:
        # 确定性对齐结果也过一道护栏，避免误改破坏口径；不过则回退镜像全局
        if guard_rewrite(snap, new_snap):
            new_snap = global_final
    else:
        skill_text = _skill_text(skill)
        new_snap = global_final
        if model and (prompt or "").strip():
            try:
                cand, _ = rewrite_sql(model, snap, [prompt], skill_text or None)
            except Exception:
                cand = global_final
            if not guard_rewrite(snap, cand) and not detect_hardcoded_dates(cand):
                new_snap = cand
    ks.write_skill_piece(skill, "sql", name, new_snap)
    entry = prov["sql"][name]
    entry["source"] = name
    entry["fingerprint"] = fingerprint(global_final)
    entry["content_fingerprint"] = fingerprint(new_snap)
    entry["mode"] = "follow"
    ks.write_skill_provenance(skill, prov)


def _apply_rewrite(skill: str | None, name: str, model: str | None,
                   global_before: str, global_final: str, prompt: str, game_key: str = "") -> None:
    """写全局 SQL + 同步专项快照（父链接溯源一起刷新）。"""
    sql_store.write_sql(name, global_final)
    # 审计 P2-15：SQL 资产写盘成功后按 game 失效 SQL 生成缓存，避免后续重复提问命中旧结果
    sql_cache.invalidate(game_key)
    _sync_snapshot(skill, name, model, global_before, global_final, prompt)


# ---- ① sql/modify（换日期/改口径）----

def resolve_sql_modify(model: str, skill: str | None, gap: dict, game_key, db, engine) -> dict:
    name = _sql_name(gap.get("remedy_target"))
    if not name:
        return {"action": "prompt", "kind": "sql_modify",
                "message": "该缺口未指明要修改的 SQL，请到「SQL数据」页手动处理。"}
    global_sql = sql_store.read_sql(name)
    if not global_sql.strip():
        return {"action": "prompt", "kind": "sql_modify",
                "message": f"未找到全局 SQL《{name}》，请先到「SQL数据」页确认该文件是否存在。"}
    ok, msg = _sql_target_visible(name, game_key)
    if not ok:
        # 不可见目标：不返回其内容（before_sql 泄露通道），只给拒绝提示
        return {"action": "prompt", "kind": "sql_modify", "message": msg}
    skill_text = _skill_text(skill)

    dates = detect_hardcoded_dates(global_sql)
    if dates:
        prompt = (
            f"该 SQL 硬编码了日期（{'、'.join(dates)}），请把这些日期字面量改为 current_date() 相对表达式，"
            f"使时间范围可被专项/对话动态调整；"
            f"其它表、字段、输出列、粒度、图表形态保持不变。"
        )
        try:
            new_global, _ = rewrite_sql(model, global_sql, [prompt], skill_text or None)
        except Exception as exc:
            return {"action": "draft", "kind": "sql_modify",
                    "message": f"自动改写失败（{exc}），转为草稿待审。",
                    "draft": _modify_draft(name, global_sql, prompt)}
        violations = guard_rewrite(global_sql, new_global)
        remaining = detect_hardcoded_dates(new_global)
        if violations or remaining:
            return {"action": "draft", "kind": "sql_modify",
                    "message": "自动改写未通过护栏，转为草稿待审。",
                    "draft": _modify_draft(name, new_global, prompt,
                                           violations + [f"残留硬编码日期 {d}" for d in remaining])}
        # 审计 P2-1：不再隐式落盘——护栏通过后先返回 diff 预览，用户一键确认（/chat/gap-fix/apply）后才写全局与快照
        return {"action": "confirm", "kind": "sql_modify_confirm", "name": name,
                "message": f"已改写《{name}》的硬编码日期（{'、'.join(dates)}）。请预览 diff 后确认应用（全局与快照将同步更新）。",
                "draft": {"kind": "sql_modify_confirm", "name": name, "prompt": prompt,
                          "before_sql": global_sql, "sql": new_global,
                          "skill": skill, "game_key": game_key, "gap": gap, "dates": dates}}

    # 非日期口径 → 草稿（人审后再保存）。把专项方法说明一并注入改写，使时间窗口等口径
    # 按专项约定（如『合并窗口 interval 14 day』）对齐，而不是只凭缺口描述猜。
    prompt = (gap.get("remedy_detail") or gap.get("issue") or "").strip()
    if skill_text:
        prompt = (prompt + "\n\n改写时务必遵守专项方法说明（参考 Skill）里对时间窗口/口径的约定，"
                  "把 SQL 中与之不符的相对时间窗口（如 interval N day）改成专项约定的窗口。").strip()
    try:
        new_global, _ = rewrite_sql(model, global_sql, [prompt] if prompt else [], skill_text or None)
    except Exception:
        new_global = global_sql
    return {"action": "draft", "kind": "sql_modify",
            "message": "已生成改写草稿，请审阅后保存（将同步写回全局与专项快照）。",
            "draft": _modify_draft(name, new_global, prompt)}


def _modify_draft(name: str, sql: str, prompt: str, violations: list[str] | None = None) -> dict:
    return {"kind": "sql_modify", "name": name, "prompt": prompt, "sql": sql,
            "violations": violations or []}


# ---- ② sql/create（缺 SQL → 生成草稿 → 人审保存）----

def resolve_sql_create(model: str, skill: str | None, gap: dict, game_key, db, engine) -> dict:
    if not skill:
        return {"action": "prompt", "kind": "sql_create",
                "message": "未关联专项，无法自动生成并绑定 SQL，请到「SQL数据」页手动新建后再到专项页绑定。"}
    detail = (gap.get("remedy_detail") or "").strip() or (gap.get("issue") or "").strip()
    try:
        schema_text, ref_docs, _src = schema_context.build_sql_context(engine, db, game=game_key, question=detail)
        sql, _ = generate_sql(model, schema_text, detail, ref_docs)
    except Exception as exc:
        return {"action": "prompt", "kind": "sql_create", "message": f"SQL 生成失败：{exc}"}
    name = _propose_sql_name(gap)
    base = name[:-4] if name.endswith(".sql") else name
    i = 2
    while sql_store.read_sql(name).strip():
        name = f"{base}_{i}.sql"
        i += 1
    step = name[:-4] if name.endswith(".sql") else name
    draft = {"kind": "sql_create", "name": name, "step": step, "section": "🔍 明细下钻",
             "required": False, "sql": sql, "prompt": detail}
    return {"action": "draft", "kind": "sql_create", "name": name,
            "message": "已生成 SQL 草稿，请审阅后保存（将写入全局并绑定到专项）。", "draft": draft}


# ---- ③ kb（缺知识库 → 扫库绑定 / 登记提示）----

def resolve_kb_gap(skill: str | None, gap: dict, game_key) -> dict:
    if not skill:
        return {"action": "prompt", "kind": "kb_missing",
                "message": "未关联专项，无法自动扫描绑定知识库，请到「知识库」页手动补充。"}
    smeta = ks.read_skill_meta(skill)
    scan_game = smeta.get("game") or game_key
    existing = _scan_existing_doc(gap, scan_game)
    if existing:
        # 审计 P2-1：绑定知识库同样改为一键确认，不再隐式落盘
        return {"action": "confirm", "kind": "kb_bind_confirm", "doc": existing,
                "message": f"在现有知识库中找到《{existing}》，确认后将绑定到专项并标记缺口已修复。",
                "draft": {"kind": "kb_bind_confirm", "doc": existing,
                          "skill": skill, "game_key": scan_game, "gap": gap}}
    mark_gap(skill, gap, "known")
    _append_skill_note(skill, f"[缺知识库] {gap.get('issue')} —— {gap.get('remedy_detail') or ''}")
    return {"action": "prompt", "kind": "kb_missing",
            "message": "现有知识库中未找到匹配文档，已登记进专项缺口登记册（后续运行不再重复汇报）。"
                       "请到「知识库」页新建该文档，或直接告诉我补充内容，我来生成。"}


# ---- 分发与草稿保存 ----

def resolve_gap(model: str, skill: str | None, gap: dict, game_key, db, engine) -> dict:
    rtype = gap.get("remedy_type")
    raction = gap.get("remedy_action")
    if rtype == "kb":
        return resolve_kb_gap(skill, gap, game_key)
    if rtype == "sql" and raction == "create":
        return resolve_sql_create(model, skill, gap, game_key, db, engine)
    if rtype == "sql" and raction == "modify":
        return resolve_sql_modify(model, skill, gap, game_key, db, engine)
    return {"action": "prompt", "kind": "manual",
            "message": f"该缺口类型（{rtype}/{raction}）暂无自动修复，请到对应页面手动处理。"}


def apply_gap_draft(skill: str | None, draft: dict, model: str | None, game_key, db, engine) -> dict:
    kind = draft.get("kind")
    if kind == "sql_create":
        return _apply_create(skill, draft, game_key)
    if kind == "sql_modify":
        return _apply_modify(skill, draft, model, game_key=game_key)
    if kind == "sql_modify_confirm":  # 审计 P2-1：确认应用自动改写预览
        return _apply_modify_confirm(skill, draft, model, game_key=game_key)
    if kind == "kb_bind_confirm":  # 审计 P2-1：确认绑定知识库
        return _apply_kb_bind(skill, draft, game_key=game_key)
    return {"ok": False, "message": f"未知草稿类型 {kind}"}


def _apply_create(skill: str | None, draft: dict, game_key) -> dict:
    name = _sql_name(draft.get("name"))
    sql = (draft.get("sql") or "").strip()
    if not name or not sql:
        return {"ok": False, "message": "草稿缺少 SQL 名称或内容"}
    try:
        validate_sql(sql)
    except Exception as exc:
        return {"ok": False, "message": f"SQL 校验未通过：{exc}"}
    if detect_hardcoded_dates(sql):
        return {"ok": False, "message": "SQL 仍含硬编码日期，请改为相对日期/占位符后再保存"}
    if sql_store.read_sql(name).strip():
        return {"ok": False, "message": f"全局 SQL《{name}》已存在，请改名后再保存"}

    sql_store.write_sql(name, sql)
    # 审计 P2-15：SQL 资产写盘成功后按 game 失效 SQL 生成缓存，避免后续重复提问命中旧结果
    sql_cache.invalidate(game_key)
    smeta = ks.read_skill_meta(skill) if skill else {}
    level = draft.get("level") or smeta.get("level") or "项目"
    game_for_sql = draft.get("game") or smeta.get("game") or game_key
    meta = dict(sql_store.DEFAULT_META)
    meta["level"] = level
    meta["game"] = game_for_sql
    meta["owner"] = current_owner_key() if level == "个人" else None
    meta["fields"] = sql_store.fields_from_sql(sql)
    sql_store.write_sql_meta(name, meta)

    if skill:
        step = (draft.get("step") or "").strip() or (name[:-4] if name.endswith(".sql") else name)
        required = bool(draft.get("required", False))
        ks.add_skill_sql(skill, name, step, required)
        ks.write_skill_piece(skill, "sql", name, sql)
        prov = ks.read_skill_provenance(skill)
        prov.setdefault("sql", {})[name] = {
            "source": name, "fingerprint": fingerprint(sql), "mode": "follow",
            "content_fingerprint": fingerprint(sql),
        }
        ks.write_skill_provenance(skill, prov)
        _append_skill_note(skill, f"[补 SQL] 新增《{name}》（步骤「{step}」），已绑定到专项。")
    return {"ok": True, "name": name,
            "message": f"已保存全局 SQL《{name}》" + ("并绑定到专项。" if skill else "（未关联专项，仅写入全局）。")}


def _apply_modify(skill: str | None, draft: dict, model: str | None, game_key: str = "") -> dict:
    name = _sql_name(draft.get("name"))
    sql = (draft.get("sql") or "").strip()
    prompt = (draft.get("prompt") or "").strip()
    if not name or not sql:
        return {"ok": False, "message": "草稿缺少 SQL 名称或内容"}
    ok, msg = _sql_target_visible(name, game_key)
    if not ok:
        return {"ok": False, "message": msg}
    try:
        validate_sql(sql)
    except Exception as exc:
        return {"ok": False, "message": f"SQL 校验未通过：{exc}"}
    original = sql_store.read_sql(name)
    if original.strip():
        violations = guard_rewrite(original, sql)
        dates = detect_hardcoded_dates(sql)
        if violations or dates:
            problems = violations + [f"残留硬编码日期 {d}" for d in dates]
            return {"ok": False, "violations": problems,
                    "message": "改写结果未通过护栏，未保存：" + "；".join(problems)}
    _apply_rewrite(skill, name, model, original, sql, prompt or "按缺口建议改写", game_key=game_key)
    return {"ok": True, "name": name, "message": f"已保存《{name}》的改写（全局与快照已同步）。"}


def _apply_modify_confirm(skill: str | None, draft: dict, model: str | None, game_key: str = "") -> dict:
    """审计 P2-1：确认应用「sql_modify_confirm」草稿。

    防篡改：确认时重新读盘比对 before_sql（用户审阅期间 SQL 若被他人改动则拒绝），
    并重跑护栏与硬编码日期检查，通过后才写全局 + 同步快照 + 标记缺口已修复。
    """
    name = _sql_name(draft.get("name"))
    sql = (draft.get("sql") or "").strip()
    before_sql = draft.get("before_sql")
    gap = draft.get("gap") or {}
    if not name or not sql:
        return {"ok": False, "message": "草稿缺少 SQL 名称或内容"}
    ok, msg = _sql_target_visible(name, game_key)
    if not ok:
        return {"ok": False, "message": msg}
    current = sql_store.read_sql(name)
    if current != before_sql:
        return {"ok": False, "message": f"《{name}》在预览期间已被改动，请重新运行修复以生成最新 diff。"}
    try:
        validate_sql(sql)
    except Exception as exc:
        return {"ok": False, "message": f"SQL 校验未通过：{exc}"}
    violations = guard_rewrite(current, sql)
    dates = detect_hardcoded_dates(sql)
    if violations or dates:
        problems = violations + [f"残留硬编码日期 {d}" for d in dates]
        return {"ok": False, "violations": problems,
                "message": "改写结果未通过护栏，未保存：" + "；".join(problems)}
    _apply_rewrite(skill, name, model, current, sql,
                   (draft.get("prompt") or "按缺口建议改写"), game_key=game_key)
    mark_gap(skill, gap, "fixed")
    if skill:
        _append_skill_note(skill, f"[修复缺口] 《{name}》硬编码日期已改为相对日期并同步全局与快照。")
    return {"ok": True, "name": name,
            "message": f"已应用《{name}》的改写（全局与快照已同步），缺口已标记为已修复。"}


def _apply_kb_bind(skill: str | None, draft: dict, game_key: str = "") -> dict:
    """审计 P2-1：确认应用「kb_bind_confirm」草稿。

    防篡改：确认时重扫现有知识库并要求命中文档一致，才绑定到专项并标记缺口已修复。
    """
    if not skill:
        return {"ok": False, "message": "未关联专项，无法绑定知识库。"}
    doc = (draft.get("doc") or "").strip()
    gap = draft.get("gap") or {}
    if not doc:
        return {"ok": False, "message": "草稿缺少知识库文档名。"}
    current = _scan_existing_doc(gap, draft.get("game_key") or game_key)
    if current != doc:
        return {"ok": False, "message": "知识库在预览期间已变化，未找到原匹配文档，请重新运行缺口分析。"}
    ks.add_skill_doc(skill, doc)
    mark_gap(skill, gap, "fixed")
    _append_skill_note(skill, f"[修复缺口] 绑定知识库《{doc}》到专项，缺口已标记为已修复。")
    return {"ok": True, "doc": doc,
            "message": f"已绑定知识库《{doc}》到专项，缺口已标记为已修复。"}


# ---- ④ 文本回答：用户说明原因 → AI 按说明调整 SQL / 知识库 / 专项 / 预测模型 ----
# 与「一键修复」的区别：这是人→AI 的回路，用户用文字讲清缺口该怎么补、为什么这么改，
# AI 据此产出调整草稿（不落盘），人审后经 apply_gap_answer_draft 走留痕 writer 落盘。
# 四类 remedy_type（sql/kb/skill/model）× 两种 action（create/modify）统一成一种草稿结构：
#   kind ∈ sql|kb|skill|model，action ∈ create|modify，
#   sql 类放 `sql` 文本，其余三类放 `content` 正文，model 的 `meta` 只放 AI 打算改的配置键子集。

_INVALID_FILE_CHARS = re.compile(r'[\\/:*?"<>|]')


def _clean_name(name: str, limit: int = 24) -> str:
    """清理文件名里的非法字符并截断，供新建 SQL/文档/专项/模型名使用。"""
    name = re.sub(r"^#+\s*", "", (name or "").strip())  # 去掉 markdown 标题的 # 前缀
    name = re.sub(r"\s+", " ", name).strip()
    name = _INVALID_FILE_CHARS.sub("", name)
    return name[:limit]


def _merged_instruction(gap: dict, answer: str) -> str:
    """把缺口上下文与用户说明拼成一条调整指令。"""
    parts = []
    if (gap.get("issue") or "").strip():
        parts.append("缺口问题：" + gap["issue"].strip())
    if (gap.get("remedy_detail") or "").strip():
        parts.append("缺口建议：" + gap["remedy_detail"].strip())
    if (answer or "").strip():
        parts.append("用户说明（据此调整）：" + answer.strip())
    return "\n".join(parts)


def _valid_forecast(fc, game_key: str | None = None) -> str | None:
    """把 AI 给的预测能力绑定归一为命中候选的单一 id（兼容数组/字符串/null），无命中返回 None。

    只在「当前游戏/用户可见」的能力范围内校验，避免把他人「个人」模型绑进来。
    """
    ids = {c.get("id") for c in forecast.visible_capabilities(game_key)}
    if isinstance(fc, list):
        return next((f for f in fc if isinstance(f, str) and f in ids), None)
    return fc if isinstance(fc, str) and fc in ids else None


def _propose_doc_name(gap: dict, title: str = "") -> str:
    """从缺口/标题推导新文档名（裸名，不带 .md；write_doc/read_doc 自动补后缀）。"""
    name = _clean_name(title) or _clean_name(gap.get("remedy_target") or "") or "缺口补充"
    return name[:-3] if name.endswith(".md") else name


def _propose_model_name(gap: dict) -> str:
    """从缺口建议里推导新模型名。"""
    name = _clean_name(gap.get("remedy_target") or "")
    if not name:
        m = re.search(r"模型[：:]\s*([A-Za-z_][A-Za-z0-9_]{2,})", gap.get("remedy_detail") or "")
        name = m.group(1) if m else ""
    return name or "缺口模型"


# ---- 分发：生成调整草稿（不落盘）----

def resolve_gap_answer(model: str, game_key: str, db, engine, gap: dict, answer: str,
                       skill: str | None = None) -> dict:
    """用户用文字说明缺口怎么补，AI 按说明产出四类资产的调整草稿（仅草稿，不落盘）。"""
    rtype = gap.get("remedy_type")
    raction = gap.get("remedy_action") or "modify"
    instruction = _merged_instruction(gap, answer)
    if not instruction.strip():
        return {"action": "prompt", "message": "请先填写调整说明，再点「按说明调整」。"}
    try:
        if rtype == "sql":
            return _resolve_sql_answer(model, skill, gap, game_key, db, engine, instruction, raction)
        if rtype == "kb":
            return _resolve_kb_answer(model, gap, game_key, instruction, raction)
        if rtype == "skill":
            return _resolve_skill_answer(model, skill, gap, game_key, instruction, raction)
        if rtype == "model":
            return _resolve_model_answer(model, skill, gap, game_key, instruction, raction)
    except Exception as exc:
        return {"action": "prompt", "message": f"调整失败：{exc}"}
    return {"action": "prompt", "message": f"该缺口类型（{rtype}）暂不支持文本调整，请到对应页面手动处理。"}


def _resolve_sql_answer(model, skill, gap, game_key, db, engine, instruction, raction) -> dict:
    name = _sql_name(gap.get("remedy_target"))
    if raction == "create":
        if not skill:
            return {"action": "prompt", "message": "未关联专项，无法生成并绑定 SQL，请到「SQL数据」页手动新建。"}
        try:
            schema_text, ref_docs, _src = schema_context.build_sql_context(
                engine, db, game=game_key, question=instruction)
            sql, _ = generate_sql(model, schema_text, instruction, ref_docs)
        except Exception as exc:
            return {"action": "prompt", "message": f"SQL 生成失败：{exc}"}
        new_name = _propose_sql_name(gap)
        base = new_name[:-4] if new_name.endswith(".sql") else new_name
        i = 2
        while sql_store.read_sql(new_name).strip():
            new_name = f"{base}_{i}.sql"
            i += 1
        draft = {"kind": "sql", "action": "create", "name": new_name, "target": new_name,
                 "step": new_name[:-4] if new_name.endswith(".sql") else new_name,
                 "section": "🔍 明细下钻", "required": False, "sql": sql, "prompt": instruction}
        return {"action": "draft", "draft": draft,
                "message": "已按说明生成 SQL 草稿，请审阅后保存（将写入全局并绑定到专项）。"}
    global_sql = sql_store.read_sql(name)
    if not global_sql.strip():
        return {"action": "prompt", "message": f"未找到全局 SQL《{name}》，请先到「SQL数据」页确认。"}
    skill_text = _skill_text(skill)
    prompt = instruction
    if skill_text:
        prompt = (prompt + "\n\n改写时务必遵守专项方法说明（参考 Skill）里对时间窗口/口径的约定，"
                  "把 SQL 中与之不符的相对时间窗口改成专项约定的窗口。").strip()
    try:
        new_sql, _ = rewrite_sql(model, global_sql, [prompt], skill_text or None)
    except Exception as exc:
        return {"action": "prompt", "message": f"SQL 改写失败：{exc}"}
    violations = guard_rewrite(global_sql, new_sql)
    draft = {"kind": "sql", "action": "modify", "name": name, "target": name,
             "sql": new_sql, "prompt": instruction, "violations": violations}
    return {"action": "draft", "draft": draft,
            "message": "已按说明改写 SQL，请审阅后保存（将同步全局与专项快照）。"}


def _resolve_kb_answer(model, gap, game_key, instruction, raction) -> dict:
    name = (gap.get("remedy_target") or "").strip()
    if name.endswith(".md"):
        name = name[:-3]
    existing = ks.read_doc(name) if name else ""
    if raction != "modify" or not existing.strip():
        try:
            draft_text, title = kb_gen.summarize(
                model, [{"name": "缺口说明", "content": instruction}], extra=instruction)
        except Exception as exc:
            return {"action": "prompt", "message": f"知识库生成失败：{exc}"}
        new_name = _propose_doc_name(gap, title)
        draft = {"kind": "kb", "action": "create", "name": new_name, "target": new_name,
                 "content": draft_text, "prompt": instruction}
        return {"action": "draft", "draft": draft,
                "message": "已按说明生成知识库文档草稿，请审阅后保存。"}
    try:
        draft_text, _ = kb_gen.summarize(
            model, [{"name": "缺口说明", "content": instruction}], extra=instruction, existing=existing)
    except Exception as exc:
        return {"action": "prompt", "message": f"知识库改写失败：{exc}"}
    draft = {"kind": "kb", "action": "modify", "name": name, "target": name,
             "content": draft_text, "prompt": instruction}
    return {"action": "draft", "draft": draft,
            "message": "已按说明改写知识库文档，请审阅后保存。"}


def _resolve_skill_answer(model, skill, gap, game_key, instruction, raction) -> dict:
    name = (gap.get("remedy_target") or "").strip() or (skill or "").strip()
    if not name:
        return {"action": "prompt", "message": "未指明要调整的专项，且当前未关联专项，请到专项页手动处理。"}
    existing = ks.read_skill(name) if ks.read_skill(name).strip() else ""
    if raction == "create":
        existing = ""
    sql_names = sql_store.list_sql_files(game_key)
    doc_names = ks.list_docs(game_key)
    forecast_caps = [c for c in forecast.visible_capabilities(game_key) if c.get("input") == "sql"]
    description = instruction
    if raction != "create":
        description = (instruction + f"\n\n（目标专项《{name}》：请在其基础上按上述说明增删改，"
                       "保持原有报告结构/章节组织不变，只调整说明要求的部分。）").strip()
    try:
        result = kb_gen.summarize_skill(model, description, sql_names, doc_names,
                                        existing=existing, forecast_caps=forecast_caps)
    except Exception as exc:
        return {"action": "prompt", "message": f"专项调整失败：{exc}"}
    sqls = [s for s in (result.get("sqls") or []) if sql_store.read_sql(s).strip()]
    docs = [d for d in (result.get("docs") or []) if ks.read_doc(d).strip()]
    fc = _valid_forecast(result.get("forecast"), game_key)
    target_name = name if raction != "create" else ((result.get("title") or "").strip() or name)
    draft = {"kind": "skill", "action": raction, "name": target_name, "target": name,
             "content": result.get("content") or "", "prompt": instruction,
             "meta": {"sqls": sqls, "docs": docs, "forecast": fc}}
    return {"action": "draft", "draft": draft,
            "message": "已按说明调整专项（正文与绑定），请审阅后保存。"}


def _resolve_model_answer(model, skill, gap, game_key, instruction, raction) -> dict:
    name = (gap.get("remedy_target") or "").strip()
    existing_meta = code_store.read_code_meta(name) if name else {}
    existing_code = code_store.read_code(name) if name else ""
    if raction == "modify" and not existing_code.strip():
        raction = "create"
    bound_sql_names: list[str] = []
    doc_names: list[str] = []
    if skill:
        smeta = ks.read_skill_meta(skill)
        bound_sql_names = list(smeta.get("sqls") or [])
        doc_names = list(smeta.get("docs") or [])
    if name and name.endswith(".sql") and name not in bound_sql_names:
        bound_sql_names = [name]
    try:
        result = model_gen.generate_model(model, instruction, bound_sql_names, doc_names,
                                          existing=existing_code if raction == "modify" else "")
    except Exception as exc:
        return {"action": "prompt", "message": f"模型生成失败：{exc}"}
    bind_sql = ""
    if raction == "modify" and existing_meta.get("sql"):
        bind_sql = existing_meta.get("sql")
    elif bound_sql_names:
        bind_sql = bound_sql_names[0]
    draft = {"kind": "model", "action": raction, "name": name or _propose_model_name(gap),
             "target": name, "content": result.get("code") or "", "prompt": instruction,
             "violations": result.get("problems") or [],
             "meta": {"sql": bind_sql, "desc": instruction[:80]},
             "sources": result.get("sources") or [],
             "transformed_sqls": result.get("transformed_sqls") or {}}
    return {"action": "draft", "draft": draft,
            "message": "已按说明调整预测模型，请审阅后保存。"}


# ---- 草稿落盘（人审通过后，走留痕 writer）----

def apply_gap_answer_draft(skill: str | None, draft: dict, gap: dict, model: str | None,
                           game_key, db, engine) -> dict:
    """保存文本调整草稿：按 kind 分派到四类资产，全部走版本化 writer 留痕。"""
    kind = draft.get("kind")
    if kind == "sql":
        result = _apply_sql_answer(skill, draft, model, game_key)
    elif kind == "kb":
        result = _apply_kb_answer(skill, draft, game_key)
    elif kind == "skill":
        result = _apply_skill_answer(skill, draft, game_key)
    elif kind == "model":
        result = _apply_model_answer(skill, draft, game_key)
    else:
        return {"ok": False, "message": f"未知草稿类型 {kind}"}
    if result.get("ok") and skill:
        mark_gap(skill, gap, "fixed")
    return result


def _apply_sql_answer(skill: str | None, draft: dict, model: str | None, game_key) -> dict:
    """SQL 类草稿落盘：复用现有 _apply_create / _apply_modify（改 kind 后透传）。"""
    if draft.get("action") == "create":
        d = dict(draft)
        d["kind"] = "sql_create"
        return _apply_create(skill, d, game_key)
    d = dict(draft)
    d["kind"] = "sql_modify"
    return _apply_modify(skill, d, model, game_key=game_key)


def _apply_kb_answer(skill: str | None, draft: dict, game_key) -> dict:
    name = _clean_name(draft.get("name") or draft.get("target") or "")
    content = (draft.get("content") or "").strip()
    if not name or not content:
        return {"ok": False, "message": "草稿缺少文档名称或内容"}
    if name.endswith(".md"):
        name = name[:-3]
    # 对抗审查三轮 F0：既有文档按可见性闸门（个人级仅归属用户/项目级同族），
    # 且覆写时保留其原有 level/game/owner（此前无条件重写 meta，同族成员可把
    # 项目级文档升为「通用」扩大可见面，或销毁他人个人级隔离）。
    if ks.read_doc(name).strip():
        meta = ks.read_doc_meta(name)
        if not visible_to(meta.get("level"), meta.get("game"), game_key,
                          meta.get("owner"), current_owner_key()):
            return {"ok": False, "message": f"文档《{name}》属于其他游戏或用户，无权覆盖。"}
        ks.write_doc(name, content)
    else:
        ks.write_doc(name, content)
        smeta = ks.read_skill_meta(skill) if skill else {}
        level = smeta.get("level") or "通用"
        ks.write_doc_meta(name, {"level": level, "game": smeta.get("game") or game_key,
                                  "owner": current_owner_key() if level == "个人" else None})
    if skill:
        ks.add_skill_doc(skill, name)
    return {"ok": True, "kind": "kb", "action": draft.get("action"), "name": name,
            "message": f"已保存知识库文档《{name}》" + ("并绑定到专项。" if skill else "。")}


def _apply_skill_answer(skill: str | None, draft: dict, game_key) -> dict:
    name = _clean_name(draft.get("name") or draft.get("target") or "")
    content = (draft.get("content") or "").strip()
    if not name or not content:
        return {"ok": False, "message": "草稿缺少专项名称或正文"}
    existing_meta = ks.read_skill_meta(name)
    # 对抗审查三轮 F0：目标专项名与关联专项（body.skill）可不同，闸门只看 body.skill
    # 挡不住按 draft.name 覆写他人专项正文——对目标专项单独做可见性校验。
    if ks.read_skill(name).strip():
        if not visible_to(existing_meta.get("level"), existing_meta.get("game"), game_key,
                          existing_meta.get("owner"), current_owner_key()):
            return {"ok": False, "message": f"专项「{name}」属于其他游戏或用户，无权覆盖。"}
    want = draft.get("meta") or {}
    # 护栏：只绑定真实存在的 SQL/文档，避免把幻觉文件名写进绑定表
    new_sqls = [s for s in (want.get("sqls") or []) if s and sql_store.read_sql(s).strip()]
    new_docs = [d for d in (want.get("docs") or []) if d and ks.read_doc(d).strip()]
    fc = _valid_forecast(want.get("forecast"), game_key)
    # 关键：read_skill_meta 的 sqls 由 steps 推导，改绑定时必须同步重写 steps，
    # 否则下次读取会把 sqls 覆盖回 steps 旧值。保留旧步骤名，新增 SQL 用文件名当步骤名。
    old_steps = existing_meta.get("steps") or []
    step_by_sql = {st["sql"]: st for st in old_steps if isinstance(st, dict) and st.get("sql")}
    steps = []
    for s in new_sqls:
        if s in step_by_sql:
            steps.append({"name": step_by_sql[s].get("name") or s, "sql": s,
                          "required": bool(step_by_sql[s].get("required", True))})
        else:
            steps.append({"name": s, "sql": s, "required": False})
    meta = {
        "sqls": new_sqls,
        "docs": new_docs,
        "steps": steps,
        "forecast": fc,
        "level": existing_meta.get("level"),
        "game": existing_meta.get("game"),
        "owner": existing_meta.get("owner"),
        "summary": existing_meta.get("summary"),
        "online": ks.online_on_save(name),
    }
    ks.write_skill(name, content)
    ks.write_skill_meta(name, meta)
    return {"ok": True, "kind": "skill", "action": draft.get("action"), "name": name,
            "message": f"已调整专项《{name}》（正文与绑定已更新）。"}


def _apply_model_answer(skill: str | None, draft: dict, game_key) -> dict:
    name = _clean_name(draft.get("name") or draft.get("target") or "")
    code = (draft.get("content") or "").strip()
    if not name or not code:
        return {"ok": False, "message": "草稿缺少模型名称或代码"}
    problems = model_gen.precheck_code(code)
    if problems:
        return {"ok": False, "message": "代码未通过安全预检：" + "；".join(problems)}
    if forecast.is_builtin(name):
        return {"ok": False, "message": f"「{name}」为内置能力，不可覆盖。"}
    existing_meta = code_store.read_code_meta(name)
    if not visible_to(existing_meta.get("level"), existing_meta.get("game"), game_key,
                      existing_meta.get("owner"), current_owner_key()):
        return {"ok": False, "message": f"「{name}」属于其他游戏或用户，无权覆盖。"}

    action = draft.get("action")
    dmeta = draft.get("meta") or {}
    bind_sql = (dmeta.get("sql") or "").strip()
    if bind_sql and not sql_store.read_sql(bind_sql).strip():
        bind_sql = ""
    if action == "modify":
        level = existing_meta.get("level") or "通用"
        meta_game = existing_meta.get("game")
        input_type = existing_meta.get("input") or "sql"
        granularity = existing_meta.get("granularity") or "day"
    else:
        level = "通用"
        meta_game = None
        input_type = "sql" if bind_sql else "upload"
        granularity = "day"
    # 配置键只从 read_code_meta 起步合并，level/game 绝不取前端回传，防伪造越权
    meta = {
        "name": (dmeta.get("desc") or name),
        "desc": (dmeta.get("desc") or ""),
        "input": input_type,
        "granularity": granularity,
        "sql": bind_sql,
        "level": level,
        "game": meta_game,
    }
    for k in ("hist_days", "hist_months", "horizon_days", "horizon_months", "window"):
        if existing_meta.get(k) is not None:
            meta[k] = existing_meta[k]
    if draft.get("sources"):
        meta["sources"] = draft["sources"]

    code_store.write_code(name, code)
    transformed = (draft.get("transformed_sqls") or {}).get(bind_sql)
    if transformed and transformed.strip():
        code_store.write_model_sql(name, transformed)
        meta["sql_transformed"] = True
        meta["sql_source"] = bind_sql
    else:
        code_store.delete_model_sql(name)
        meta.pop("sql_transformed", None)
    code_store.write_code_meta(name, meta)
    forecast.load_external_capabilities()
    return {"ok": True, "kind": "model", "action": action, "name": name,
            "message": f"已保存预测模型《{name}》。"}
