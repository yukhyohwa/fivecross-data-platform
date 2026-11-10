"""写 SQL 的上下文解析：优先用知识库里的「表结构文档」「指标口径说明」，缺失再扫真实表。

- 表结构文档（名称含「表结构」/「schema」等）→ 直接用其内容当 schema 上下文，不再扫库；
- 指标口径说明（名称含「指标口径」/「口径」等）→ 作为业务口径参考附上。
"""
from analysis import knowledge_store as ks
from analysis import glossary
from analysis import metrics
from analysis.prompts import frame_ref

from . import games as games_svc
from . import schema as schema_svc

_SCHEMA_KEYWORDS = ["表结构", "schema", "字段说明"]
_METRIC_KEYWORDS = ["指标口径", "口径", "指标说明"]


def _find_doc(names, keywords):
    for n in names:
        low = n.lower()
        for k in keywords:
            if k.lower() in low:
                return n
    return None


def _find_doc_retrieval(query_text, names, keywords):
    """先关键词撞名（保留旧行为），无命中时用检索层按语义相关性兜底取 top-1。"""
    hit = _find_doc(names, keywords)
    if hit:
        return hit
    try:
        from analysis import retrieval
        allowed = set(names)
        for r in retrieval.query(query_text, ["doc"], k=5):
            if r["id"] in allowed:
                return r["id"]
    except Exception:  # noqa: BLE001 —— 检索不可用时回退 None（走扫库），不阻断
        pass
    return None


def build_sql_context(engine, target_db, game=None, question=None, user=None):
    """返回 (schema_text, ref_docs, source)。

    - schema_text：表结构上下文（文档内容，或真实扫表汇总）；
    - ref_docs：[(文档名, 全文)] 口径参考；
    - source：表结构上下文来源描述（用于过程展示）。

    question 非空时，额外从全量表结构知识库（knowledge/table_schema/table_schema.json，
    704 张同名表含字段描述/字典）按问题检索 top-k 相关表拼进 schema_text——只注入相关表，
    避免 2MB 全文撑爆上下文。

    user 非空时（审计 P1-1），指标口径优先注入用户在指标库确认过的指标
    （indicator_hint，definition+canonical_sql），无命中再回退内置 metrics.json。
    """
    docs = ks.list_docs(game)
    schema_doc = _find_doc_retrieval("表结构 schema 字段说明", docs, _SCHEMA_KEYWORDS)
    metric_doc = _find_doc_retrieval("指标口径 指标说明", docs, _METRIC_KEYWORDS)

    if schema_doc:
        # 表结构文档是知识库外部存储内容，进 prompt 前包防注入 framing（审计 P1-19）
        schema_text = frame_ref(f"表结构文档（知识库）《{schema_doc}》", ks.read_doc(schema_doc))
        source = f"知识库「{schema_doc}」"
    else:
        schema, total = schema_svc.load_core_schema(engine, target_db)
        schema_text = schema_svc.schema_summary(schema, target_db, total)
        source = "真实数据库表结构"

    ref_docs = []
    if metric_doc:
        ref_docs.append((metric_doc, ks.read_doc(metric_doc)))
    # 追加时区口径：当前库的 active 视图需按 tz 过滤（rooc / rooc_am 各有固定 tz）
    tz_hint = games_svc.active_view_tz_hint(target_db)
    if tz_hint:
        schema_text = (schema_text or "").rstrip() + "\n\n" + tz_hint
    # 追加全量表结构知识库检索结果（字段描述/字典），仅当提供了问题
    if question:
        try:
            from . import table_schema
            ktabs = table_schema.query_tables(question, game, k=12)
            if ktabs:
                extra = table_schema.tables_to_text(ktabs, target_db)
                # 全量表结构检索结果同样是外部存储内容，包防注入 framing（审计 P1-19）
                extra = frame_ref("全量表结构检索结果（字段描述/字典）", extra)
                schema_text = ((schema_text or "").rstrip() + "\n\n" + extra).strip()
        except Exception:  # noqa: BLE001 —— 检索失败不阻断，回退纯扫库/文档
            pass
    # 追加术语表/同义词（schema linking 兜底）：有内容才注入，缺失/异常不阻断写 SQL
    gh = glossary.glossary_hint()
    if gh:
        # 术语表属外部存储内容，包防注入 framing（审计 P1-19）
        schema_text = (schema_text or "").rstrip() + frame_ref("术语表/同义词（schema linking 兜底）", gh)
    # 追加机器可读指标层（指标语义层）：按问题命中注入指标公式，避免口径漂移。
    # 审计 P1-1：优先「已确认指标」（ide_data.db，用户人工确认过的口径），无命中再回退
    # metrics.json 内置层——避免两套指标口径双源漂移。
    from . import indicator_hint
    # game 约定为游戏 key 字符串（所有调用方均传 game["key"]/game_key），
    # 兼容个别传入 dict 的调用方：dict 取 key，str 原样用
    game_key = game.get("key") if isinstance(game, dict) else game
    mh = indicator_hint.indicator_hint(question, user, game_key) or metrics.metrics_hint(question)
    if mh:
        # 指标定义（已确认指标 / 内置 metrics.json）属外部存储内容，包防注入 framing（审计 P1-19）
        schema_text = (schema_text or "").rstrip() + frame_ref("指标口径参考", mh)
    return schema_text, ref_docs, source
