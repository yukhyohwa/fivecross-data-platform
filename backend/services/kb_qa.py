"""知识库问答通道：检索知识库文档 → 总结作答（纯文本，不取数、不生成 SQL）。

对应对话四通道路由的「知识/口径」通道：用户问指标口径、字段定义、计算规则、分析方法时，
直接检索知识库相关文档作答，与取数/专项/算法通道完全独立。
"""
from analysis import knowledge_store as ks
from analysis import retrieval
from analysis.prompts import frame_ref
from .llm import complete_with_fallback

_SYSTEM = (
    "你是游戏数据分析知识助手。基于给定的知识库文档内容，直接、准确地回答用户关于"
    "指标口径、字段定义、计算规则、分析方法的问题。要求：只依据给出的文档作答，不要臆测；"
    "文档没有覆盖到的部分要明确说明；关键口径尽量保留原文定义。输出简洁的 Markdown。"
)


def _retrieve_docs(question: str, game: str | None = None, k: int = 5) -> list[str]:
    """检索 top-k 相关文档名；检索层不可用时退化为取列表前 k（保证不崩）。"""
    try:
        return [r["id"] for r in retrieval.query(question, ["doc"], k=k, game=game)]
    except Exception:  # noqa: BLE001 —— 检索不可用时不阻断
        return ks.list_docs(game)[:k]


def answer_knowledge(model: str, question: str, game: str | None = None, history: str | None = None, user: dict | None = None) -> str:
    """检索知识库文档并总结作答，返回 Markdown 文本。

    history 为已拼好的对话历史文本；提供时一并带入，让 AI 结合多轮上下文判断
    （对应「命中知识库时把聊天内容带进去一起处理」）。
    """
    docs = _retrieve_docs(question, game)
    pairs = [(d, ks.read_doc(d)) for d in docs if ks.read_doc(d).strip()]
    if not pairs:
        return "知识库里暂时没有与这个问题直接相关的内容。你可以先在「知识库」页补充对应口径文档，再回来问我。"
    # 进 prompt 的检索文档包防注入 framing（审计 P1-19）；raw_parts 留给兜底直出（给用户看，不带 framing）
    parts = [frame_ref(f"### 《{d}》", content) for d, content in pairs]
    raw_parts = [f"### 《{d}》\n\n{content.strip()}" for d, content in pairs]
    user_prompt = "\n\n---\n\n".join(parts) + "\n\n# 用户问题\n\n" + question.strip()
    if history and history.strip():
        user_prompt = history.strip() + "\n\n" + user_prompt
    try:
        text, _ = complete_with_fallback(
            model=model,
            messages=[{"role": "system", "content": _SYSTEM},
                      {"role": "user", "content": user_prompt}],
            user=user,
        )
    except Exception:
        # 模型不可用时直接拼接文档内容兜底（仍返回有用信息，不崩）
        return "\n\n---\n\n".join(raw_parts)
    return text
