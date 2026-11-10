# Platform-owned assets

This directory intentionally contains no copied `hlhy_data_ai` table dictionaries.

The previous reference repository's `table_info.xlsx` and `table_column_info.xlsx` describe 欢乐互娱/RO3/ROO/JoyData schemas and are not authoritative for FiveCross. They were removed from this rebuild.

FiveCross schema sources are resolved by project:

- AliCloud China and overseas: `fivecross-data-client` plus the relevant SQL in `fivecross-sql-lib`.
- ThinkingData/Trino: the per-game event tables and SQL under `fivecross-sql-lib/games`.
- Event contracts: `shinchan-events-tracking` where applicable.
- Large AliCloud backup: external-only reference in `config/source_registry.yaml`.

Add a file here only when it is owned by FiveCross and has a documented source, game scope, date coverage, and refresh owner.
