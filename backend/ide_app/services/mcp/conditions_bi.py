"""BI 报表 conditions 字段构建与 MCP Schema 定义

每种图表类型：
  1. chart_type 常量
  2. builder 函数 — 接收明确字段，返回合法 conditions dict
  3. MCP JSON Schema 片段

新增图表类型：
  a. 添加 CHART_* 常量
  b. 添加 conditions_<type>() builder
  c. 添加 <TYPE>_CONDITIONS_SCHEMA
  d. 在 CONDITIONS_SCHEMA["oneOf"] 末尾 append
"""

from typing import Any

# ── chart_type 常量 ───────────────────────────────────────────────────────────

CHART_DATA   = "data"    # 数据表（明细列表，支持行级筛选）
CHART_METRIC = "card"    # 指标卡
CHART_PIVOT  = "table"   # 透视表（维度 + 度量分组）
CHART_LINE   = "line"    # 折线图（时间序列趋势）
CHART_STACK  = "stack"   # 堆叠图（按分类堆叠的柱状图）
CHART_DONUT  = "donut"   # 环形图（饼图变体，按分类切片）
# CHART_BAR  = "bar"     # 柱状图 — 待填充


# ── Builder 函数 ──────────────────────────────────────────────────────────────

def conditions_data(
    sql: str,
    cols: list,
    col_types: dict,
    sql_cont: str = None,
    limit: int = 1000,
    columns3: list = None,
    filters: list = None,
    filters_array: list = None,
    dynamic_params: list = None,
    top_col_types: dict = None,
    show_type: str = "chart",
) -> dict:
    """数据表 conditions（明细列表，支持行级筛选）。

    Args:
        sql: 静态 SQL（含硬编码日期，用于预览）
        cols: chart_config 展示列名列表
        col_types: chart_config 内的列类型 map（展示列）
        sql_cont: 参数化 SQL（含 ${Date:Date1} 等占位符）；有动态筛选时必填
        limit: 结果行数上限
        columns3: 展示列顺序列表（通常与 cols 相同）；None 时默认同 cols
        filters: 可筛选列名字符串列表，如 ["人工单号", "AI单号"]
        filters_array: 结构化筛选配置，如
            [{"type": "string", "field": "人工单号"}, {"type": "string", "field": "AI单号"}]
        dynamic_params: 动态参数列表，单项结构：
            {
                "op": "noeffect",
                "type": "Date",
                "sqlTem": "${Date:Date1}",    # 与 sqlCont 占位符对应
                "showSql": "between '...' and '...'",
                "defaultName": "Date1",       # 占位符变量名
                "info": {
                    "date": {
                        "custom_date_range": "today",
                        "date_description": "今日",
                        "begin_date_type": "dynamic",
                        "begin_date_value": "2026-07-09 00:00:00",
                        "begin_show_value": "0",
                        "end_date_type": "dynamic",
                        "end_date_value": "2026-07-09 23:59:59",
                        "end_show_value": "0",
                    }
                },
            }
        top_col_types: 顶层 col_types（SQL 全量输出列类型，可与 col_types 不同）；
                       None 时与 col_types 相同
        show_type: 渲染模式，默认 "chart"
    """
    displayed_cols = columns3 if columns3 is not None else cols
    chart_config: dict = {
        "cols": cols,
        "columns3": displayed_cols,
        "filters": filters or [],
        "col_types": col_types,
        "quotasSelect": [],
        "filters_array": filters_array or [],
    }
    return {
        "chart_type": CHART_DATA,
        "sql": sql,
        "sqlCont": sql_cont if sql_cont is not None else sql,
        "limit": limit,
        "showType": show_type,
        "col_types": top_col_types if top_col_types is not None else col_types,
        "chart_config": chart_config,
        "quotasSelect": [],
        "dynamic_params": dynamic_params or [],
    }


