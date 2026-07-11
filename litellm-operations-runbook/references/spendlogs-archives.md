# SpendLogs Archive Reference

Use this for monthly `LiteLLM_SpendLogs` export/import/delete operations.

## Export

Use the bundled script with an explicit age recipient:

```bash
scripts/spendlogs/export-spendlogs-month.sh \
  --month YYYY-MM \
  --age-recipient '<reviewed age public recipient>'
```

- Sets the PostgreSQL session timezone to UTC and exports rows where `startTime` is within the half-open UTC month window.
- Creates `data/LiteLLM_SpendLogs.csv`, `data/request_ids.csv`, `schema/LiteLLM_SpendLogs.schema.sql`, and `manifest.env`.
- Records row count, explicit `Z`-suffixed UTC range, SHA-256 checksums for data, request IDs, and schema, source database, and archive format.
- Uses `REPEATABLE READ` while selecting request IDs and exporting data.
- Supports `--dry-run` for count and output-path preview.
- Uses process `umask 077`, validates plaintext below a mode-0700 temporary directory, then publishes only `.tar.gz.age` authenticated ciphertext and its `.sha256` sidecar.
- Uses archive format `litellm_spendlogs_month_v2`. Version 1 archives are not accepted because they do not carry all required integrity evidence.

Post-export deletion is never implied by export. It requires all three flags and an exact count from a preceding dry-run:

```bash
scripts/spendlogs/export-spendlogs-month.sh \
  --month 2026-06 \
  --age-recipient '<reviewed age public recipient>' \
  --delete-after-export \
  --execute \
  --expect-count 12345
```

The script validates the completed archive, rechecks the exported count, and deletes only the exported request IDs inside the same UTC month. It refuses the current UTC month unless `--force-current-month` is also supplied.

## Import

Use the encrypted archive and an explicit identity file:

```bash
scripts/spendlogs/import-spendlogs-month.sh \
  --file archive.tar.gz.age \
  --age-identity /run/secrets/litellm-spendlogs-age-identity
```

- Requires `manifest.env` and `archive_format=litellm_spendlogs_month_v2`.
- Accepts only the six fixed archive members: `manifest.env`, the `data` and `schema` directories, and their three expected regular files.
- Rejects absolute paths, `..` traversal, unexpected or duplicate members, and symbolic or hard links. Files are copied out with restrictive permissions instead of using unrestricted `tar -x` extraction.
- Requires manifest file paths to exactly match the fixed member paths and verifies data, request-ID, and schema SHA-256 checksums.
- Verifies that the data CSV and request-ID CSV both match `row_count`, contain unique non-empty IDs, and represent exactly the same request-ID set.
- Verifies every data-row `startTime` is inside the manifest's half-open UTC month.
- Enforces configurable member and total extraction limits through `LITELLM_ARCHIVE_MAX_MEMBER_BYTES` and `LITELLM_ARCHIVE_MAX_TOTAL_BYTES`.
- Loads CSV into a temp table matching `LiteLLM_SpendLogs`.
- Repeats row-count, uniqueness, and request-ID-set checks in PostgreSQL before import.
- Dry-run reports existing duplicates and would-insert counts.
- Import mode uses `ON CONFLICT (request_id) DO NOTHING`.

## Delete

Without `--execute`, the delete script is always a preview:

```bash
scripts/spendlogs/delete-spendlogs-month.sh --month 2026-06 --dry-run
```

Preferred deletion supplies the validated archive as proof and pins the observed count:

```bash
scripts/spendlogs/delete-spendlogs-month.sh \
  --month 2026-06 \
  --archive backups/spendlogs/LiteLLM_SpendLogs_2026-06_20260701T000000Z.tar.gz.age \
  --age-identity /run/secrets/litellm-spendlogs-age-identity \
  --execute \
  --expect-count 12345
```

- Dry-run reports row count and first/last timestamps.
- With archive proof, dry-run and delete mode require the archive request-ID set to exactly match the current database month; a count-only match is insufficient.
- Delete mode uses a serializable transaction and a writer-blocking table lock,
  rechecks `--expect-count`, retains the UTC predicate on `DELETE`, and requires
  the month to contain zero rows before commit.
- The current UTC month is refused unless `--force-current-month` is supplied.
- If policy intentionally requires deletion without an archive, `--retention-only` is the explicit acknowledgement and still requires `--execute --expect-count N`.

## Operational Rules

- Export before deleting unless the user explicitly confirms retention-only deletion.
- Keep each `.age` archive with its `.age.sha256` sidecar.
- Treat archives as sensitive because they may contain prompts, responses, proxy request data, IP addresses, metadata, and agent/tool identifiers.
- Record dry-run output and use its exact count for `--expect-count`.
- Do not delete an active month unless writes have been stopped and `--force-current-month` is deliberately approved.
- All month boundaries are UTC; do not reinterpret them in the host or operator's local timezone.
- Store only the age identity path in automation; never place private identity
  contents in environment variables or source control.
