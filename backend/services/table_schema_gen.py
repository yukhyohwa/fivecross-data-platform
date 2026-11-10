"""Guard for the retired legacy schema rebuild endpoint.

The former implementation consumed JoyTools Excel and a live ``pf_`` database.
That source is archived.  Keeping this small module avoids an import-time break
for status tooling while making accidental regeneration fail closed.
"""
from .. import config

OUT_PATH = config.DATA_AI_ROOT / "knowledge" / "table_schema" / "table_schema.json"


def rebuild_table_schema(engine=None) -> dict:
    raise RuntimeError(
        "Legacy table-schema rebuild is disabled; use a verified FiveCross schema manifest."
    )