def conditions_donut(
    sql: str,
    rows: list,
    columns: list,
    cols: list,
    col_types: dict,
    sql_cont: str = None,
    limit: int = 1000,
    donut_config: dict = None,
    quotas_select: list = None,
    dynamic_params: list = None,
    show_type: str = "chart",
) -> dict:
    """环形图 conditions（饼图变体，按分类切片）。

    Args:
        sql: 静态 SQL（含硬编码日期，用于预览）
        rows: 分类维度列名列表（切片分组，如 ["状态"]）
        columns: 度量列名列表（切片大小，如 ["单数"]）
        cols: SQL 结果所有列名
        col_types: 列类型 map，值为 string/number/date
        sql_cont: 参数化 SQL（含 ${Date:Date1} 占位符）；有动态筛选时必填
        limit: 结果行数上限
        donut_config: 环形图展示配置，结构如下：
            {
                "groupSize": 20,           # 分组数量上限
                "showLabels": "all",       # 标签显示方式
                "showNumbers": ["number", "percent"],  # 显示原始数值和百分比
            }
        quotas_select: 度量选择配置，如
            [{"name": "单数", "checked": True, "display_name": "单数"}]
        dynamic_params: 动态参数列表（格式同 conditions_data，无 name 字段）
        show_type: 渲染模式，默认 "chart"
    """
    chart_config: dict = {
        "cols": cols,
        "rows": rows,
        "rows1": [],
        "columns": columns,
        "columns1": [],
        "columns3": [],
        "filters": [],
        "col_types": col_types,
        "donut": donut_config or {"groupSize": 20, "showLabels": "all", "showNumbers": ["number", "percent"]},
        "colorScale": True,
        "colorResered": False,
        "legend_page": True,
        "show_calendar": False,
        "quotasSelect": [],
        "showPagation": True,
        "showRowTotal": True,
    }
    return {
        "chart_type": CHART_DONUT,
        "sql": sql,
        "sqlCont": sql_cont if sql_cont is not None else sql,
        "limit": limit,
        "showType": show_type,
        "chart_config": chart_config,
        "quotasSelect": quotas_select or [],
        "dynamic_params": dynamic_params or [],
    }


def conditions_stack(
    sql: str,
    rows: list,
    rows1: list,
    columns: list,
    cols: list,
    col_types: dict,
    sql_cont: str = None,
    limit: int = 1000,
    filters: list = None,
    quotas_select: list = None,
    dynamic_params: list = None,
    show_type: str = "chart",
) -> dict:
    """堆叠图 conditions（按分类堆叠的柱状图）。

    Args:
        sql: 静态 SQL（含硬编码日期，用于预览）
        rows: X 轴维度列名列表（通常为时间列，如 ["日期"]）
        rows1: 堆叠分组维度列名列表（如 ["状态"]，按此列的值分色堆叠）
        columns: 度量列名列表（数值列，如 ["单数"]）
        cols: SQL 结果所有列名
        col_types: 列类型 map，值为 string/number/double/date
        sql_cont: 参数化 SQL（含 ${Date:Date1} 占位符）；有动态筛选时必填
        limit: 结果行数上限
        filters: 可筛选列名字符串列表，如 ["状态", "处理状态"]
        quotas_select: 度量选择配置，如
            [{"name": "单数", "checked": True, "display_name": "单数"}]
        dynamic_params: 动态参数列表（格式同 conditions_data，无 name 字段）
        show_type: 渲染模式，默认 "chart"
    """
    chart_config: dict = {
        "cols": cols,
        "rows": rows,
        "rows1": rows1,
        "columns": columns,
        "columns1": [],
        "columns3": [],
        "filters": filters or [],
        "col_types": col_types,
        "quotasSelect": [],
    }
    return {
        "chart_type": CHART_STACK,
        "sql": sql,
        "sqlCont": sql_cont if sql_cont is not None else sql,
        "limit": limit,
        "showType": show_type,
        "chart_config": chart_config,
        "quotasSelect": quotas_select or [],
        "dynamic_params": dynamic_params or [],
    }



