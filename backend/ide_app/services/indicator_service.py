"""指标管理业务逻辑层"""

import asyncio
import json
from datetime import datetime

from . import db_service


async def _call_llm(prompt: str, user: dict | None) -> str:
    """调用 LLM 分析 SQL 提取指标元数据。

    经 backend.services.llm.complete 统一走 per-user key 路由与 LLMNotConfigured 闸门
    （非管理员未配 Key 阻断，admin/匿名回落系统默认）；模型用 config.task_model("split")
    快速档（指标定义抽取与指标拆分同类结构化任务）。
    函数体内懒 import：backend.services.llm → ide_bridge → db_service 与本模块同层，
    模块顶层 import 会形成循环导入。
    """
    from backend import config
    from backend.services.llm import complete
    from backend.ide_app.prompts import load_system_user
    from analysis import ai_client

    # system prompt 从配置文件加载
    system_prompt, _ = load_system_user("indicator_analyze")
    model = config.task_model("split")
    # complete 是同步 requests 调用，放进线程避免阻塞事件循环（原实现为 async httpx）
    return await asyncio.to_thread(
        complete,
        model,
        [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": prompt},
        ],
        user,
        max_tokens=4096,
        **ai_client.reasoning_off(model),
    )


async def create_indicator(uid: str, data: dict) -> dict:
    """创建指标（不自动 AI 拆解，用户可选点击 AI 解析按钮）"""
    return db_service.create_indicator(uid, data)


async def update_indicator(indicator_id: int, data: dict, uid: str = "") -> dict:
    """更新指标 — 始终创建版本快照，SQL 变更时触发 AI 重新拆解"""
    existing = db_service.get_indicator_by_id(indicator_id)
    if not existing:
        raise ValueError("指标不存在")

    # 检查 SQL 是否变更
    sql_changed = "canonical_sql" in data and data["canonical_sql"] != existing.get("canonical_sql")

    # 始终保存版本快照（覆盖所有字段变更，确保可回滚）
    db_service.create_indicator_version(
        indicator_id=indicator_id,
        version=existing["version"],
        snapshot=json.dumps(existing, ensure_ascii=False, default=str),
        change_comment=data.get("change_comment", ""),
        created_by=uid or existing.get("owner", ""),
    )

    # 新版本号
    data["version"] = existing["version"] + 1

    if sql_changed:
        # 校验片段一致性
        fragments = data.get("sql_fragments", existing.get("sql_fragments", []))
        inconsistencies = validate_fragments(data["canonical_sql"], fragments)
        if inconsistencies:
            raise ValueError(f"SQL 片段与完整 SQL 不一致: {json.dumps(inconsistencies, ensure_ascii=False)}")

        # AI 重新拆解 — 只在用户未填关键字段时才调用 LLM
        ai_fields = {"domain", "category", "definition", "tags", "aggregation_type", "granularity"}
        need_ai = any(k not in data or not data[k] for k in ai_fields)
        if need_ai:
            analysis = await analyze_sql_indicator(
                data.get("metric_name", existing["metric_name"]),
                data["canonical_sql"],
                fragments,
                uid,
            )
            for k, v in analysis.items():
                if k not in data:
                    data[k] = v

    # 更新 change_log
    change_log = existing.get("change_log", [])
    if isinstance(change_log, str):
        change_log = json.loads(change_log) if change_log else []
    change_log.append({
        "version": data["version"],
        "date": datetime.utcnow().isoformat()[:10],
        "user": uid or existing.get("owner", ""),
        "change": data.get("change_comment", "更新"),
    })
    data["change_log"] = change_log

    return db_service.update_indicator(indicator_id, data)


async def analyze_sql_indicator(
    metric_name: str, canonical_sql: str, sql_fragments: list = None, uid: str = ""
) -> dict:
    """调用 LLM 分析 SQL，提取结构化维度信息"""
    fragments_str = json.dumps(sql_fragments, ensure_ascii=False) if sql_fragments else "无"
    sql = canonical_sql[:2000] if len(canonical_sql) > 2000 else canonical_sql

    # user prompt 从配置文件加载（system 在 _call_llm 内加载）
    from backend.ide_app.prompts import load_system_user
    try:
        _, prompt = load_system_user(
            "indicator_analyze", metric_name=metric_name, sql=sql, fragments_str=fragments_str,
        )
    except Exception as e:
        return {
            "domain": "通用", "category": "核心指标", "tags": [metric_name], "definition": "",
            "uncertain_fields": [{"field": "analysis", "question": f"prompt 加载失败: {str(e)[:100]}"}],
        }

    try:
        result_str = await _call_llm(prompt, {"id": uid} if uid else None)
        return json.loads(result_str)
    except Exception as e:
        return {
            "domain": "通用",
            "category": "核心指标",
            "tags": [metric_name],
            "definition": "",
            "uncertain_fields": [{"field": "analysis", "question": f"AI分析失败: {str(e)[:100]}"}],
        }


def validate_fragments(canonical_sql: str, fragments: list) -> list:
    """校验SQL片段是否在完整SQL中存在"""
    inconsistencies = []
    for f in (fragments or []):
        f_sql = (f.get("sql") or "").strip()
        if f_sql and f_sql not in canonical_sql:
            inconsistencies.append({
                "name": f.get("name", "未命名"),
                "sql": f_sql,
                "issue": "该片段未在完整SQL中找到匹配",
            })
    return inconsistencies


