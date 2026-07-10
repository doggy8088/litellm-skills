# Virtual Key Operations Reference

Use this for bulk virtual-key lifecycle operations, model access changes, budget updates, and usage reports.

Prefer the bundled scripts in `scripts/key-manager/` for repeatable CSV-backed workflows. Treat input and output CSV files as secrets.

## CSV Schemas

- `Key_List.csv`: `key_alias`, `new_key`
- `userList.csv`: `user_id`, `Team`, `key_alias`, `models`, `key_type`, `metadata`
- `keyRecreateResults.csv`: `key_alias`, `old_key_hash`, `delete_status`, `new_key`, `create_status`, `response_json`
- `keyRegenerateResults.csv`: `key_alias`, `key_hash`, `new_key`, `key_info_json`, `response_json`, `status`
- `updateBudgetResults.csv`: before/after budget fields and status
- `updateModelsResults.csv`: action, status, changed models, error

All of these can contain secrets or privileged operational data.

## Core Workflows

### Query Usage

A robust usage-query workflow:

- Resolves admin token from parameter, `LITELLM_ADMIN_TOKEN`, or `LITELLM_MASTER_KEY`.
- Reads aliases from `Key_List.csv` or a single `-KeyAlias`.
- Paginates `/key/list`, then calls `/key/info` to map aliases to key hashes.
- Sums `spend` and `model_spend`.
- For a single key, can query daily aggregated activity or spend logs for today's spend and tokens.
- Can export CSV and JSON reports.

### Create From Template

A template-based key-creation workflow:

- Normalizes a username/email into `rg-aoai-<name>`.
- Reads a template key alias and copies its model allowlist.
- Generates a new virtual key.
- Backs up and updates `Key_List.csv`.

Use this pattern when onboarding one user from an existing permissions template.

### Recreate Or Regenerate

- Recreate deletes an existing key by hash, then calls `/key/generate` from a trusted user list.
- Regenerate calls `/key/{hash}/regenerate` for existing aliases.
- A reconciliation step copies successful `new_key` values back into the operational key list.

Prefer `-WhatIf` before destructive or broad operations.

### Update Model Access

A model-access update workflow:

- Adds or removes model names for every key in `Key_List.csv`.
- Handles comma-separated model input and accidental PowerShell-array text.
- Calls `/key/update` with the new model list.
- Can test updated models after the update.
- Selects test endpoints by model family: chat, responses, image, or audio transcription.

### Update Budgets

A budget-update workflow:

- Updates all aliases from `Key_List.csv` or selected `-KeyAlias` values.
- Sends `max_budget`.
- Sends `budget_duration` only when the user supplies it, preserving existing reset windows by default.
- Writes before/after result rows.

## Safety Rules

- Do not print virtual keys, key hashes, or admin tokens in final answers.
- Recommend rotating any key that has been committed, logged, exported, or shared.
- Prefer `-WhatIf`, `--dry-run`, or single-key testing before bulk operations.
- Keep backups of CSVs before writes.
- Treat result CSVs as secrets because response JSON may include generated keys.
