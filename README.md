# FiveCross Data Platform

AI-native game analytics platform rebuilt from `hlhy_data_ai`, with the canonical FiveCross data assets and data client as its source-of-truth.

## What this rebuild includes

- **Chat + agent analysis**: FastAPI backend, streaming chat, SQL generation, report/forecast workflows, chart and artifact delivery.
- **Project-aware game library**: `games.json` separates projects by game and region. Slam Dunk China has a dedicated AliCloud MaxCompute route through `fivecross-data-client`; Slam Dunk TC/GL/KR remain ThinkingData/Trino projects. The mainland-China route is based on the observed `app_id/game_id=13002010` assets and must not be inferred from the TC/GL/KR event mappings.
- **Searchable knowledge base**: SQL, logic rules, analysis cases, and event-tracking documents are mirrored into `sql/` and `knowledge/docs/` by an auditable bootstrap script. The upstream repositories remain authoritative.
- **External backup reference**: `fivecross-aliyun-backup` is registered in `config/source_registry.yaml` but never recursively copied; it is too large and remains an external reference.
- **Canonical database access**: The `fivecross-data-client` execution framework is vendored under `vendor/fivecross_data_client/`; AliCloud and ThinkingData credentials are owned by this platform's `.env`. The upstream client repository remains the synchronization source.
- **Fixed report contract**: Analysis reports use the four required sections: `📊 概览`, `🎯 成因结论`, `🔍 明细下钻`, `🔮 预测`.

## Source repositories

| Capability | Repository |
|---|---|
| Reference platform | `C:/Users/5xgames/Desktop/github/hlhy_data_ai` |
| Platform | `C:/Users/5xgames/Desktop/github/fivecross-data-platform` |
| SQL library | `C:/Users/5xgames/Desktop/github/fivecross-sql-lib` |
| Analysis cases | `C:/Users/5xgames/Desktop/github/fivecross-analysis-cases` |
| Event-tracking documents | `C:/Users/5xgames/Desktop/github/shinchan-events-tracking` |
| DB access client | `C:/Users/5xgames/Desktop/github/fivecross-data-client` |

## Web search

Web search uses configured Tavily, Serper, or Bing providers and retains its result cache. The platform does not impose daily/monthly search allowances or display remaining calls. Missing provider configuration or provider failure is reported as unavailable, never as fabricated results. LLM token/cost usage remains independent.

## Installation

Use Python 3.11 for compatibility with the existing `fivecross-data-client` environment.

```bash
cd C:/Users/5xgames/Desktop/github/fivecross-data-platform
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements.txt
copy .env.example .env
```

The platform uses the vendored client in `vendor/fivecross_data_client/` for AliCloud/TA queries. Its upstream source is `C:/Users/5xgames/Desktop/github/fivecross-data-client`; use the upstream repository when synchronizing client changes. Credentials are stored in this platform's `.env`, not in a second client `.env`.

## Configuration

`.env` contains runtime-only values. Important settings:

- `OPENAI_API_KEY`: internal OpenAI-compatible/LiteLLM gateway key.
- `FIVECROSS_DATA_CLIENT_ROOT`: canonical `fivecross-data-client` path.
- `FIVECROSS_CLIENT_TIMEOUT`: external query timeout in seconds.
- `AUTH_ENABLED`, `AUTH_TOKEN`: optional platform access control.
- `LITELLM_BASE_URL` / `OPENAI_BASE_URL`: OpenAI-compatible AI endpoint.

The copied reference project's `DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME` and
JoyData/Feishu settings are not FiveCross configuration and are not loaded here.
The legacy MySQL/StarRocks adapter is disabled unless explicitly enabled with
`ENABLE_LEGACY_MYSQL=true`; normal FiveCross data access never uses it.

## Sync knowledge and SQL sources

```bash
python scripts/bootstrap_fivecross_sources.py
```

The command reports the number of mirrored SQL and Markdown files. It skips `.git` and `node_modules`; each mirrored file receives a source metadata sidecar. Re-run after updating upstream repositories.

## Run

```bash
python -m uvicorn backend.main:app --host 0.0.0.0 --port 8000 --reload
```

Open `http://127.0.0.1:8000`. The root UI is the SQL/analysis workspace; the legacy chat UI is available at `/app`.

## Slam Dunk China query routing

Select `灌篮高手中国（阿里云）` (`slam_dunk_cn_ali`). Agent SQL is passed to the vendored `fivecross-data-client` with engine `odps`, region `china`, and credentials from this platform's `.env`. This is intentionally separate from the overseas ThinkingData projects.

For revenue, use the validated source schema and explicitly state the window, source, and currency. The default rolling window is the last 30 calendar dates through today; do not call it “all-time first payment”. The AliCloud monthly KPI cases document coverage only through 2026-05-27; for later periods, do not silently apply those historical ODPS templates. The tested `transaction_wallet` route is a separate wallet/charge metric and must be labeled as such.

## Verification

```bash
python -m compileall -q .
python scripts/bootstrap_fivecross_sources.py
```

For live data verification, run the platform and query:

> 查询灌篮高手中国（阿里云）近一个月收入，按日返回收入、订单数、付费用户数，并说明时间窗口和币种。

If AliCloud returns a schema or credential error, preserve the exact error and inspect the corresponding client/project configuration rather than silently switching to another database.

## Security and operational rules

- Keep `.env`, browser sessions, exported data, and database credentials out of Git.
- All generated SQL passes the existing read-only guard before native execution.
- The data client is the only integration boundary for ODPS, Hologres, and ThinkingData.
- Analysis conclusions must distinguish measured revenue from proxy metrics and include source, window, currency, denominator, and aggregation grain.