def conditions_line(
    sql: str,
    rows: list,
    columns: list,
    cols: list,
    col_types: dict,
    sql_cont: str = None,
    limit: int = 1000,
    line_config: dict = None,
    quotas_select: list = None,
    dynamic_params: list = None,
    show_type: str = "chart",
) -> dict:
    """折线图 conditions（时间序列趋势图）。

    Args:
        sql: 静态 SQL（含硬编码日期，用于预览）
        rows: X 轴维度列名列表（通常为时间列，如 ["统计日期"]）
        columns: Y 轴度量列名列表（每列对应一条折线）
        cols: SQL 结果所有列名
        col_types: 列类型 map，值为 string/number/double/date
        sql_cont: 参数化 SQL（含 ${Date:Date1} 占位符）；有动态筛选时必填
        limit: 结果行数上限
        line_config: 每条线的展示配置，key 为列名，value 为 {showInLegend: bool} 等；
                     格式：{"列名": {"showInLegend": True}}
        quotas_select: 度量选择配置，如
            [{"name": "列名", "checked": True, "display_name": "列名"}]
        dynamic_params: 动态参数列表（格式同 conditions_data，无 name 字段）
        show_type: 渲染模式，默认 "chart"
    """
    chart_config: dict = {
        "cols": cols,
        "rows": rows,
        "rows1": [],
        "columns": columns,
        "columns1": [],
        "columns3": [],
        "filters": [],
        "col_types": col_types,
        "line": line_config or {},
        "colorScale": True,
        "colorResered": False,
        "quotasSelect": [],
        "showPagation": True,
        "showRowTotal": True,
    }
    return {
        "chart_type": CHART_LINE,
        "sql": sql,
        "sqlCont": sql_cont if sql_cont is not None else sql,
        "limit": limit,
        "showType": show_type,
        "chart_config": chart_config,
        "quotasSelect": quotas_select or [],
        "dynamic_params": dynamic_params or [],
    }


def conditions_metric(
    sql: str,
    rows: list,
    cols: list,
    col_types: dict,
    sql_cont: str = None,
    limit: int = 1000,
    card_config: dict = None,
    dynamic_params: list = None,
    show_type: str = "chart",
) -> dict:
    """指标卡 conditions。

    Args:
        sql: 静态 SQL（含硬编码日期范围）
        rows: 展示为指标卡的列名列表（核心 KPI 指标）
        cols: SQL 结果所有列名
        col_types: 列类型 map，如 {"字段名": "number"/"string"}
        sql_cont: 参数化 SQL（含 ${...} 占位符）；None 时与 sql 相同
        limit: 结果行数上限
        card_config: 每个指标的展示配置，结构如下：
            {
                "<列名>": {"showLabel": True, "showProgress": False, "showProgressTarget": False},
                "conditions": [{"value": 0, "selectedValue": "<列名>", "comparisonValue": "fix"}],
                "colorChange": "red,orange,green",
            }
        dynamic_params: 动态筛选参数列表（格式同 conditions_pivot）
        show_type: 渲染模式，默认 "chart"
    """
    chart_config: dict = {
        "cols": cols,
        "rows": rows,
        "rows1": [],
        "columns": [],
        "filters": [],
        "col_types": col_types,
        "card": card_config or {},
    }
    return {
        "chart_type": CHART_METRIC,
        "sql": sql,
        "sqlCont": sql_cont if sql_cont is not None else sql,
        "limit": limit,
        "showType": show_type,
        "chart_config": chart_config,
        "quotasSelect": [],
        "dynamic_params": dynamic_params or [],
    }


def conditions_pivot(
    sql: str,
    rows: list,
    columns: list,
    cols: list,
    col_types: dict,
    sql_cont: str = None,
    limit: int = 1000,
    quotas_select: list = None,
    dynamic_params: list = None,
    outside_filter: list = None,
    filters: list = None,
    show_type: str = "chart",
) -> dict:
    """透视表 conditions。

    Args:
        sql: 静态 SQL（含硬编码日期，用于预览）
        rows: 维度列名列表（行标题 / 分组依据）
        columns: 度量列名列表（数值列）
        cols: SQL 结果所有列名
        col_types: 列类型 map，如 {"字段名": "number"/"string"}
        sql_cont: 参数化 SQL（含 ${Date:字段名} 占位符）；有动态筛选时必填
        limit: 结果行数上限
        quotas_select: 度量选择配置，如
            [{"name": "单数", "checked": True, "display_name": "单数"}]
        dynamic_params: 动态参数列表，单项结构：
            {
                "op": "noeffect",
                "name": "日期",
                "type": "Date",
                "sqlTem": "${Date:日期}",
                "showSql": "between '2026-07-06' and '2026-07-12'",
                "defaultName": "日期",
                "info": {
                    "date": {
                        "custom_date_range": "last_week",
                        "date_description": "上周",
                        "begin_date_type": "dynamic",
                        "begin_date_value": "2026-07-06 00:00:00",
                        "begin_show_value": "7",
                        "end_date_type": "dynamic",
                        "end_date_value": "2026-07-12 23:59:59",
                        "end_show_value": "1",
                    }
                },
            }
        outside_filter: 看板外部筛选器列表，单项结构：
            {
                "op": "noeffect",
                "index": 0,
                "label": "日期",
                "fieldName": "日期",
                "fieldType": "Date",
                "isOutside": True,
                "filterType": "dynamic",
                "props": {
                    "type": "dynamic",
                    "item": { ...同 dynamic_params 单项... },
                },
            }
        filters: chart_config 内联筛选器列表
        show_type: 渲染模式，默认 "chart"
    """
    chart_config: dict = {
        "cols": cols,
        "rows": rows,
        "rows1": [],
        "columns": columns,
        "filters": filters or [],
        "col_types": col_types,
    }
    return {
        "chart_type": CHART_PIVOT,
        "sql": sql,
        "sqlCont": sql_cont if sql_cont is not None else sql,
        "limit": limit,
        "showType": show_type,
        "col_types": col_types,       # 顶层与 chart_config 内相同
        "chart_config": chart_config,
        "quotasSelect": quotas_select or [],
        "outsideFilter": outside_filter or [],
        "dynamic_params": dynamic_params or [],
    }


