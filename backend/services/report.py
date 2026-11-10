"""三阶段交叉验证报告流水线：改写 SQL → 执行 → 生成 → 验证 → 汇总 → 存档。

把 game_analytics/webapp/pages/3_运行报告.py 的串行流程移植为事件生成器：
每个产出是 {"type": ...} 字典，由 routers/reports.py 序列化为 SSE。
事件类型：stage（进度）、markdown（各轮结论）、report（最终结果汇总）、error。
"""
import json
import time
from datetime import datetime, timezone
from pathlib import Path

from analysis import knowledge_store as ks
from analysis import sql_store
from analysis.atomic import atomic_write_text
from analysis.db import run_raw_sql
from analysis.games import owner_key
from analysis.prompts import build_data_block
from analysis.sql_rewriter import rewrite_sql, validate_sql
from analysis.time_range import apply_date_range

from .. import config
from ..deps import get_engine
from . import games, report_config
from .report_analyze import run_three_model


def _reports_dir() -> Path:
    return config.DATA_AI_ROOT / "reports"


def run_report_pipeline(params: dict):
    """生成器：逐步产出事件 dict。params 字段见 routers/reports.py 的 ReportRunReq。"""
    sqls = params["sqls"]
    mods = params.get("mods", {}) or {}
    skill = params.get("skill") or None
    docs = params.get("docs", []) or []
    extra_prompt = params.get("extra_prompt", "") or ""
    start_date = params.get("start_date") or None
    end_date = params.get("end_date") or None
    subscription_id = params.get("subscription_id") or None
    source = params.get("source") or ("subscription" if subscription_id else "manual")
    game = params.get("game") or {}
    game_key = game.get("key")
    game_db = game.get("db")
    user = params.get("user")

    cfg = report_config.read_report_config()
    # 【模型名校验】params 来自 ReportRunReq，model_gen/ver/sum 无任何模型名校验；客户端若直接
    # 传占位/已下线模型名（如 x/y/z），会绕过 read_report_config 的校验一路打到网关触发 ~290s
    # 挂起（与专项/聊天跑报告同根因）。这里与 read 端用同一套可用列表校验：非法/空值回落任务默认。
    valid_models = set(config.available_models())

    def _model(key: str) -> str:
        v = params.get(key)
        return v if (v and v in valid_models) else cfg[key]

    model_gen = _model("model_gen")
    model_ver = _model("model_ver")
    model_sum = _model("model_sum")

    skill_texts = [ks.read_skill(skill)] if skill else []
    if skill:
        notes = ks.read_skill_notes(skill)
        if notes.strip():
            skill_texts.append(f"# 本专项补充口径与经验（专项笔记）\n\n{notes}")
    doc_texts = [(d, ks.read_doc(d)) for d in docs if d in ks.list_docs(game_key)]

    # 步骤 1/5：AI 改写 SQL
    yield {"type": "stage", "stage": "rewrite", "message": "步骤 1/5：AI 改写 SQL"}
    t0 = time.time()
    rewritten = {}
    for sql_name in sqls:
        meta = sql_store.read_sql_meta(sql_name)
        original = sql_store.read_sql(sql_name)
        if start_date or end_date:
            original = apply_date_range(original, start_date, end_date)
        checked = [m for m in meta["modifications"] if m.get("id") in (mods.get(sql_name) or [])]
        if checked:
            bound_text = f"# 本次运行分析方法 Skill：{skill}\n\n{ks.read_skill(skill)}" if skill else None
            try:
                new_sql, _ = rewrite_sql(
                    model_gen, original, [m.get("prompt") for m in checked], bound_text
                )
            except Exception as e:
                yield {"type": "stage", "stage": "rewrite",
                       "message": f"⚠️ {sql_name} 改写失败：{e}，已改用原 SQL"}
                rewritten[sql_name] = {"sql": original, "mode": "original", "mods": []}
            else:
                yield {"type": "stage", "stage": "rewrite",
                       "message": f"✅ {sql_name} 已按修改描述改写"}
                rewritten[sql_name] = {
                    "sql": new_sql,
                    "mode": "ai",
                    "mods": [m.get("name") or m.get("prompt") or "" for m in checked],
                }
        else:
            rewritten[sql_name] = {"sql": original, "mode": "original", "mods": []}
            yield {"type": "stage", "stage": "rewrite", "message": f"ℹ️ {sql_name} 使用原 SQL"}
    yield {"type": "stage", "stage": "rewrite", "message": f"步骤 1/5 完成（{time.time() - t0:.1f}s）"}

    # 步骤 2/5：执行查询
    yield {"type": "stage", "stage": "query", "message": "步骤 2/5：执行查询"}
    t0 = time.time()
    query_results = {}
    try:
        engine = get_engine()
    except Exception as e:
        engine = None
        yield {"type": "stage", "stage": "query", "message": f"❌ 数据库连接失败：{e}"}
    if engine is not None:
        for sql_name, item in rewritten.items():
            try:
                validate_sql(item["sql"])  # 只读校验（含 mode="original" 的既有 SQL）
                df = run_raw_sql(engine, games.apply_sql(item["sql"], game_db))
            except Exception as e:
                yield {"type": "stage", "stage": "query",
                       "message": f"❌ {sql_name} 执行失败：{e}"}
            else:
                query_results[sql_name] = df
                yield {"type": "stage", "stage": "query", "message": f"✅ {sql_name}：{len(df)} 行"}
    if not query_results:
        yield {"type": "error", "message": "所有查询均执行失败，无法继续分析"}
        return
    yield {"type": "stage", "stage": "query", "message": f"步骤 2/5 完成（{time.time() - t0:.1f}s）"}

    data_block = build_data_block(query_results)

    # 步骤 3-5/5：三模型交叉验证（生成 → 验证 → 汇总）
    yield {"type": "stage", "stage": "analyze", "message": "步骤 3/5：三模型交叉验证（生成 → 验证 → 汇总）"}
    gen, ver, fin = yield from run_three_model(
        data_block, skill_texts, doc_texts, extra_prompt,
        cfg={"model_gen": model_gen, "model_ver": model_ver, "model_sum": model_sum},
        user=user,
        deep_thinking=bool(params.get("deep_thinking")),
    )
    if gen is None:
        return

    # ---- 存档 ----
    generated_at = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    run_id = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    output_dir = _reports_dir() / run_id
    output_dir.mkdir(parents=True, exist_ok=True)

    report_md = ""
    generate_md = ""
    verify_md = ""
    if fin:
        report_lines = [
            "# 游戏流水分析报告",
            "",
            f"生成时间：{generated_at}",
            f"使用模型：生成 {model_gen} → 验证 {model_ver} → 汇总 {model_sum}",
            f"专项：{skill if skill else '无'}",
            f"参考文档：{', '.join(docs) if docs else '无'}",
        ]
        if start_date and end_date:
            report_lines.append(f"数据区间：{start_date} ～ {end_date}")
        report_lines += [
            "",
            "## 最终报告",
            "",
            fin,
            "",
            "## 附录：查询结果",
            "",
        ]
        for sql_name, df in query_results.items():
            report_lines += [
                f"### {sql_name}",
                "",
                df.to_markdown(index=False) if not df.empty else "_该查询无数据_",
                "",
            ]
        report_md = "\n".join(report_lines)
        atomic_write_text(output_dir / "report.md", report_md, encoding="utf-8")

    if gen:
        generate_md = f"# 生成轮结论（模型：{model_gen}）\n\n{gen}"
        atomic_write_text(output_dir / "generate.md", generate_md, encoding="utf-8")
    if ver:
        verify_md = f"# 验证轮审核意见（模型：{model_ver}）\n\n{ver}"
        atomic_write_text(output_dir / "verify.md", verify_md, encoding="utf-8")

    run_meta = {
        "generated_at": generated_at,
        "models": {"generate": model_gen, "verify": model_ver, "summarize": model_sum},
        "selected_sql": sqls,
        "sql_mods": {
            sql_name: {"mode": rewritten[sql_name]["mode"], "mods": rewritten[sql_name]["mods"]}
            for sql_name in sqls
            if sql_name in rewritten
        },
        "skill": skill,
        "selected_docs": docs,
        "extra_prompt": extra_prompt,
        "start_date": start_date,
        "end_date": end_date,
        "subscription_id": subscription_id,
        "source": source,
        "game": game_key,
        "owner": owner_key(user),  # 归属人：历史报告按用户隔离（个人级仅本人可见；通用级同族可见）
    }
    atomic_write_text(
        output_dir / "run_meta.json",
        json.dumps(run_meta, ensure_ascii=False, indent=2), encoding="utf-8",
    )

    yield {
        "type": "report",
        "run_id": run_id,
        "report_md": report_md,
        "generate_md": generate_md,
        "verify_md": verify_md,
    }
