"""深度分析会话级取数结果存储（数据浓缩 + 分页读回）。

问题：query_database 的预览结果经 tool_result_to_str 统一按字符硬截断后，模型看到的是
残缺数据，反而「因获取数据不全而无法分析」。JoyTools 88 Agent 的解法是 spill：超预算的
结果整份暂存到会话存储，模型先拿「信封」（result_id + 总数 + 样本行 + 读回指引），需要
更多数据时用 read_result_rows 按页读回——浓缩但不失真。

本模块只依赖标准库，不 import 业务模块；store 实例挂在 ctx["result_store"] 上，
随请求生命周期自然回收（每个深度分析请求一个独立 ctx，流结束即释放）。
"""
import json
import time

# 信封中行数据的字符预算：行样本自适应压缩到该预算内（总工具结果上限另由
# settings.AGENT_TOOL_RESULT_MAX_CHARS 控制，样本预算 = 上限 - RESERVE，且不低于 MIN）
ROW_PAYLOAD_RESERVE_CHARS = 1400
ROW_PAYLOAD_MIN_CHARS = 1200
SAMPLE_FLOOR_ROWS = 3          # 信封最少保留的样本行数
MAX_PAGE_ROWS = 500            # read_result_rows 单页上限
STORE_CAPACITY = 8             # 单个会话最多暂存的结果数（LRU 淘汰）
STORE_MAX_BYTES = 32 * 1024 * 1024  # 单会话暂存结果总字节预算（估算值，防宽表大结果叠加撑爆内存）
ESTIMATE_SAMPLE_ROWS = 100     # 字节/字符估算的抽样行数上限（避免整份 dumps 的临时大字符串）


class ResultStore:
    """会话级取数结果暂存（LRU）。rows 为 JSON 安全的行列表（已做 NaN/Inf→None 转换）。

    淘汰同时受「份数上限（capacity）」与「总字节预算（max_bytes）」约束：任一超限
    即按 LRU 淘汰最旧结果，但至少保留最新一份（信封模式的 result_id 必须可用）。
    max_bytes=0 表示关闭字节预算，退回纯份数上限。
    """

    def __init__(self, capacity: int = STORE_CAPACITY, max_bytes: int = STORE_MAX_BYTES):
        self._data: dict[str, dict] = {}
        self._order: list[str] = []
        self._seq = 0
        self.capacity = max(1, int(capacity))
        self.max_bytes = max(0, int(max_bytes))
        self._sizes: dict[str, int] = {}   # rid -> 估算字节数
        self._total_bytes = 0              # 当前暂存总估算字节数

    def _estimate_bytes(self, entry: dict) -> int:
        """抽样估算一份结果的序列化字节数（样本行平均长度 × 行数，再加列名与 SQL）。

        宽表单份结果动辄数十 MB，整份 json.dumps 会产生等量临时字符串，故只对
        最多 ESTIMATE_SAMPLE_ROWS 个均匀抽样行做 dumps 再按行数外推；估算值仅用于
        淘汰决策，不要求精确。
        """
        rows = entry["rows"]
        if not rows:
            base = 0
        elif len(rows) <= ESTIMATE_SAMPLE_ROWS:
            base = len(json.dumps(rows, ensure_ascii=False, default=str))
        else:
            step = len(rows) // ESTIMATE_SAMPLE_ROWS
            sample = rows[::step][:ESTIMATE_SAMPLE_ROWS]
            avg = len(json.dumps(sample, ensure_ascii=False, default=str)) / len(sample)
            base = int(avg * len(rows))
        base += len(json.dumps(entry["columns"], ensure_ascii=False))
        base += len(entry.get("sql") or "")
        return base

    def put(self, columns: list, rows: list, total_rows: int, sql: str = "") -> str:
        """暂存一份完整结果，返回 result_id（如 r0/r1/…）。超容量/超字节预算按 LRU 淘汰最旧结果。"""
        rid = f"r{self._seq}"
        self._seq += 1
        entry = {
            "columns": list(columns),
            "rows": rows,
            "total_rows": int(total_rows),
            "sql": sql,
            "saved_at": time.time(),
        }
        self._data[rid] = entry
        self._sizes[rid] = self._estimate_bytes(entry)
        self._total_bytes += self._sizes[rid]
        self._order.append(rid)
        # 淘汰：份数超上限，或总估算字节超预算；至少保留最新一份（信封流程依赖它可用）
        while len(self._order) > 1:
            over_count = len(self._order) > self.capacity
            over_bytes = bool(self.max_bytes) and self._total_bytes > self.max_bytes
            if not (over_count or over_bytes):
                break
            old = self._order.pop(0)
            self._data.pop(old, None)
            self._total_bytes -= self._sizes.pop(old, 0)
        return rid

    def get(self, rid: str) -> dict | None:
        """取整份结果（含 rows 全量），不存在（已淘汰）返回 None。"""
        return self._data.get(rid)

    def page(self, rid: str, offset: int = 0, limit: int = MAX_PAGE_ROWS) -> dict | None:
        """按页读回：返回 {result_id, columns, rows, offset, next_offset, total_rows}。"""
        entry = self._data.get(rid)
        if entry is None:
            return None
        offset = max(0, int(offset))
        limit = min(max(1, int(limit)), MAX_PAGE_ROWS)
        rows = entry["rows"]
        page_rows = rows[offset:offset + limit]
        return {
            "result_id": rid,
            "columns": entry["columns"],
            "rows": page_rows,
            "offset": offset,
            "next_offset": offset + len(page_rows) if offset + len(page_rows) < len(rows) else None,
            "total_rows": entry["total_rows"],
        }


