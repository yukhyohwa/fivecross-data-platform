#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
审计 P2-13：dist/src 漂移校验（服务器无 Node，纯 Python 实现，零第三方依赖）

用法（在 data_ai 目录下）：
    python scripts/check_dist_drift.py          # 校验：ide_frontend/dist 指纹 vs 当前 src 内容哈希
    python scripts/check_dist_drift.py --stamp  # 构建后打标：把当前 src 指纹写入 dist/.src-fingerprint.json

退出码：
    0 = 一致（或无任何源文件）
    1 = 漂移：dist 落后于 src（改了 src 但没重新构建），或文件被增删
    2 = dist 缺少指纹文件（旧构建产物，建议重新构建后 --stamp）

后端 lifespan 启动时会调用 check_only()：仅在漂移时向 server_out.log 打警告，绝不阻塞启动。
"""
import hashlib
import json
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = PROJECT_ROOT / "ide_frontend" / "src"
DIST_DIR = PROJECT_ROOT / "ide_frontend" / "dist"
FINGERPRINT_FILE = DIST_DIR / ".src-fingerprint.json"


def compute_fingerprint() -> dict:
    """内容哈希指纹：{relpath: sha256}，与 mtime 无关（改回原内容即视为一致）。"""
    files = {}
    if not SRC_DIR.is_dir():
        return files
    for p in sorted(SRC_DIR.rglob("*")):
        if p.is_file():
            rel = p.relative_to(SRC_DIR).as_posix()
            files[rel] = hashlib.sha256(p.read_bytes()).hexdigest()
    return files


def overall_hash(files: dict) -> str:
    h = hashlib.sha256()
    for rel in sorted(files):
        h.update(rel.encode("utf-8"))
        h.update(b"\x00")
        h.update(files[rel].encode("utf-8"))
        h.update(b"\x00")
    return h.hexdigest()


def stamp() -> int:
    files = compute_fingerprint()
    payload = {
        "fingerprint": overall_hash(files),
        "built_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "file_count": len(files),
        "files": files,  # 逐文件内容哈希：漂移时可定位具体文件
    }
    DIST_DIR.mkdir(parents=True, exist_ok=True)
    FINGERPRINT_FILE.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"[dist-drift] 已写入指纹 {FINGERPRINT_FILE}（{len(files)} 个源文件）")
    return 0


def check_only(log=print) -> int:
    """供 CLI 与后端 lifespan 复用；漂移时经 log 输出警告。"""
    if not FINGERPRINT_FILE.exists():
        log("[dist-drift] [WARN] dist 缺少 .src-fingerprint.json 指纹（旧构建产物），"
            "无法校验 src/dist 一致性；请重新构建并在构建后执行 --stamp 打标")
        return 2
    try:
        stored = json.loads(FINGERPRINT_FILE.read_text(encoding="utf-8"))
    except Exception as e:
        log(f"[dist-drift] [WARN] 指纹文件损坏无法解析：{e}")
        return 2

    current = compute_fingerprint()
    cur_hash = overall_hash(current)
    if cur_hash == stored.get("fingerprint"):
        return 0

    stored_files = set()
    if isinstance(stored.get("files"), dict):
        stored_files = set(stored["files"])
    else:  # 旧格式只存总指纹：无法定位具体文件，仅报告总量级漂移
        log(f"[dist-drift] [WARN] src 与 dist 指纹不一致（stored={stored.get('fingerprint', '?')[:12]}… "
            f"current={cur_hash[:12]}…）：src 已改动但 dist 未重新构建，请重新构建 ide_frontend")
        return 1

    changed, added, removed = [], [], []
    for rel in sorted(set(current) | stored_files):
        in_cur, in_old = current.get(rel), stored["files"].get(rel)
        if in_cur and in_old and in_cur != in_old:
            changed.append(rel)
        elif in_cur and not in_old:
            added.append(rel)
        elif in_old and not in_cur:
            removed.append(rel)

    lines = ["[dist-drift] [WARN] src 与 dist 漂移：改了 src 但 dist 未重新构建，线上将运行旧前端："]
    for label, arr in (("改动", changed), ("新增", added), ("删除", removed)):
        if arr:
            lines.append(f"    {label}({len(arr)})：{', '.join(arr[:20])}"
                         + ("…" if len(arr) > 20 else ""))
    for line in lines:
        log(line)
    return 1


if __name__ == "__main__":
    sys.exit(stamp() if "--stamp" in sys.argv else check_only())
