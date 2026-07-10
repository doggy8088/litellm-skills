# Secret Inventory And Sanitization

Use this when the task involves sharing, publishing, auditing, or cleaning this repo.

## Sensitive Local Artifacts

LiteLLM operational repositories often accumulate secret-like material in:

- key-list CSVs
- key recreation result CSVs
- key regeneration result CSVs
- PowerShell scripts with hardcoded bearer-token defaults
- Azure Blob upload helper scripts with SAS URLs/signatures
- browser or API captures
- Spend-log archives if generated later

## Recommended Sanitization

- Replace hardcoded admin tokens with empty defaults and environment-variable resolution.
- Replace hardcoded SAS URLs with `AZURE_BACKUP_SAS_URL`.
- Remove committed key CSVs or replace them with small redacted fixtures.
- Remove `__pycache__` and generated result CSVs from version control.
- Add ignore rules for key-list CSVs, result CSVs, browser/API captures, backups, `.env`, and spend-log archives.
- Rotate any credential that has been committed or shared.

## Redaction Rules

Redact:

- values beginning with `sk-`
- `Bearer ...` headers
- key hashes and `new_key` columns
- SAS query strings, especially signature parameters
- database passwords and URLs
- prompt/response text from spend logs
- requester IP addresses and customer/project metadata when not needed

## Final Answer Rule

When reporting analysis, name files and risk categories. Do not print the actual secret values.
