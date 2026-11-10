# Reference-porting boundary

`hlhy_data_ai` is used as an architectural reference only. Its company-owned assets are not FiveCross assets.

## Reused deliberately

- FastAPI/React application shell and streaming chat contract.
- Read-only SQL guard, retrieval stores, analysis workflow, report artifact layer.
- Game selection and project-scoped visibility patterns.

## Replaced or isolated

- 欢乐互娱/ROO/JoyData table dictionaries: removed from `assets/`.
- Company-specific game inventory: replaced/extended through `games.json` with FiveCross projects.
- Database execution: routed through `fivecross-data-client`, not copied database connectors or credentials.
- SQL and business logic: seeded only from FiveCross repositories by `scripts/bootstrap_fivecross_sources.py`.
- Large AliCloud backups: external-only reference; never copied into the platform.
- AI endpoint: no hard-coded internal company gateway; use `LITELLM_BASE_URL`/`OPENAI_BASE_URL` from `.env`.

## Remaining migration work

The copied reference shell still contains optional legacy modules such as Joydata/Feishu adapters. They must remain disabled or be removed before production if the FiveCross deployment does not provide those services. They are not used by the Slam Dunk ODPS route.
