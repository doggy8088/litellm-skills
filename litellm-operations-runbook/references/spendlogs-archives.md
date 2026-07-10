# SpendLogs Archive Reference

Use this for monthly `LiteLLM_SpendLogs` export/import/delete operations.

## Export

Use bundled script `scripts/spendlogs/export-spendlogs-month.sh --month YYYY-MM`:

- Exports rows where `startTime` is within the UTC month window.
- Creates `data/LiteLLM_SpendLogs.csv`, `data/request_ids.csv`, `schema/LiteLLM_SpendLogs.schema.sql`, and `manifest.env`.
- Records row count, UTC range, checksums, source database, and archive format.
- Uses `REPEATABLE READ` while selecting request IDs and exporting data.
- Supports `--dry-run` for count and output-path preview.
- Supports `--delete-after-export`, which deletes only exported request IDs after archive creation.

## Import

Use bundled script `scripts/spendlogs/import-spendlogs-month.sh --file archive.tar.gz`:

- Requires `manifest.env` and `archive_format=litellm_spendlogs_month_v1`.
- Verifies data and request-id SHA-256 checksums.
- Loads CSV into a temp table matching `LiteLLM_SpendLogs`.
- Checks row count and duplicate `request_id`.
- Dry-run reports existing duplicates and would-insert counts.
- Import mode uses `ON CONFLICT (request_id) DO NOTHING`.

## Delete

Use bundled script `scripts/spendlogs/delete-spendlogs-month.sh --month YYYY-MM`:

- Dry-run reports row count and first/last timestamps.
- Delete mode captures matching `request_id` values in a temp table, deletes them in a transaction, and reports matched/deleted counts.

## Operational Rules

- Export before deleting unless the user explicitly confirms retention-only deletion.
- Keep archives and manifests together.
- Treat archives as sensitive because they may contain prompts, responses, proxy request data, IP addresses, metadata, and agent/tool identifiers.
- Validate with dry-run before import or delete.
- Use absolute month windows and document whether UTC or local timezone is used.