# ── MCP JSON Schema 片段 ──────────────────────────────────────────────────────

DONUT_CONDITIONS_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": (
        "环形图（donut）conditions — 饼图变体，按分类切片展示占比。"
        "chart_type 固定填 donut。"
        "rows 为切片分类维度，columns 为切片大小度量值。"
    ),
    "required": ["chart_type", "sql", "chart_config"],
    "properties": {
        "chart_type": {"type": "string", "const": CHART_DONUT, "description": "固定填 donut"},
        "sql": {"type": "string", "description": "静态 SQL（含硬编码日期，用于预览）"},
        "sqlCont": {
            "type": "string",
            "description": "参数化 SQL（含 ${Date:Date1} 占位符）；有 dynamic_params 时必填",
        },
        "limit": {"type": "integer", "default": 1000},
        "showType": {"type": "string", "default": "chart"},
        "chart_config": {
            "type": "object",
            "required": ["cols", "rows", "columns", "col_types"],
            "properties": {
                "cols": {"type": "array", "items": {"type": "string"}, "description": "SQL 所有输出列名"},
                "rows": {"type": "array", "items": {"type": "string"}, "description": "切片分类维度列（如 ['状态']）"},
                "rows1": {"type": "array", "default": []},
                "columns": {"type": "array", "items": {"type": "string"}, "description": "切片大小度量列（如 ['单数']）"},
                "columns1": {"type": "array", "default": []},
                "columns3": {"type": "array", "default": []},
                "filters": {"type": "array", "default": []},
                "col_types": {"type": "object", "description": "列类型 map，值为 string/number/date"},
                "donut": {
                    "type": "object",
                    "description": "环形图展示配置",
                    "properties": {
                        "groupSize": {"type": "integer", "default": 20, "description": "分组数量上限"},
                        "showLabels": {"type": "string", "default": "all", "description": "标签显示方式"},
                        "showNumbers": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "显示内容，可含 number（原始值）和/或 percent（百分比）",
                        },
                    },
                },
                "colorScale": {"type": "boolean", "default": True},
                "colorResered": {"type": "boolean", "default": False},
                "legend_page": {"type": "boolean", "default": True, "description": "图例分页"},
                "show_calendar": {"type": "boolean", "default": False},
                "showPagation": {"type": "boolean", "default": True},
                "showRowTotal": {"type": "boolean", "default": True},
                "quotasSelect": {"type": "array", "default": []},
            },
        },
        "quotasSelect": {
            "type": "array",
            "description": "度量选择配置",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "checked": {"type": "boolean", "default": True},
                    "display_name": {"type": "string"},
                },
            },
        },
        "dynamic_params": {
            "type": "array",
            "description": "动态筛选参数",
            "items": {
                "type": "object",
                "properties": {
                    "op": {"type": "string", "default": "noeffect"},
                    "type": {"type": "string"},
                    "sqlTem": {"type": "string"},
                    "showSql": {"type": "string"},
                    "defaultName": {"type": "string"},
                    "info": {"type": "object"},
                },
            },
        },
    },
}


