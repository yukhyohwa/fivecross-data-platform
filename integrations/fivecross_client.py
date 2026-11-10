"""Data access adapter for the canonical fivecross-data-client repository."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pandas as pd

PLATFORM_ROOT = Path(__file__).resolve().parents[1]
CLIENT_ROOT = Path(os.environ.get("FIVECROSS_DATA_CLIENT_ROOT", PLATFORM_ROOT / "vendor" / "fivecross_data_client"))
BRIDGE = PLATFORM_ROOT / "integrations" / "fivecross_client_bridge.py"


def _python() -> str:
    candidates = [
        CLIENT_ROOT / "venv" / "Scripts" / "python.exe",
        CLIENT_ROOT / ".venv" / "Scripts" / "python.exe",
        CLIENT_ROOT / "venv" / "bin" / "python",
        CLIENT_ROOT / ".venv" / "bin" / "python",
    ]
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    return sys.executable


def fetch(sql: str, engine: str = "odps", region: str = "china") -> pd.DataFrame:
    """Execute SQL through fivecross-data-client, never through a second DB connector."""
    if not CLIENT_ROOT.exists():
        raise RuntimeError(f"fivecross-data-client not found: {CLIENT_ROOT}")
    proc = subprocess.run(
        [_python(), str(BRIDGE), engine, region],
        input=sql,
        text=True,
        capture_output=True,
        cwd=str(CLIENT_ROOT),
        env={
            **os.environ,
            "PYTHONPATH": str(CLIENT_ROOT),
            "FIVECROSS_DATA_CLIENT_ROOT": str(CLIENT_ROOT),
            "FIVECROSS_PLATFORM_ROOT": str(PLATFORM_ROOT),
        },
        timeout=int(os.environ.get("FIVECROSS_CLIENT_TIMEOUT", "600")),
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "unknown client error").strip()
        raise RuntimeError(f"fivecross-data-client query failed ({proc.returncode}): {detail[-4000:]}")
    try:
        payload = json.loads(proc.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError) as exc:
        raise RuntimeError(f"fivecross-data-client returned invalid JSON: {proc.stdout[-1000:]}") from exc
    return pd.DataFrame(payload.get("rows", []), columns=payload.get("columns", []))
