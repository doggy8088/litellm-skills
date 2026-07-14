# Backup And Restore Reference

Use these scripts for logical PostgreSQL backups, Azure Blob retention, and
isolated restore drills. They intentionally do not implement physical base
backups, incremental archives, or WAL replay.

## Security Model

- All scripts set `umask 077`; temporary files and new backup artifacts are
  readable only by their owner by default.
- Published backups are authenticated age ciphertext. Set one explicit public
  recipient through `LITELLM_AGE_RECIPIENT`; keep the private identity only in a
  mode-restricted file referenced by `LITELLM_AGE_IDENTITY_FILE` or
  `--age-identity`.
- `.env`, compose files, LiteLLM configuration, and other deployment files are
  never placed in a backup archive or uploaded by the backup workflow.
- `daily-backup.sh` reads only `POSTGRES_USER` and `POSTGRES_DB` from `.env` so
  it can address the running database. It does not read the Azure SAS from that
  file.
- Supply an Azure container SAS at runtime through
  `AZURE_BACKUP_SAS_URL`. Avoid command-line `--sas` in automation because
  command-line arguments can be visible to other local processes.
- Azure endpoints must use HTTPS. AzCopy console output and job logs are
  disabled, and its temporary job directory is removed after each run, so the
  SAS query is not copied to normal output or persistent AzCopy logs.

## Daily Logical Backup

Run the bundled script from a Linux host with Docker Compose, `zip`, `age`, and
either `sha256sum` or `shasum`:

```bash
LITELLM_AGE_RECIPIENT='<reviewed age public recipient>' \
LITELLM_PROJECT_DIR=/srv/litellm \
  ./scripts/backup-restore/daily-backup.sh
```

The script:

1. Detects `docker-compose` or `docker compose` and locates the `postgres`
   service.
2. Runs `pg_dump -Fc` inside the service container.
3. Creates a plaintext ZIP containing only `database.dump`, `manifest.txt`, and
   `SHA256SUMS` inside a mode-0700 temporary directory.
4. Publishes only `backup_YYYYMMDD_HHMMSS.zip.age` plus the strict ciphertext
   checksum `backup_YYYYMMDD_HHMMSS.zip.age.sha256`, then removes plaintext.

Set `LITELLM_BACKUPS_DIR` to override the local output directory. The backup is
kept locally when `AZURE_BACKUP_SAS_URL` is unset. When the variable is set,
the script invokes `upload-backup.sh` through `bash`, so the helper does not
depend on an executable file mode. It uploads only the ZIP and detached
checksum, then applies the configured retention period:

```bash
AZURE_BACKUP_SAS_URL='<HTTPS container SAS URL>' \
AZURE_BACKUP_RETENTION_DAYS=7 \
LITELLM_AGE_RECIPIENT='<reviewed age public recipient>' \
LITELLM_PROJECT_DIR=/srv/litellm \
  ./scripts/backup-restore/daily-backup.sh
```

Do not put the literal SAS value in cron files or source control. Inject it
from the host's secret manager or protected runtime environment.

## Azure Blob Upload And Retention

`upload-backup.sh` accepts local files only. Remote HTTP/HTTPS source URLs are
rejected; downloading arbitrary content is outside the backup workflow.

```bash
AZURE_BACKUP_SAS_URL='<HTTPS container SAS URL>' \
  bash scripts/backup-restore/upload-backup.sh \
    --file backups/backup_20260712_010000.zip.age \
    --verbose
```

The default blob name is the local filename. `--name` accepts conservative
slash-separated names made from letters, digits, dots, underscores, and
dashes. Existing blobs are not overwritten unless `--force` is explicit.

Retention deletion has two independent safeguards:

- A positive `--delete-older-than-days` value and the separate
  `--execute-retention` confirmation are both required.
- Deletion is non-recursive and restricted to container-root blobs matching
  `backup_*.zip.age` or `backup_*.zip.age.sha256`.

```bash
AZURE_BACKUP_SAS_URL='<HTTPS container SAS URL>' \
  bash scripts/backup-restore/upload-backup.sh \
    --delete-older-than-days 7 \
    --execute-retention \
    --verbose
```

The SAS must include delete permission for retention cleanup. Use a narrowly
scoped, short-lived container SAS and grant only the permissions needed by the
operation.

## Restore Drill

`restore-backup.sh` accepts only logical `.zip.age`, `.dump.age`, and `.sql.age`
inputs accompanied by a strict `<filename>.sha256` ciphertext checksum.
Local restores require Docker but do not require AzCopy:

```bash
bash scripts/backup-restore/restore-backup.sh \
  --source local \
  --file backups/backup_20260712_010000.zip.age \
  --age-identity /run/secrets/litellm-backup-age-identity \
  --verify-only
```

Select the latest standard backup from a specific UTC date with `--date`:

```bash
bash scripts/backup-restore/restore-backup.sh \
  --source local \
  --local-dir backups \
  --date 2026-07-12 \
  --age-identity /run/secrets/litellm-backup-age-identity
```

For Azure, use either an explicit blob name or a date. Explicit downloads keep
the blob's `.zip.age`, `.dump.age`, or `.sql.age` suffix so format detection
remains deterministic:

```bash
AZURE_BACKUP_SAS_URL='<HTTPS container SAS URL>' \
  bash scripts/backup-restore/restore-backup.sh \
    --source azure \
    --blob-name backup_20260712_010000.zip.age \
    --age-identity /run/secrets/litellm-backup-age-identity \
    --verify-only
```

The ciphertext checksum is mandatory and Azure restores download its sidecar
before decrypting. ZIP plaintext must contain exactly one `.dump` or `.sql`
member and one `SHA256SUMS`; its inner checksum is also verified. Plaintext is
kept only below the mode-0700 restore work directory. Configure extraction
ceilings with `LITELLM_RESTORE_MAX_MEMBER_BYTES` and
`LITELLM_RESTORE_MAX_TOTAL_BYTES` when the defaults are unsuitable.

The drill creates a temporary PostgreSQL container with a freshly generated
random password and publishes it only on `127.0.0.1` (port `55432` by default).
It restores the dump, runs a database/table-count query, and removes the
container, Docker volume, download, and temporary AzCopy state on success or
failure. Resources carry a per-run ownership label and cleanup refuses to
delete unlabeled or foreign resources. `--verify-only` retains this lifecycle.

Use `--keep-data` only when a successful drill needs manual inspection. This
explicit option keeps both the container and Docker volume; the script prints
a password-free `docker exec ... psql` inspection command. Remove the retained
resources when finished:

```bash
docker rm -f <container-name>
docker volume rm <volume-name>
```

## Verification Checklist

- Confirm the `.age` ciphertext and detached `.sha256` are non-empty and
  mode-restricted.
- Inspect `manifest.txt`; it must not contain credentials or secret config.
- Require checksum verification before treating an archive as restorable.
- Keep age identities in a protected secret file. Encrypted identities that
  prompt for a passphrase are unsuitable for unattended drills.
- Run a temporary restore, not only an upload-success check.
- Compare expected schema/table or date-window row counts for critical data.
- Confirm no restore container or volume remains unless `--keep-data` was
  explicitly requested.
