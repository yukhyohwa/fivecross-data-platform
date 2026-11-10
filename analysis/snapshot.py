"""快照与溯源：生成下游工件时对上游内容「改写后冻结 + 记源 + 指纹漂移判定」。

语义（与四工件独立 / 快照方案对齐）：
- fingerprint 对「原始来源内容」打 sha256 指纹；
- snapshot_entry 记录 {kind, name, fingerprint(原始), content(改写后冻结)}；
- drifted 载入时比对当前源指纹，不一致即「源已改动，需手动更新」（不自动）。

下游工件用冻结的 content 执行（保证准确性与速度），用 fingerprint 检测源是否漂移。
"""
from __future__ import annotations

import hashlib

KINDS = ("doc", "sql", "model")


def fingerprint(text: str) -> str:
    """返回文本的 sha256 指纹（对原始来源内容使用）。"""
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()


def snapshot_entry(kind: str, name: str, original: str, adapted: str) -> dict:
    """构造一条快照：{kind, name, fingerprint, content}。

    kind ∈ doc|sql|model；name 为源裸名；fingerprint 对 original（原始来源）打指纹；
    content 为改写后冻结的下游可执行内容。
    """
    return {
        "kind": kind,
        "name": (name or "").strip(),
        "fingerprint": fingerprint(original),
        "content": adapted or "",
    }


def provenance_entry(kind: str, name: str, original: str) -> dict:
    """构造一条轻量溯源：{kind, name, fingerprint}（不含内容，供 SQL/模型 manifest 记源+漂移）。"""
    return {
        "kind": kind,
        "name": (name or "").strip(),
        "fingerprint": fingerprint(original),
    }


def drifted(entry: dict, current_original: str) -> bool:
    """载入时比对：当前源内容指纹与快照记录不一致 → 源已改动（需手动更新）。

    无指纹 / 非法 entry 视为「不可判定 → 需更新」。
    """
    if not isinstance(entry, dict):
        return True
    stored = entry.get("fingerprint")
    if not stored:
        return True
    return stored != fingerprint(current_original)


# ---- 快照改编模式：记录「全局源 → 本专项快照」的关系策略（三态漂移用）----

MODE_FOLLOW = "follow"      # 跟随全局：全局更新时可通过「刷新」重新同步
MODE_PIN = "pin"            # 锁定：无外部源（缺失生成）或刻意不再跟随全局
MODE_ADAPTED = "adapted"    # 已针对专项改编：与全局有意分叉，刷新需人工确认
VALID_MODES = (MODE_FOLLOW, MODE_PIN, MODE_ADAPTED)


def normalize_mode(mode) -> str:
    """把任意 mode 值归一化到 VALID_MODES，非法/缺失回退 follow。"""
    return mode if mode in VALID_MODES else MODE_FOLLOW


def drift_state(entry: dict, current_source: str | None = None,
                current_snapshot: str | None = None) -> str:
    """三态漂移判定（取代布尔 drifted，供 UI 区分「全局动了」还是「专项改了」）。

    返回：
    - "orphan"  无外部源/指纹（缺失生成），不参与漂移比对；
    - "clean"   源未变、快照未被本地改编；
    - "drifted" 源已更新（全局向前走了，快照仍冻结在旧版）；
    - "adapted" 快照被就地改编（与冻结时内容不同）；
    - "both"    源更新且快照也被本地改编。

    entry 的 fingerprint 为「冻结时源指纹」（= base），content_fingerprint 为
    「冻结时快照内容指纹」，二者配合即可把「全局动了」与「专项改了」分开判定。
    """
    if not isinstance(entry, dict):
        return "orphan"
    source = (entry.get("source") or "").strip()
    stored = entry.get("fingerprint")
    if not source or not stored:
        return "orphan"
    source_moved = current_source is not None and stored != fingerprint(current_source)
    local = False
    content_fp = entry.get("content_fingerprint")
    if content_fp and current_snapshot is not None:
        local = content_fp != fingerprint(current_snapshot)
    if source_moved and local:
        return "both"
    if source_moved:
        return "drifted"
    if local:
        return "adapted"
    return "clean"
