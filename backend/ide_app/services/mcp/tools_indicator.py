"""指标管理 MCP Tools — 查询/更新/回滚指标"""

import json
from typing import Optional

# ── Tool 定义（元数据） ──

TOOL_GET_INDICATOR_DETAIL = {
    "name": "get_indicator_detail",
    "description": "获取单个指标的完整详情，包括所有字段、版本号、变更日志。可通过 metric_id 或名称查找。",
    "inputSchema": {
        "type": "object",
        "properties": {
            "metric_id": {
                "type": "string",
                "description": "指标的唯一标识（metric_id），如 ind_abc1234def",
            },
            "metric_name": {
                "type": "string",
                "description": "指标名称，用于模糊搜索匹配",
            },
        },
    },
}

TOOL_UPDATE_INDICATOR = {
    "name": "update_indicator",
    "description": (
        "更新指标内容。支持预览模式（confirmed=false）和确认模式（confirmed=true）。"
        "预览模式返回新旧值对比，不实际修改。确认模式会先保存版本快照再应用更新，支持后续回滚。"
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "metric_id": {
                "type": "string",
                "description": "指标的唯一标识（metric_id）",
            },
            "updates": {
                "type": "object",
                "description": (
                    "要更新的字段，键值对形式。支持更新的字段：metric_name, metric_alias, domain, "
                    "category, tags, definition, aggregation_type, granularity, canonical_sql, "
                    "status, owner, business_scenarios, supported_filters, test_cases 等"
                ),
            },
            "confirmed": {
                "type": "boolean",
                "description": "是否确认执行更新。false=仅预览差异，true=实际应用更新",
                "default": False,
            },
            "change_comment": {
                "type": "string",
                "description": "变更说明（可选）",
            },
        },
        "required": ["metric_id", "updates"],
    },
}

TOOL_ROLLBACK_INDICATOR = {
    "name": "rollback_indicator",
    "description": (
        "将指标回滚到指定版本。回滚前会保存当前状态为新版本快照，以便撤销回滚操作。"
        "不指定 version 则回滚到上一版本。"
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "metric_id": {
                "type": "string",
                "description": "指标的唯一标识（metric_id）",
            },
            "version": {
                "type": "integer",
                "description": "目标版本号。不传则回滚到上一版本（当前版本-1）",
            },
        },
        "required": ["metric_id"],
    },
}


# ── 执行函数 ──

async def get_indicator_detail(
    metric_id: str = "",
    metric_name: str = "",
) -> dict:
    """获取指标完整详情"""
    from .. import db_service

    indicator = None
    if metric_id:
        indicator = db_service.get_indicator_by_metric_id(metric_id)
    if not indicator and metric_name:
        # 按名称模糊搜索
        items, _ = db_service.list_indicators("", search=metric_name, size=1)
        if items:
            indicator = items[0]

    if not indicator:
        return {
            "content": [
                {"type": "text", "text": f"未找到指标: metric_id={metric_id}, metric_name={metric_name}"}
            ],
            "isError": True,
        }

    # 获取版本历史
    versions = db_service.list_indicator_versions(indicator["id"])

    return {
        "content": [
            {"type": "text", "text": f"指标: {indicator.get('metric_name', '')} (v{indicator.get('version', 1)})"},
            {"type": "json", "data": {
                "indicator": indicator,
                "versions": versions,
                "version_count": len(versions),
            }},
        ],
    }


