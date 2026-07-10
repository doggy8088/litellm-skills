# Backup And Restore Reference

Use this for daily backup, Azure Blob upload, restore drills, and cross-platform upload helpers.

## Daily Backup

Use bundled script `scripts/backup-restore/daily-backup.sh`:

- Resolves project root from `LITELLM_PROJECT_DIR`, or from the expected copied script layout, and reads `.env`.
- Detects `docker-compose` or `docker compose`.
- Reads `POSTGRES_USER` and `POSTGRES_DB` from `.env`, defaulting to `litellm`.
- Requires `zip`.
- Runs `pg_dump -Fc` inside the Postgres container.
- Zips the dump plus available config files such as compose files, `config/litellm_config.yaml`, and `.env`.
- Uploads with bundled `scripts/backup-restore/upload-backup.sh` when executable.
- Deletes Azure backup blobs older than 7 days after a successful upload.

## Azure Blob Upload

Use bundled script `scripts/backup-restore/upload-backup.sh`:

- Uses `azcopy` and a container SAS URL supplied by `--sas` or `AZURE_BACKUP_SAS_URL`.
- Supports local files and remote URLs.
- Can set blob name, content type, force overwrite, and verbose output.
- Skips upload if the blob already exists unless `--force`.
- Adds content disposition for archive/binary files.
- Supports retention cleanup with `--delete-older-than-days`, requiring delete permission in the SAS.

SAS URLs are sensitive. Use `AZURE_BACKUP_SAS_URL` or a runtime `--sas` argument; do not write SAS values into the script.

## PowerShell Upload Helper

Use bundled script `scripts/backup-restore/Upload-AzureBlobWithSas.ps1`:

- Uses HTTP PUT with `x-ms-blob-type: BlockBlob`.
- Supports `ShouldProcess`.
- Downloads remote URLs to a temporary file before upload.
- Uses a Git object hash as the blob name when `-BlobName` is omitted.
- Adds content disposition for archive/binary files.

SAS URLs are sensitive. Pass `-SasUrl` or set `AZURE_BACKUP_SAS_URL`; do not copy SAS values into examples.

## Restore Drill

Use bundled script `scripts/backup-restore/restore-backup.sh`:

- Restores by `--date YYYY-MM-DD`.
- Supports `--source local|azure`, `--file`, `--blob-name`, and `--sas`.
- Uses a temporary Postgres container on port `55432` by default.
- Restores legacy `.zip` archives containing `.dump` or `.sql`.
- Supports full/incremental backup chains with WAL replay when matching archives exist.
- `--verify-only` is equivalent to keeping the temporary data for inspection.
- Logs a temporary connection string with the password redacted.

## Verification Steps

- Confirm archive exists and is non-empty.
- For dumps, run a temporary restore rather than trusting upload success.
- Query `select current_database();` in the restored container.
- Compare expected date/window row counts when restoring spend-log-related data.
- Remove temporary containers/data unless `--keep-data` or `--verify-only` is requested.