async def match_indicators_by_llm(user_message: str, indicators: list[dict], uid: str) -> dict:
    """用 LLM 判断用户消息与哪些指标相关，返回 {matched: [...], reasoning: str}。

    考虑多个维度：名称语义、别名、领域、分类、定义描述、SQL涉及的表/字段。
    LLM 不可用时降级为简单关键词匹配。
    """
    if not user_message or not indicators:
        return {"matched": [], "reasoning": "无指标或无用户消息"}

    # 构建指标摘要（控制总长度避免超 token）
    indicator_lines = []
    for i, ind in enumerate(indicators):
        name = ind.get("metric_name", "")
        alias = ind.get("metric_alias", "")
        domain = ind.get("domain", "")
        category = ind.get("category", "")
        definition = (ind.get("definition") or "")[:100]
        sql = (ind.get("canonical_sql") or "")[:200]
        parts = [f"[{i}] {name}"]
        if alias:
            parts.append(f"别名:{alias}")
        if domain:
            parts.append(f"领域:{domain}")
        if category:
            parts.append(f"分类:{category}")
        if definition:
            parts.append(f"定义:{definition}")
        if sql:
            parts.append(f"SQL:{sql}")
        indicator_lines.append(" | ".join(parts))

    prompt = f"""用户消息：{user_message}

可用指标列表（含名称、别名、领域、分类、定义、SQL）：
{chr(10).join(indicator_lines)}

请判断哪些指标与用户消息相关。综合考虑：
- 指标名称/别名的语义是否匹配用户意图
- 指标的领域/分类是否与用户关注点一致
- 指标定义描述是否与用户需求相关
- 指标 SQL 涉及的表和字段是否与用户提到的数据相关

返回 JSON 格式：
{{"matched": ["指标名称1", "指标名称2"], "reasoning": "简要说明匹配理由，一句话即可"}}

如果没有匹配的指标，返回 {{"matched": [], "reasoning": "未找到相关指标"}}"""

    try:
        result_str = await _call_llm_custom(prompt, {"id": uid} if uid else None, max_tokens=1024)
        result = json.loads(result_str)
        matched_names = result.get("matched", [])
        reasoning = result.get("reasoning", "")
        matched = [ind for ind in indicators if ind.get("metric_name", "") in matched_names]
        return {"matched": matched, "reasoning": reasoning}
    except Exception:
        return _fallback_match(user_message, indicators)


def _fallback_match(user_message: str, indicators: list[dict]) -> dict:
    """降级方案：简单关键词包含匹配"""
    msg_lower = user_message.lower()
    matched = []
    for ind in indicators:
        name = (ind.get("metric_name") or "").lower()
        alias = (ind.get("metric_alias") or "").lower()
        domain = (ind.get("domain") or "").lower()
        category = (ind.get("category") or "").lower()
        definition = (ind.get("definition") or "").lower()
        if (name and name in msg_lower) or (alias and alias in msg_lower):
            matched.append(ind)
        elif domain and len(domain) > 1 and domain in msg_lower:
            matched.append(ind)
        elif category and len(category) > 1 and category in msg_lower:
            matched.append(ind)
        elif definition and len(definition) > 3 and definition[:20] in msg_lower:
            matched.append(ind)
    return {"matched": matched, "reasoning": "关键词降级匹配" if matched else "未找到相关指标"}


async def _call_llm_custom(prompt: str, user: dict | None, max_tokens: int = 1024) -> str:
    """自定义参数的 LLM 调用（指标匹配：无 system 段、输出预算较小）。

    与 _call_llm 同口径：经 backend.services.llm.complete 走 per-user 路由与闸门，
    模型用 config.task_model("split") 快速档；函数体内懒 import 避免循环导入。
    """
    from backend import config
    from backend.services.llm import complete
    from analysis import ai_client

    model = config.task_model("split")
    return await asyncio.to_thread(
        complete,
        model,
        [{"role": "user", "content": prompt}],
        user,
        max_tokens=max_tokens,
        **ai_client.reasoning_off(model),
    )


async def migrate_from_macros(uid: str) -> dict:
    """将用户的所有宏迁移为指标"""
    macros = db_service.get_all_macros(uid)
    results = {"migrated": 0, "failed": 0, "errors": []}

    for macro in macros:
        try:
            existing = db_service.get_indicator_by_metric_id(f"macro_{macro['id']}")
            if existing:
                results["migrated"] += 1
                continue

            data = {
                "metric_id": f"macro_{macro['id']}",
                "metric_name": macro["name"],
                "metric_alias": "",
                "canonical_sql": macro["sql_text"],
                "definition": macro.get("description", ""),
                "from_macro_id": str(macro["id"]),
                "status": "draft",
            }
            try:
                analysis = await analyze_sql_indicator(macro["name"], macro["sql_text"], [], uid)
                data.update(analysis)
                if not analysis.get("uncertain_fields"):
                    data["status"] = "active"
            except Exception:
                data["status"] = "draft"

            db_service.create_indicator(uid, data)
            results["migrated"] += 1
        except Exception as e:
            results["failed"] += 1
            results["errors"].append({"macro": macro.get("name", ""), "error": str(e)})

    return results
