"""Explain SQL without assuming a company-specific schema."""
from __future__ import annotations
import re

_AGG = {"sum":"求和", "count":"计数", "avg":"平均", "max":"最大值", "min":"最小值"}
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
_REL = re.compile(r"(?:date_sub|date_add|current_date|now\(\)|today)", re.I)

def explain_sql(sql: str, question: str | None = None) -> str:
    s=(sql or "").strip()
    if not s: return ""
    low=s.lower(); parts=[]
    aggs=[f"{name}（{_AGG[fn]}）" for fn in _AGG for name in re.findall(rf"{fn}\s*\(\s*([A-Za-z_][A-Za-z0-9_.]*)", low)]
    if aggs: parts.append("统计 " + "、".join(aggs))
    gm=re.search(r"group\s+by\s+(.+?)(?:\s+(?:order|limit|having)|$)", low, re.I|re.S)
    if gm:
        cols=[re.findall(r"[A-Za-z_][A-Za-z0-9_]*", x)[-1] for x in re.split(r"\s*,\s*",gm.group(1)) if re.findall(r"[A-Za-z_][A-Za-z0-9_]*",x)]
        if cols: parts.append("按 " + "、".join(cols) + " 分组")
    dates=sorted(set(_DATE.findall(s)))
    if len(dates)>=2: parts.append(f"取数区间 {dates[0]} ~ {dates[-1]}")
    elif dates: parts.append(f"取数日期 {dates[0]}")
    elif _REL.search(s): parts.append("最近一段时间")
    lm=re.search(r"limit\s+(\d+)",low)
    if lm: parts.append(f"取前 {lm.group(1)} 条")
    return "，".join(parts)+"。" if parts else ""
