"""聊天后自动「提炼建议」：把一轮数据对话生成 SQL / 知识库 / 专项 草稿，供前端一键确认保存/合并。

- build_suggestion：本轮结果 → 三种草稿（SQL 直接复用已执行 SQL；知识库/专项各一次 LLM 调用）。
- build_merge：把本轮对话合并进某个既有专项/知识库/SQL（复用各生成函数的 existing= 参数）。
"""
import logging
import re

from analysis import knowledge_store as ks
from analysis import sql_store

from . import kb_summarize, schema_context, sql_cache, sql_gen

logger = logging.getLogger(__name__)

_ILLEGAL = re.compile(r'[\\/:*?"<>|]')


def _clean_name(text: str, default: str = "AI提炼") -> str:
    name = _ILLEGAL.sub("_", (text or "").strip()).strip()[:60]
    return name or default


def _unique_name(name: str, existing: list[str]) -> str:
    if name not in existing:
        return name
    # 扩展名感知：让计数后缀落在扩展名之前（如 foo-2.sql 而非 foo.sql-2）
    stem, dot, ext = name.rpartition(".")
    i = 2
    while True:
        candidate = f"{stem}-{i}.{ext}" if dot else f"{name}-{i}"
        if candidate not in existing:
            return candidate
        i += 1


def _turn_text(question: str, sql: str, answer: str) -> str:
    """把本轮（问题 + SQL + 解读）拼成一段文本，供知识库合并等场景使用。"""
    parts = [f"【用户提问】{question.strip()}"]
    if sql and sql.strip():
        parts.append(f"【执行的 SQL】\n```sql\n{sql.strip()}\n```")
    if answer and answer.strip():
        parts.append(f"【AI 解读】\n{answer.strip()}")
    return "\n\n".join(parts)


def _turn_messages(question: str, sql: str, answer: str) -> list[dict]:
    return [
        {"role": "user", "text": question},
        {"role": "assistant", "text": answer or "", "sql": sql or ""},
    ]


def _skill_description(question: str, sql: str) -> str:
    desc = (question or "").strip()
    if sql and sql.strip():
        desc += "\n\n本轮执行的 SQL：\n```sql\n" + sql.strip() + "\n```"
    return desc


def build_suggestion(model: str, *, skill: str | None, question: str, sql: str, answer: str, game_key: str,
                     kinds: list[str] | None = None) -> dict:
    """生成本轮的四类草稿建议，返回 {sql, doc, skill, model}（每项为 None 或 {action,target,name,draft,...}）。

    任何一项生成失败仅该项置 None，不影响其它项；调用方据返回值决定是否下发 suggest 事件。
    kinds 非空时只提炼指定类别（sql/doc/skill），省 LLM 调用；model 草稿始终由调用方单独补发。
    """
    only = set(kinds) if kinds else None
    sql_names = sql_store.list_sql_files(game_key)
    doc_names = ks.list_docs(game_key)
    skill_names = ks.list_online_skills(game_key)
    result: dict = {"sql": None, "doc": None, "skill": None, "model": None}

    # 1) SQL：直接复用本轮已执行 SQL（与任一已有 SQL 内容相同则视为已存在，不重复建议）
    if (not only or "sql" in only) and sql and sql.strip():
        existing_texts = {sql_store.read_sql(n).strip() for n in sql_names}
        if sql.strip() not in existing_texts:
            base = _clean_name(question, "AI提炼").removesuffix(".sql")
            name = _unique_name(base + ".sql", sql_names)
            result["sql"] = {"action": "new", "target": None, "name": name, "draft": sql.strip()}

    # 2) 知识库草稿（新建）
    if not only or "doc" in only:
        try:
            draft, title = kb_summarize.summarize_chat(model, _turn_messages(question, sql, answer), "docs")
            result["doc"] = {"action": "new", "target": None, "name": _unique_name(_clean_name(title, "AI提炼"), doc_names), "draft": draft}
        except Exception:
            pass

    # 3) 专项草稿：选了专项 → 优化既有专项；否则新建专项
    if not only or "skill" in only:
        try:
            # 评审 A3：skill 必须先在该游戏范围内可见（哨兵模式恢复出的 game_key），
            # 否则 read_skill 会读到其它游戏/他人的专项并生成合并草稿
            if skill and skill in skill_names:
                merged = kb_summarize.summarize_skill(
                    model, _skill_description(question, sql), sql_names, doc_names, existing=ks.read_skill(skill)
                )
                result["skill"] = {
                    "action": "update", "target": skill, "name": skill,
                    "draft": merged["content"], "sqls": merged["sqls"], "docs": merged["docs"],
                }
            else:
                draft, title = kb_summarize.summarize_chat(model, _turn_messages(question, sql, answer), "skills")
                result["skill"] = {"action": "new", "target": None, "name": _unique_name(_clean_name(title, "AI提炼"), skill_names), "draft": draft}
        except Exception:
            pass

    return result


