# Key Manager Runbook

Use this for operational key-management workflows.

## Prerequisites

- PowerShell 7 or compatible `pwsh`.
- LiteLLM admin token via `-AuthToken`, `LITELLM_ADMIN_TOKEN`, or `LITELLM_MASTER_KEY`.
- Correct `ApiBaseUrl`.
- `Key_List.csv` and `userList.csv` stored as secrets.
- For executable helpers, use the bundled scripts in the `litellm-cost-governance` skill under `scripts/key-manager/`, or copy that directory into the operational deployment.

## Common Commands

Query one alias:

```powershell
pwsh ./QueryVirtualKeyUsage.ps1 -KeyAlias "rg-aoai-example"
```

Query all aliases:

```powershell
pwsh ./QueryVirtualKeyUsage.ps1 -All -OutputCsv ./keyUsageResults.csv -OutputJson ./keyUsageResults.json
```

Preview key recreation:

```powershell
pwsh ./BatchRecreateKey.ps1 -WhatIf
```

Add model access:

```powershell
pwsh ./UpdateKey_HasModels.ps1 -Models "model-a,model-b" -Action Add -WhatIf
```

Update max budget without changing reset window:

```powershell
pwsh ./UpdateKey_Budget.ps1 -MaxBudget 20 -WhatIf
```

Update max budget and reset window:

```powershell
pwsh ./UpdateKey_Budget.ps1 -MaxBudget 20 -BudgetDuration 30d -WhatIf
```

## Usage WebApp

Use the bundled app in the `litellm-cost-governance` skill at `scripts/key-manager/usage_webapp/app.py`:

- Reads admin token from environment.
- Reads aliases from `Key_List.csv`.
- Keeps privileged calls server-side.
- Serves `/api/virtual-keys` and `/api/usage/{alias}`.
- Does not return admin token or key hash.

Run with:

```bash
uvicorn app:app --host 0.0.0.0 --port 8010
```

## Result Handling

- `keyRecreateResults.csv` and `keyRegenerateResults.csv` can contain new keys and API responses.
- `updateBudgetResults.csv` and `updateModelsResults.csv` document the outcome of bulk changes.
- Back up `Key_List.csv` before writes.
- Never paste result rows containing keys into chat or docs.