STACK_CONDITIONS_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": (
        "堆叠图（stack）conditions — 按分类堆叠的柱状图。"
        "chart_type 固定填 stack。"
        "rows 为 X 轴维度，rows1 为堆叠分组维度（按此列的值分色堆叠），columns 为度量值列。"
    ),
    "required": ["chart_type", "sql", "chart_config"],
    "properties": {
        "chart_type": {"type": "string", "const": CHART_STACK, "description": "固定填 stack"},
        "sql": {"type": "string", "description": "静态 SQL（含硬编码日期，用于预览）"},
        "sqlCont": {
            "type": "string",
            "description": "参数化 SQL（含 ${Date:Date1} 占位符）；有 dynamic_params 时必填",
        },
        "limit": {"type": "integer", "default": 1000},
        "showType": {"type": "string", "default": "chart"},
        "chart_config": {
            "type": "object",
            "required": ["cols", "rows", "rows1", "columns", "col_types"],
            "properties": {
                "cols": {"type": "array", "items": {"type": "string"}, "description": "SQL 所有输出列名"},
                "rows": {"type": "array", "items": {"type": "string"}, "description": "X 轴维度列（如时间列）"},
                "rows1": {"type": "array", "items": {"type": "string"}, "description": "堆叠分组维度列（按此字段的值分色堆叠）"},
                "columns": {"type": "array", "items": {"type": "string"}, "description": "度量列（数值列）"},
                "columns1": {"type": "array", "default": []},
                "columns3": {"type": "array", "default": []},
                "filters": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "可筛选列名字符串列表",
                    "default": [],
                },
                "col_types": {"type": "object", "description": "列类型 map，值为 string/number/date"},
                "quotasSelect": {"type": "array", "default": []},
            },
        },
        "quotasSelect": {
            "type": "array",
            "description": "度量选择配置",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "checked": {"type": "boolean", "default": True},
                    "display_name": {"type": "string"},
                },
            },
        },
        "dynamic_params": {
            "type": "array",
            "description": "动态筛选参数；sqlCont 中的 ${Date:Date1} 占位符与此对应",
            "items": {
                "type": "object",
                "properties": {
                    "op": {"type": "string", "default": "noeffect"},
                    "type": {"type": "string"},
                    "sqlTem": {"type": "string"},
                    "showSql": {"type": "string"},
                    "defaultName": {"type": "string"},
                    "info": {"type": "object"},
                },
            },
        },
    },
}


LINE_CONDITIONS_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": (
        "折线图（line）conditions — 时间序列趋势图。"
        "chart_type 固定填 line。"
        "rows 为 X 轴时间列，columns 为 Y 轴各度量列（每列一条折线）。"
        "顶层无 col_types，仅 chart_config 内有。"
    ),
    "required": ["chart_type", "sql", "chart_config"],
    "properties": {
        "chart_type": {"type": "string", "const": CHART_LINE, "description": "固定填 line"},
        "sql": {"type": "string", "description": "静态 SQL（含硬编码日期，用于预览）"},
        "sqlCont": {
            "type": "string",
            "description": "参数化 SQL（含 ${Date:Date1} 占位符）；有 dynamic_params 时必填",
        },
        "limit": {"type": "integer", "default": 1000},
        "showType": {"type": "string", "default": "chart"},
        "chart_config": {
            "type": "object",
            "required": ["cols", "rows", "columns", "col_types"],
            "properties": {
                "cols": {"type": "array", "items": {"type": "string"}, "description": "SQL 所有输出列名"},
                "rows": {"type": "array", "items": {"type": "string"}, "description": "X 轴维度列（通常为时间列）"},
                "columns": {"type": "array", "items": {"type": "string"}, "description": "Y 轴度量列（每列一条折线）"},
                "rows1": {"type": "array", "default": []},
                "columns1": {"type": "array", "default": []},
                "columns3": {"type": "array", "default": []},
                "filters": {"type": "array", "default": []},
                "col_types": {
                    "type": "object",
                    "description": "列类型 map，值为 string/number/double/date",
                },
                "line": {
                    "type": "object",
                    "description": "每条折线的展示配置，key 为列名，value 为 {showInLegend: bool} 等",
                },
                "colorScale": {"type": "boolean", "default": True},
                "colorResered": {"type": "boolean", "default": False},
                "showPagation": {"type": "boolean", "default": True},
                "showRowTotal": {"type": "boolean", "default": True},
                "quotasSelect": {"type": "array", "default": []},
            },
        },
        "quotasSelect": {
            "type": "array",
            "description": "度量选择配置",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "checked": {"type": "boolean", "default": True},
                    "display_name": {"type": "string"},
                },
            },
        },
        "dynamic_params": {
            "type": "array",
            "description": "动态筛选参数；sqlCont 中的 ${Date:Date1} 占位符与此对应",
            "items": {
                "type": "object",
                "properties": {
                    "op": {"type": "string", "default": "noeffect"},
                    "type": {"type": "string", "description": "参数类型，如 Date"},
                    "sqlTem": {"type": "string", "description": "SQL 占位符，如 ${Date:Date1}"},
                    "showSql": {"type": "string"},
                    "defaultName": {"type": "string", "description": "占位符变量名"},
                    "info": {"type": "object"},
                },
            },
        },
    },
}