def build_merge(model: str, *, kind: str, target: str, question: str, sql: str, answer: str, game_key: str, db: str, engine) -> dict:
    """把本轮对话合并进某个既有目标，返回合并后的草稿（前端展示后再写回 target）。

    kind: sql | docs | skills。
    """
    if kind == "sql":
        schema_text, _, _ = schema_context.build_sql_context(engine, db, game_key, question=question)
        # 审计 P2-15：SQL 合并生成短 TTL 缓存——重复合并请求（同 question/game/schema/底稿 SQL）
        # 直接复用上次生成结果，跳过 LLM 全量重生成。底稿 SQL 全文进 extra 摘要：底稿被改过
        # 即自然换键，不会命中旧结果（SQL 资产写盘另有 invalidate(game_key) 兜底）。
        existing_text = sql_store.read_sql(target)
        cache_key = sql_cache.make_key(
            question, game_key, schema_text,
            extra_context=sql_cache.context_digest(model, target, existing_text),
        )
        cached = sql_cache.get(cache_key)
        if cached is not None:
            merged, _cache_meta = cached
            logger.info(
                "「审计 P2-15」build_merge(sql) 缓存命中：question=%r game=%s target=%s",
                question, game_key, target,
            )
        else:
            merged, _ = sql_gen.generate_sql(model, schema_text, question, None, existing=existing_text)
            sql_cache.put(cache_key, (merged, {"source": "refine_build_merge"}), game_key=game_key)
        return {"kind": kind, "target": target, "name": target, "draft": merged}
    if kind == "docs":
        draft, _ = kb_summarize.summarize(
            model, [{"name": "本轮对话", "content": _turn_text(question, sql, answer)}], existing=ks.read_doc(target)
        )
        return {"kind": kind, "target": target, "name": target, "draft": draft}
    if kind == "skills":
        sql_names = sql_store.list_sql_files(game_key)
        doc_names = ks.list_docs(game_key)
        merged = kb_summarize.summarize_skill(
            model, _skill_description(question, sql), sql_names, doc_names, existing=ks.read_skill(target)
        )
        return {"kind": kind, "target": target, "name": target, "draft": merged["content"], "sqls": merged["sqls"], "docs": merged["docs"]}
    if kind == "models":
        from analysis import code_store, model_gen
        meta = code_store.read_code_meta(target)
        bound_sqls = [meta.get("sql")] if isinstance(meta, dict) and meta.get("sql") else []
        doc_names = [s.get("name") for s in (meta.get("sources") or []) if isinstance(s, dict) and s.get("kind") == "doc"]
        result = model_gen.generate_model(
            model, question, bound_sqls, doc_names, existing=code_store.read_code(target)
        )
        return {
            "kind": kind, "target": target, "name": target, "draft": result["code"],
            "transformed_sqls": result["transformed_sqls"], "sources": result["sources"],
        }
    raise ValueError(f"未知 kind：{kind}")
