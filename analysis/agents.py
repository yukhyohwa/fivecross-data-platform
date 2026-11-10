"""统一 Agent 注册表：把 data_ai / 飞书 / 未来工具共用的能力抽象成带契约的 agent。

每个 agent = 一个能力节点（知识库 → SQL → 算法模型 → 专项 → 报告）：
- depends_on / inputs / outputs 描述它在能力 DAG 里的位置与上下游工件；
- func 是生成实现，用「模块路径:函数名」懒加载引用，调用时才 import ——
  这样注册表本身纯声明式、无 import 期耦合，任何工具 import analysis.agents 都不会
  连带加载 data_ai 等重模块，`list_agents()` 也无需加载具体实现即可列出 DAG。

未来新增工具/能力：往 AGENTS 里加一条（或复用现有条目）即可，不写工具内私有逻辑。
"""
from __future__ import annotations

import importlib
from typing import Any, Callable

AGENTS: dict[str, dict] = {
    "kb": {
        "id": "kb",
        "name": "知识库生成",
        "desc": "把原始资料 / 对话 / 飞书文档整理成结构化知识库文档，供 SQL / 专项 / 报告引用",
        "depends_on": [],
        "inputs": [],
        "outputs": ["doc"],
        "func": "analysis.kb_gen:summarize",
    },
    "sql": {
        "id": "sql",
        "name": "SQL 生成",
        "desc": "依据表结构（优先知识库文档）与业务口径，生成只读 SELECT 查询",
        "depends_on": ["kb"],
        "inputs": ["doc"],
        "outputs": ["sql"],
        "func": "analysis.sql_gen:generate_sql",
    },
    "model": {
        "id": "model",
        "name": "算法模型",
        "desc": "依据 SQL 取数口径与知识库，生成可执行预测/算法模型代码（人审后动态注册）",
        "depends_on": ["kb", "sql"],
        "inputs": ["doc", "sql"],
        "outputs": ["model"],
        "func": "analysis.model_gen:generate_model",
    },
    "skill": {
        "id": "skill",
        "name": "专项生成",
        "desc": "把分析方法描述与绑定 SQL / 知识库 / 预测能力，生成结构化专项说明",
        "depends_on": ["kb", "sql", "model"],
        "inputs": ["doc", "sql", "model"],
        "outputs": ["skill"],
        "func": "analysis.kb_gen:summarize_skill",
    },
    "report": {
        "id": "report",
        "name": "报告生成",
        "desc": "执行专项 SQL 并三模型交叉验证产出分析报告（依赖 DB / SSE 上下文，懒加载）",
        "depends_on": ["skill"],
        "inputs": ["skill", "sql", "model", "doc"],
        "outputs": ["report"],
        "func": "backend.services.report:run_report_pipeline",
    },
}


def list_agents() -> list[dict]:
    """列出全部 agent 的声明式元数据（不含 func 引用），供前端/文档/自检展示。"""
    return [{k: v for k, v in spec.items() if k != "func"} for spec in AGENTS.values()]


def get_agent(agent_id: str) -> dict:
    """返回某 agent 的完整声明（含 func 引用）。未知 id 抛 ValueError。"""
    if agent_id not in AGENTS:
        raise ValueError(f"未知 agent：{agent_id!r}（可用：{', '.join(AGENTS)}）")
    return AGENTS[agent_id]


def resolve_func(func_ref: str) -> Callable:
    """解析「模块路径:函数名」引用为可调用对象。"""
    module_path, _, attr = func_ref.partition(":")
    if not attr:
        raise ValueError(f"func 引用格式错误（应为 模块:函数）：{func_ref!r}")
    module = importlib.import_module(module_path)
    func = getattr(module, attr)
    if not callable(func):
        raise ValueError(f"func 引用不是可调用对象：{func_ref!r}")
    return func


def run_agent(agent_id: str, **kwargs) -> Any:
    """调用某 agent 的生成实现（func 懒加载）。实现缺失/不可用时抛 ValueError。"""
    return resolve_func(get_agent(agent_id)["func"])(**kwargs)


def agent_dag() -> list[str]:
    """拓扑排序返回 agent id（上游在前，保证依赖顺序）。"""
    seen: set[str] = set()
    order: list[str] = []

    def _visit(aid: str) -> None:
        if aid in seen:
            return
        for dep in AGENTS[aid].get("depends_on", []):
            if dep in AGENTS:
                _visit(dep)
        seen.add(aid)
        order.append(aid)

    for aid in AGENTS:
        _visit(aid)
    return order


def upstream(agent_id: str) -> list[str]:
    """直接上游 agent id。"""
    return list(get_agent(agent_id).get("depends_on", []))


def downstream(agent_id: str) -> list[str]:
    """直接依赖 agent_id 的下游 agent id。"""
    return [aid for aid, spec in AGENTS.items() if agent_id in spec.get("depends_on", [])]