DATA_CONDITIONS_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": (
        "数据表（data）conditions — 明细列表，支持行级筛选。"
        "chart_type 固定填 data。"
        "顶层 col_types 为 SQL 全量输出列类型，chart_config.col_types 为展示列类型（可不同）。"
    ),
    "required": ["chart_type", "sql", "chart_config"],
    "properties": {
        "chart_type": {"type": "string", "const": CHART_DATA, "description": "固定填 data。禁止填 table/list/grid"},
        "sql": {"type": "string", "description": "静态 SQL（含硬编码日期，用于预览）"},
        "sqlCont": {
            "type": "string",
            "description": "参数化 SQL（含 ${Date:Date1} 等占位符）；有 dynamic_params 时必填",
        },
        "limit": {"type": "integer", "default": 1000},
        "showType": {"type": "string", "default": "chart"},
        "col_types": {
            "type": "object",
            "description": "顶层列类型 map，覆盖 SQL 全量输出列（值为 string/number/date）",
        },
        "chart_config": {
            "type": "object",
            "required": ["cols", "col_types"],
            "properties": {
                "cols": {"type": "array", "items": {"type": "string"}, "description": "展示列名列表"},
                "columns3": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "展示列顺序（通常与 cols 相同）",
                },
                "filters": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "可筛选列名字符串列表，如 ['人工单号', 'AI单号']",
                    "default": [],
                },
                "filters_array": {
                    "type": "array",
                    "description": "结构化筛选配置",
                    "items": {
                        "type": "object",
                        "properties": {
                            "field": {"type": "string", "description": "字段名"},
                            "type": {"type": "string", "description": "字段类型，如 string/date"},
                        },
                    },
                    "default": [],
                },
                "col_types": {
                    "type": "object",
                    "description": "展示列类型 map（值为 string/number/date）",
                },
                "quotasSelect": {"type": "array", "default": []},
            },
        },
        "quotasSelect": {"type": "array", "default": []},
        "dynamic_params": {
            "type": "array",
            "description": "动态筛选参数；sqlCont 中的 ${Date:Date1} 占位符与此对应",
            "items": {
                "type": "object",
                "properties": {
                    "op": {"type": "string", "default": "noeffect"},
                    "type": {"type": "string", "description": "参数类型，如 Date"},
                    "sqlTem": {"type": "string", "description": "SQL 占位符，如 ${Date:Date1}"},
                    "showSql": {"type": "string", "description": "可读 SQL 片段"},
                    "defaultName": {"type": "string", "description": "占位符变量名（与 sqlTem 中的变量一致）"},
                    "info": {"type": "object", "description": "日期范围详细配置"},
                },
            },
        },
    },
}

METRIC_CONDITIONS_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "指标卡（card）conditions — 将 SQL 结果列展示为 KPI 指标卡片",
    "required": ["chart_type", "sql", "chart_config"],
    "properties": {
        "chart_type": {"type": "string", "const": CHART_METRIC, "description": "固定填 card。禁止填 metric/number/indicator/kpi，平台不识别"},
        "sql": {"type": "string", "description": "静态 SQL（含硬编码日期范围）"},
        "sqlCont": {"type": "string", "description": "参数化 SQL；无动态筛选时与 sql 相同"},
        "limit": {"type": "integer", "default": 1000},
        "showType": {"type": "string", "default": "chart"},
        "chart_config": {
            "type": "object",
            "required": ["cols", "rows", "col_types"],
            "properties": {
                "cols": {"type": "array", "items": {"type": "string"}, "description": "SQL 所有输出列名"},
                "rows": {"type": "array", "items": {"type": "string"}, "description": "展示为指标卡的列名"},
                "rows1": {"type": "array", "default": []},
                "columns": {"type": "array", "default": []},
                "filters": {"type": "array", "default": []},
                "col_types": {"type": "object", "description": "列类型 map，值为 string 或 number"},
                "card": {
                    "type": "object",
                    "description": (
                        "每个指标列的展示配置。"
                        "key 为列名，value 为 {showLabel, showProgress, showProgressTarget}。"
                        "另含顶层 key：conditions（颜色阈值规则数组）和 colorChange（颜色方案如 red,orange,green）"
                    ),
                },
            },
        },
        "quotasSelect": {"type": "array", "default": []},
        "dynamic_params": {"type": "array", "description": "动态筛选参数", "default": []},
    },
}

