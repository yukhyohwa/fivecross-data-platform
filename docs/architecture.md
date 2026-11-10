# Architecture and source boundaries

## Layers

```text
backend/                 FastAPI transport, auth, routers, orchestration
analysis/                Retrieval, SQL safety, prompts, report rules, stores
integrations/            External data-client bridges only
config/                  Non-secret source and runtime policy
knowledge/docs/          Mirrored searchable documents + metadata
knowledge/skills/        Analysis-specialty bundles
sql/                     Mirrored and platform-authored read-only SQL
scripts/                 Repeatable bootstrap, validation and maintenance commands
frontend/                User chat/report surface
ide_frontend/            SQL IDE and administration surface
```

## Data boundary

`fivecross-data-client` is the canonical execution boundary for ThinkingData, AliCloud ODPS and Hologres. The platform's `integrations/fivecross_client.py` invokes its existing Python environment through a small JSON bridge; it does not duplicate credentials or database drivers.

`fivecross-aliyun-backup` is an external reference only. It is registered in `config/source_registry.yaml` for future schema/backup inspection but is deliberately excluded from bootstrap copying because it is large and may contain operational snapshots.

## Game routing

- `slam_dunk_cn_ali`: `odps / china` through the external client.
- `slam_dunk_tc`, `slam_dunk_gl`, `slam_dunk_kr`: ThinkingData/Trino project metadata and SQL assets; execution must use the client's TA route when those projects are enabled.
- Existing non-Slam-Dunk projects retain the native StarRocks-compatible route from the reference platform.

## Query contract

Every analysis result records source, project, engine, exact date window, currency, aggregation grain, numerator and denominator. Rolling “last month” means a 30-calendar-day window only when the user asks for “近一个月”; calendar-month reporting must use explicit month boundaries.
