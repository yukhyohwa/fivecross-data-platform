"""Bridge executed inside fivecross-data-client's Python environment.
Reads one SQL query from stdin and writes a JSON DataFrame payload to stdout.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv

CLIENT_ROOT = Path(os.environ.get("FIVECROSS_DATA_CLIENT_ROOT", Path(__file__).resolve().parents[1] / "vendor" / "fivecross_data_client"))
PLATFORM_ROOT = Path(os.environ.get("FIVECROSS_PLATFORM_ROOT", Path(__file__).resolve().parents[1]))
load_dotenv(PLATFORM_ROOT / ".env")
if str(CLIENT_ROOT) not in sys.path:
    sys.path.insert(0, str(CLIENT_ROOT))


def main() -> int:
    engine_name = (sys.argv[1] if len(sys.argv) > 1 else "odps").strip().lower()
    region = (sys.argv[2] if len(sys.argv) > 2 else "china").strip().lower()
    sql = sys.stdin.read()
    if not sql.strip():
        raise ValueError("SQL is empty")

    from src.config import settings
    if engine_name == "odps":
        from src.core.engines.ali_engine import ODPSEngine
        cfg = settings.ALI_CREDENTIALS[region]["odps"]
        df = ODPSEngine(cfg).fetch(sql)
    elif engine_name in {"ta", "thinkingdata"}:
        from src.core.engines.ta_engine import ThinkingDataEngine
        cfg = settings.TA_CREDENTIALS[region]
        # The client deliberately uses its own TA .env/session, not the platform .env.
        df = ThinkingDataEngine(cfg).fetch(sql, headless=True)
    elif engine_name == "holo":
        from src.core.engines.ali_engine import HoloEngine
        cfg = settings.ALI_CREDENTIALS[region]["holo"]
        df = HoloEngine(cfg).fetch(sql)
    else:
        raise ValueError(f"Unsupported fivecross engine: {engine_name}")

    if not isinstance(df, pd.DataFrame):
        df = pd.DataFrame(df)
    payload = {"columns": [str(c) for c in df.columns], "rows": df.where(pd.notna(df), None).values.tolist()}
    print(json.dumps(payload, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