async def update_indicator_mcp(
    metric_id: str,
    updates: dict,
    confirmed: bool = False,
    change_comment: str = "",
) -> dict:
    """更新指标（预览或确认执行）"""
    from .. import db_service
    from .. import indicator_service

    # 查找指标
    indicator = db_service.get_indicator_by_metric_id(metric_id)
    if not indicator:
        return {
            "content": [{"type": "text", "text": f"未找到指标: {metric_id}"}],
            "isError": True,
        }

    updates["change_comment"] = change_comment

    if not confirmed:
        # 预览模式：返回差异对比
        changes = []
        unchanged = []
        for field, new_value in updates.items():
            if field == "change_comment":
                continue
            old_value = indicator.get(field)
            # 列表/字典类型统一序列化比较
            if isinstance(old_value, (list, dict)):
                old_value = json.dumps(old_value, ensure_ascii=False)
            if isinstance(new_value, (list, dict)):
                new_value = json.dumps(new_value, ensure_ascii=False)
            if old_value != new_value:
                changes.append({"field": field, "from": str(old_value)[:200], "to": str(new_value)[:200]})
            else:
                unchanged.append(field)

        return {
            "content": [
                {"type": "text", "text": f"预览更新 — 指标: {indicator['metric_name']} (当前 v{indicator['version']})"},
                {"type": "json", "data": {
                    "preview": True,
                    "metric_id": metric_id,
                    "current_version": indicator["version"],
                    "changes": changes,
                    "unchanged_fields": unchanged,
                    "change_count": len(changes),
                }},
            ],
        }

    # 确认模式：实际应用更新
    try:
        result = await indicator_service.update_indicator(
            indicator["id"], updates, uid=indicator.get("user_id", "")
        )
        return {
            "content": [
                {"type": "text", "text": f"指标已更新: {result.get('metric_name', '')} → v{result.get('version', '?')}"},
                {"type": "json", "data": {
                    "preview": False,
                    "applied": True,
                    "metric_id": metric_id,
                    "new_version": result.get("version"),
                    "indicator": result,
                }},
            ],
        }
    except ValueError as e:
        return {
            "content": [{"type": "text", "text": f"更新失败: {str(e)}"}],
            "isError": True,
        }


async def rollback_indicator(
    metric_id: str,
    version: Optional[int] = None,
) -> dict:
    """回滚指标到指定版本"""
    from .. import db_service
    import json as _json
    from datetime import datetime as _datetime

    indicator = db_service.get_indicator_by_metric_id(metric_id)
    if not indicator:
        return {
            "content": [{"type": "text", "text": f"未找到指标: {metric_id}"}],
            "isError": True,
        }

    current_version = indicator["version"]
    target_version = version if version is not None else current_version - 1

    if target_version < 1:
        return {
            "content": [{"type": "text", "text": f"无法回滚：目标版本 {target_version} 无效（最低版本为 1）"}],
            "isError": True,
        }

    # 查找目标版本快照
    versions = db_service.list_indicator_versions(indicator["id"])
    target_snapshot = None
    for v in versions:
        if v["version"] == target_version:
            target_snapshot = _json.loads(v["snapshot"])
            break

    if not target_snapshot:
        return {
            "content": [{"type": "text", "text": f"未找到版本 {target_version} 的快照"}],
            "isError": True,
        }

    # 保存当前状态为新版本快照（使得回滚可撤销）
    db_service.create_indicator_version(
        indicator_id=indicator["id"],
        version=current_version,
        snapshot=_json.dumps(indicator, ensure_ascii=False, default=str),
        change_comment=f"回滚前自动保存 (v{current_version} → v{target_version})",
        created_by=indicator.get("user_id", ""),
    )

    # 更新 change_log
    change_log = target_snapshot.get("change_log", [])
    if isinstance(change_log, str):
        change_log = _json.loads(change_log) if change_log else []
    change_log.append({
        "version": current_version + 1,
        "date": _datetime.utcnow().isoformat()[:10],
        "user": indicator.get("user_id", ""),
        "change": f"回滚至 v{target_version}",
    })

    # 用快照数据覆盖当前指标（排除服务端字段）
    restore_data = {
        k: v for k, v in target_snapshot.items()
        if k not in ("id", "metric_id", "user_id", "created_at", "updated_at")
    }
    restore_data["version"] = current_version + 1
    restore_data["change_log"] = change_log

    result = db_service.update_indicator(indicator["id"], restore_data)

    return {
        "content": [
            {"type": "text", "text": f"指标 {indicator['metric_name']} 已回滚 v{current_version} → v{target_version}（当前状态已保存为 v{current_version + 1}）"},
            {"type": "json", "data": {
                "rolled_back": True,
                "metric_id": metric_id,
                "from_version": current_version,
                "to_version": target_version,
                "saved_current_as_version": current_version + 1,
                "indicator": result,
            }},
        ],
    }