PIVOT_CONDITIONS_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "透视表（pivot）conditions — chart_type 填 table，含维度列（rows）和度量列（columns）",
    "required": ["chart_type", "sql", "chart_config"],
    "properties": {
        "chart_type": {"type": "string", "const": CHART_PIVOT, "description": "固定填 table。禁止填 pivot/cross_table/matrix"},
        "sql": {"type": "string", "description": "静态 SQL（含硬编码日期，用于预览）"},
        "sqlCont": {
            "type": "string",
            "description": "参数化 SQL（含 ${Date:字段名} 占位符）；有 dynamic_params 时必填",
        },
        "limit": {"type": "integer", "default": 1000},
        "showType": {"type": "string", "default": "chart"},
        "col_types": {"type": "object", "description": "顶层列类型 map（与 chart_config.col_types 相同）"},
        "chart_config": {
            "type": "object",
            "required": ["cols", "rows", "columns", "col_types"],
            "properties": {
                "cols": {"type": "array", "items": {"type": "string"}, "description": "SQL 所有输出列名"},
                "rows": {"type": "array", "items": {"type": "string"}, "description": "维度列（行标题 / 分组依据）"},
                "columns": {"type": "array", "items": {"type": "string"}, "description": "度量列（数值列）"},
                "rows1": {"type": "array", "default": []},
                "filters": {"type": "array", "default": []},
                "col_types": {"type": "object", "description": "列类型 map，值为 string 或 number"},
            },
        },
        "quotasSelect": {
            "type": "array",
            "description": "度量选择配置",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "checked": {"type": "boolean", "default": True},
                    "display_name": {"type": "string"},
                },
            },
        },
        "dynamic_params": {
            "type": "array",
            "description": "动态筛选参数；sqlCont 中的 ${...} 占位符与此对应",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "参数显示名称（可选）"},
                    "type": {"type": "string", "description": "参数类型，如 Date"},
                    "sqlTem": {"type": "string", "description": "SQL 占位符，如 ${Date:日期}"},
                    "showSql": {"type": "string", "description": "可读 SQL 片段"},
                    "op": {"type": "string", "default": "noeffect"},
                    "defaultName": {"type": "string"},
                    "info": {"type": "object", "description": "日期范围详细配置"},
                },
            },
        },
        "outsideFilter": {
            "type": "array",
            "description": "看板外部筛选器；结构同 dynamic_params 但包装在 props.item 内，含 isOutside:true",
            "default": [],
        },
    },
}


# ── 工具函数 ─────────────────────────────────────────────────────────────────

def deep_merge(base: dict, override: dict) -> dict:
    """递归合并 override 到 base。

    override 的值覆盖 base 同名键；嵌套 dict 递归合并而非整体替换。
    用于「先取后改」场景：保留原 conditions 的完整结构，只更新指定字段。
    """
    result = dict(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


# ── 汇总 Schema（供 MCP tool definitions 使用）────────────────────────────────

CONDITIONS_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": (
        "报表核心配置。chart_type 决定图表类型，其余字段因类型而异。\n"
        "- chart_type=data：数据表（明细列表），需 chart_config.cols + col_types\n"
        "- chart_type=card：指标卡，需 chart_config.rows（KPI 列）\n"
        "- chart_type=table：透视表，需 chart_config.rows（维度）+ columns（度量）\n"
        "- chart_type=line：折线图，需 chart_config.rows（X轴时间列）+ columns（Y轴度量列）\n"
        "- chart_type=stack：堆叠图，需 rows（X轴）+ rows1（堆叠分组维度）+ columns（度量）\n"
        "- chart_type=donut：环形图，需 rows（切片分类维度）+ columns（切片大小度量）"
    ),
    "oneOf": [
        DONUT_CONDITIONS_SCHEMA,
        STACK_CONDITIONS_SCHEMA,
        LINE_CONDITIONS_SCHEMA,
        DATA_CONDITIONS_SCHEMA,
        METRIC_CONDITIONS_SCHEMA,
        PIVOT_CONDITIONS_SCHEMA,
    ],
}
