# SpendLogs And Usage Reference

Use this when a task mentions spend logs, monthly archives, usage reports, UI traffic analysis, or the usage WebApp.

## Monthly Archive Format

A monthly export workflow archives `public."LiteLLM_SpendLogs"` for a `YYYY-MM` window:

- Uses `startTime >= month_start` and `< next_month_start`.
- Exports a fixed column list to `data/LiteLLM_SpendLogs.csv`.
- Exports `data/request_ids.csv`.
- Dumps table schema to `schema/LiteLLM_SpendLogs.schema.sql`.
- Writes `manifest.env` with row count, UTC range, checksums, source database, and file paths.
- Creates `LiteLLM_SpendLogs_<month>_<timestamp>.tar.gz`.
- With `--delete-after-export`, deletes exactly the exported request IDs inside a transaction.

## Import Validation

A monthly import workflow:

- Extracts the archive and requires `archive_format=litellm_spendlogs_month_v1`.
- Verifies SHA-256 for data and request ID CSVs.
- Loads into a temp table shaped like `LiteLLM_SpendLogs`.
- Checks archive row count and duplicate `request_id`.
- In dry-run, reports archive rows, existing duplicates, would-insert, and would-skip.
- In import mode, uses `ON CONFLICT (request_id) DO NOTHING`.

## Delete Workflow

A monthly delete workflow:

- Requires `--month YYYY-MM`.
- Dry-run reports row count and first/last `startTime`.
- Delete mode creates a temp request-id table and deletes matched rows transactionally.

## Usage UI Traffic Pattern

Usage-oriented UI traffic commonly depends on these API families:

- `/spend/logs/ui` for paginated spend-log views.
- `/key/list` for key discovery and pagination.
- `/v2/model/info` for model metadata.
- `/key/aliases` for alias display and lookup.

Use this as evidence that the UI/usage workflow depends on key listing, model info, aliases, and spend-log UI endpoints.

## Usage WebApp Pattern

The FastAPI WebApp:

- Keeps `LITELLM_ADMIN_TOKEN` or `LITELLM_MASTER_KEY` server-side.
- Reads aliases from `Key_List.csv`.
- Caches alias-to-hash info for 120 seconds.
- Exposes `/api/virtual-keys` and `/api/usage/{alias}`.
- Returns summarized spend and token values without returning the admin token or key hash.
- Generalizes errors to avoid leaking internal details.

## Privacy And Retention

SpendLogs columns can include `messages`, `response`, `proxy_server_request`, requester IP, user, team, organization, agent, tool name, and metadata. If `store_prompts_in_spend_logs` is enabled, archive files can contain sensitive user prompts and model outputs.

Before sharing archives or screenshots, redact:

- virtual keys and key hashes
- prompts and responses
- requester IP addresses
- project/customer metadata
- admin tokens and SAS URLs
