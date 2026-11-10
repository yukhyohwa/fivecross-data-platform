"""统一工件读取门面：把知识库 / SQL / 模型代码 / 专项 / 报告 统一成「内容 + manifest + deps」，
供下游 agent 用 typed reader 消费，而非直接读原文、靠 LLM 肉眼比对。

每种工件的存储后端与 manifest：
- doc    → knowledge_store.read_doc + read_doc_meta
- sql    → sql_store.read_sql + read_sql_meta（另解析头部注释里的结构化字段）
- model  → code_store.read_code + read_code_meta
- skill  → knowledge_store.read_skill + read_skill_meta
- report → reports/<run_id>/report.md + run_meta.json

【canonical id】所有工件的统一 id 是不带后缀的裸名（doc/sql/model/skill 统一裸名），
方便 retrieval 的依赖图跨种类对齐（skill.sqls 里带 .sql、docs 里不带 .md 的不一致在此归一）。
"""
from __future__ import annotations

import json
from pathlib import Path

from . import code_store, knowledge_store, sql_store

KINDS = ("doc", "sql", "model", "skill", "report")

# 各 kind 的文件后缀（用于归一裸名）
_SUFFIXES = {"doc": ".md", "sql": ".sql", "model": ".py", "skill": ".md"}

_REPORTS_DIR = Path(__file__).resolve().parent.parent / "reports"


def _bare(name: str, kind: str) -> str:
    """把名字归一到不带后缀的裸名。"""
    name = (name or "").strip()
    suffix = _SUFFIXES.get(kind)
    if suffix and name.endswith(suffix):
        return name[: -len(suffix)]
    return name


def sql_header_comment(sql_text: str, max_lines: int = 16) -> str:
    """抽取 SQL 文件头部的 -- 注释块（含【步骤名】【归属章节】【粒度】【输出列】【图表】【右轴】）。

    只扫描文件头，遇到第一行非注释即停，避免误读正文里的行内注释。
    """
    lines: list[str] = []
    for ln in (sql_text or "").splitlines():
        s = ln.strip()
        if not s:
            if lines:
                break
            continue
        if s.startswith("--"):
            lines.append(s.lstrip("- ").strip())
        else:
            break
        if len(lines) >= max_lines:
            break
    return "\n".join(lines)


def list_artifacts(kind: str, game: str | None = None) -> list[str]:
    """列出某 kind 的全部 canonical id（裸名）。kind 非法抛 ValueError。"""
    if kind == "doc":
        return list(knowledge_store.list_docs(game))
    if kind == "sql":
        return [_bare(n, "sql") for n in sql_store.list_sql_files(game)]
    if kind == "model":
        return [_bare(n, "model") for n in code_store.list_code_files()]
    if kind == "skill":
        return list(knowledge_store.list_skills(game))
    if kind == "report":
        return sorted(p.name for p in _REPORTS_DIR.glob("*/")) if _REPORTS_DIR.exists() else []
    raise ValueError(f"未知工件类型：{kind!r}（可用：{', '.join(KINDS)}）")


def read_artifact(kind: str, name: str) -> dict:
    """返回 {kind, id, content, manifest, deps}。name 可带/不带后缀，自动归一。

    - deps：上游工件引用 [(kind, id)]（doc/sql/model 无上游；skill 来自 meta.sqls/docs；
      report 来自 run_meta.json）。
    """
    if kind not in KINDS:
        raise ValueError(f"未知工件类型：{kind!r}（可用：{', '.join(KINDS)}）")
    bare = _bare(name, kind)

    if kind == "doc":
        content = knowledge_store.read_doc(bare)
        manifest = knowledge_store.read_doc_meta(bare)
        deps: list[tuple[str, str]] = []
    elif kind == "sql":
        content = sql_store.read_sql(bare + ".sql")
        meta = sql_store.read_sql_meta(bare + ".sql")
        manifest = {
            "level": meta.get("level"),
            "game": meta.get("game"),
            "modifications": meta.get("modifications", []),
            "header": sql_header_comment(content),
        }
        deps = []
    elif kind == "model":
        content = code_store.read_code(bare)
        manifest = getattr(code_store, "read_code_meta", lambda _n: {})(bare)
        manifest = manifest if isinstance(manifest, dict) else {}
        deps = [(d_kind, _bare(d_name, d_kind)) for d_kind, d_name in _manifest_deps(manifest)]
    elif kind == "skill":
        content = knowledge_store.read_skill(bare)
        meta = knowledge_store.read_skill_meta(bare)
        manifest = dict(meta)
        deps = [("sql", _bare(s, "sql")) for s in meta.get("sqls", [])]
        deps += [("doc", _bare(d, "doc")) for d in meta.get("docs", [])]
    else:  # report
        content, manifest = _read_report(bare)
        deps = _manifest_deps(manifest)

    return {"kind": kind, "id": bare, "content": content, "manifest": manifest, "deps": deps}


def _manifest_deps(manifest: dict) -> list[tuple[str, str]]:
    """从 manifest 里提取上游工件引用（兼容 model manifest 的 sqls/docs、单数 sql 与 report 的 selected_sql/docs）。"""
    out: list[tuple[str, str]] = []
    for key, kind in (("sqls", "sql"), ("docs", "doc"), ("selected_sql", "sql"), ("selected_docs", "doc")):
        for item in manifest.get(key, []) or []:
            out.append((kind, str(item)))
    # model manifest 的绑定取数 SQL 用单数 "sql"（字符串，非列表），单独收进来
    sql = manifest.get("sql")
    if isinstance(sql, str) and sql.strip():
        out.append(("sql", sql.strip()))
    return out


def _read_report(run_id: str) -> tuple[str, dict]:
    """读报告工件：report.md + run_meta.json；缺失返回空串/空 dict。"""
    d = _REPORTS_DIR / _bare(run_id, "report")
    md = (d / "report.md").read_text(encoding="utf-8") if (d / "report.md").exists() else ""
    meta: dict = {}
    meta_path = d / "run_meta.json"
    if meta_path.exists():
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            meta = {}
    return md, meta if isinstance(meta, dict) else {}
