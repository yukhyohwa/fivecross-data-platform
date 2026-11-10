"""原子写文件：先写同目录临时文件再 os.replace，避免中途崩溃/并发留下半截文件。

data_ai 与 analysis 共用。凡「整个文件一次性重写」的落盘点，都应走这里而不是直接
Path.write_text / open('w')——后者在写入中途进程被杀会留下损坏的半截 JSON（读端
json.loads 直接崩，且污染后难以自愈）。
"""
from __future__ import annotations

import os
from pathlib import Path


def atomic_write_text(target: Path, text: str, **kwargs) -> None:
    """原子写文本到 target（kwargs 原样传给 write_text，如 encoding/newline）。"""
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(text, **kwargs)
    os.replace(tmp, target)