def fit_rows_budget(rows: list, budget_chars: int, floor: int = SAMPLE_FLOOR_ROWS) -> tuple:
    """把行样本自适应压缩到约 budget_chars 字符内（对半收缩，最少保留 floor 行）。

    返回 (rows_out, kept)。长度按 json.dumps(ensure_ascii=False) 估算，与
    tool_result_to_str 的实际序列化口径一致。大结果（数千行 × 宽列）每次整份
    dumps 会产生数 MB 级临时字符串，对半收缩会反复触发；这里先按抽样行估算
    总长度（样本平均 × 行数），估计值落在预算内时再做一次整份 dumps 精确校验，
    输出口径与原实现一致。
    """
    rows = list(rows)
    if not rows:
        return rows, 0

    def _estimate(row_list: list) -> int:
        """抽样估算序列化字符数：样本行平均长度 × 行数（小结果整份 dumps 即精确值）。"""
        if len(row_list) <= ESTIMATE_SAMPLE_ROWS:
            return len(json.dumps(row_list, ensure_ascii=False, default=str))
        step = len(row_list) // ESTIMATE_SAMPLE_ROWS
        sample = row_list[::step][:ESTIMATE_SAMPLE_ROWS]
        avg = len(json.dumps(sample, ensure_ascii=False, default=str)) / len(sample)
        return int(avg * len(row_list))

    while len(rows) > floor:
        if _estimate(rows) > budget_chars:
            rows = rows[: max(floor, len(rows) // 2)]
            continue
        # 估计值落在预算内：整份 dumps 精确校验，仍超则继续对半收缩
        if len(json.dumps(rows, ensure_ascii=False, default=str)) <= budget_chars:
            break
        rows = rows[: max(floor, len(rows) // 2)]
    return rows, len(rows)


def compute_row_budget(tool_cap) -> int:
    """按工具结果总上限推样本预算：cap - RESERVE，下限 ROW_PAYLOAD_MIN_CHARS。"""
    try:
        cap = int(tool_cap or 0)
    except (TypeError, ValueError):
        cap = 0
    if cap <= 0:
        cap = 4000
    return max(ROW_PAYLOAD_MIN_CHARS, cap - ROW_PAYLOAD_RESERVE_CHARS)
