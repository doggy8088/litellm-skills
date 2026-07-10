#!/usr/bin/env pwsh
<#
.SYNOPSIS
    批次設定 LiteLLM Virtual Keys 的 Max Budget（USD），並可選擇設定 Reset Budget 週期。

.DESCRIPTION
    1. 若未指定 KeyAlias，預設讀取 Key_List.csv 中所有 key_alias 作為目標
    2. 若有指定 KeyAlias，僅更新指定的 key_alias
    3. 呼叫 /key/list + /key/info 取得每把 Key 的 hash 與目前 budget 設定
    4. 呼叫 /key/update 更新 max_budget
    5. 只有在使用者有指定 BudgetDuration 時，才會把 budget_duration 傳入 API payload

.PARAMETER MaxBudget
    要設定的 Max Budget（USD）。會以數字格式傳到 API 的 max_budget 欄位。

.PARAMETER BudgetDuration
    Reset Budget 週期（budget_duration）。可選值為 24h、7d、30d。
    若未指定，腳本不會把 budget_duration 傳入 API。

.PARAMETER KeyAlias
    要更新的目標 key_alias，可傳入單一值、多個值，或逗號分隔字串。
    若未指定，預設更新 Key_List.csv 中全部 Virtual Keys。

.PARAMETER KeyListPath
    Key_List.csv 路徑。只有在未指定 KeyAlias 時才會用來取得目標清單。

.PARAMETER ApiBaseUrl
    LiteLLM API Base URL。

.PARAMETER AuthToken
    管理員 Authorization Token。

.PARAMETER ResultPath
    更新結果匯出 CSV 路徑。

.PARAMETER WhatIf
    僅顯示即將更新的內容，不實際送出 /key/update。

.EXAMPLE
    pwsh ./UpdateKey_Budget.ps1 -MaxBudget 20

.EXAMPLE
    pwsh ./UpdateKey_Budget.ps1 -MaxBudget 20 -BudgetDuration 30d

.EXAMPLE
    pwsh ./UpdateKey_Budget.ps1 -KeyAlias "rg-aoai-jia" -MaxBudget 15 -BudgetDuration 7d

.EXAMPLE
    pwsh ./UpdateKey_Budget.ps1 -KeyAlias "rg-aoai-jia,rg-aoai-lulu" -MaxBudget 10 -WhatIf
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [double]$MaxBudget,

    [Parameter(Mandatory = $false)]
    [ValidateSet("24h", "7d", "30d")]
    [string]$BudgetDuration,

    [Parameter(Mandatory = $false)]
    [string[]]$KeyAlias,

    [Parameter(Mandatory = $false)]
    [string]$KeyListPath = "",

    [Parameter(Mandatory = $false)]
    [string]$ApiBaseUrl = "http://localhost:4000",

    [Parameter(Mandatory = $false)]
    [string]$AuthToken = "",

    [Parameter(Mandatory = $false)]
    [string]$ResultPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

function Get-ResponseBody {
    param([System.Exception]$Exception)

    try {
        $response = $Exception.Response
        if (-not $response) { return $null }
        $stream = $response.GetResponseStream()
        if (-not $stream) { return $null }
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    }
    catch {
        return $null
    }
}

function Normalize-KeyAliasInput {
    param([string[]]$Values)

    $normalized = @()

    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        $parts = $value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $normalized += $parts
    }

    return @($normalized | Select-Object -Unique)
}

function Resolve-AuthHeaderValue {
    param([string]$TokenFromParam)

    if (-not [string]::IsNullOrWhiteSpace($TokenFromParam)) {
        if ($TokenFromParam -match '^Bearer\s+') { return $TokenFromParam }
        return "Bearer $TokenFromParam"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LITELLM_ADMIN_TOKEN)) {
        if ($env:LITELLM_ADMIN_TOKEN -match '^Bearer\s+') { return $env:LITELLM_ADMIN_TOKEN }
        return "Bearer $($env:LITELLM_ADMIN_TOKEN)"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LITELLM_MASTER_KEY)) {
        if ($env:LITELLM_MASTER_KEY -match '^Bearer\s+') { return $env:LITELLM_MASTER_KEY }
        return "Bearer $($env:LITELLM_MASTER_KEY)"
    }
    throw "Provide -AuthToken or set LITELLM_ADMIN_TOKEN / LITELLM_MASTER_KEY."
}

function Get-AllKeyHashes {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers
    )

    $allKeyHashes = @()
    $page = 1

    do {
        $listUri = "$BaseUrl/key/list?page=$page"
        try {
            $listResponse = Invoke-RestMethod -Method Get -Uri $listUri -Headers $Headers -ContentType "application/json"
        }
        catch {
            $body = Get-ResponseBody -Exception $_.Exception
            throw "呼叫 /key/list 失敗：$($_.Exception.Message)`n$body"
        }

        if ($listResponse.keys) {
            $allKeyHashes += $listResponse.keys
        }

        $totalPages = if ($listResponse.total_pages) { [int]$listResponse.total_pages } else { 1 }
        Write-Host "  第 $page/$totalPages 頁，取得 $($listResponse.keys.Count) 個 Hash"
        $page++
    } while ($page -le $totalPages)

    return $allKeyHashes
}

function New-ResultRow {
    param(
        [string]$KeyAlias,
        [string]$Status,
        $MaxBudgetBefore,
        $MaxBudgetAfter,
        $RequestedMaxBudget,
        $BudgetDurationBefore,
        $BudgetDurationAfter,
        $RequestedBudgetDuration,
        [string]$Error
    )

    return [PSCustomObject]@{
        key_alias                  = $KeyAlias
        status                     = $Status
        max_budget_before          = $MaxBudgetBefore
        max_budget_after           = $MaxBudgetAfter
        requested_max_budget       = $RequestedMaxBudget
        budget_duration_before     = $BudgetDurationBefore
        budget_duration_after      = $BudgetDurationAfter
        requested_budget_duration  = $RequestedBudgetDuration
        error                      = $Error
    }
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($KeyListPath)) {
    $KeyListPath = Join-Path $scriptRoot "Key_List.csv"
}
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path $scriptRoot "updateBudgetResults.csv"
}

$targetAliases = Normalize-KeyAliasInput -Values $KeyAlias

if ($targetAliases.Count -eq 0) {
    if (-not (Test-Path -Path $KeyListPath)) {
        throw "未指定 -KeyAlias，且找不到 Key_List.csv：$KeyListPath"
    }

    $keyListRows = Import-Csv -Path $KeyListPath -Encoding UTF8
    $targetAliases = @(
        $keyListRows |
        ForEach-Object { $_.key_alias } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
}

if ($targetAliases.Count -eq 0) {
    throw "找不到任何可更新的 key_alias"
}

$baseUrl = $ApiBaseUrl.TrimEnd("/")
$adminHeaders = @{ "Authorization" = (Resolve-AuthHeaderValue -TokenFromParam $AuthToken) }
$requestedBudgetDuration = if ($PSBoundParameters.ContainsKey('BudgetDuration')) { $BudgetDuration } else { $null }
$targetAliasSet = @{}
foreach ($alias in $targetAliases) {
    $targetAliasSet[$alias] = $true
}

$budgetDurationLabel = if ($PSBoundParameters.ContainsKey('BudgetDuration')) { $BudgetDuration } else { '(不傳送，保留 API 現況)' }

Write-Host "=========================================="
Write-Host " UpdateKey_Budget - 批次設定 Budget"
Write-Host "=========================================="
Write-Host "目標 Key 數量     : $($targetAliases.Count)"
Write-Host "Max Budget (USD): $MaxBudget"
Write-Host "Reset Budget     : $budgetDurationLabel"
Write-Host "WhatIf           : $WhatIf"
Write-Host "結果檔案         : $ResultPath"
Write-Host ""

Write-Host "步驟 1/3: 取得所有 Key Hash..."
$allKeyHashes = Get-AllKeyHashes -BaseUrl $baseUrl -Headers $adminHeaders
Write-Host "  共取得 $($allKeyHashes.Count) 個 Key Hash"
Write-Host ""

Write-Host "步驟 2/3: 篩選目標 Key 並讀取目前 Budget 設定..."
$aliasInfoMap = @{}
$count = 0

foreach ($hash in $allKeyHashes) {
    $count++
    $infoUri = "$baseUrl/key/info?key=$hash"

    try {
        $infoResponse = Invoke-RestMethod -Method Get -Uri $infoUri -Headers $adminHeaders -ContentType "application/json"
    }
    catch {
        continue
    }

    $keyInfo = if ($infoResponse.info) { $infoResponse.info } else { $infoResponse }
    $alias = $keyInfo.key_alias

    if ($alias -and $targetAliasSet.ContainsKey($alias)) {
        $aliasInfoMap[$alias] = @{
            hash                   = $hash
            currentMaxBudget       = $keyInfo.max_budget
            currentBudgetDuration  = $keyInfo.budget_duration
        }
        Write-Host "  [$count/$($allKeyHashes.Count)] 找到目標: $alias"
    }
}

Write-Host "  共找到 $($aliasInfoMap.Count) / $($targetAliases.Count) 個目標 Key"
Write-Host ""

Write-Host "步驟 3/3: 更新 Budget 設定..."
$results = @()
$successCount = 0
$failCount = 0
$notFoundCount = 0

foreach ($alias in $targetAliases) {
    if (-not $aliasInfoMap.ContainsKey($alias)) {
        Write-Host "  [略過] $alias - 在 API 中找不到對應的 Key" -ForegroundColor Yellow
        $notFoundCount++
        $results += New-ResultRow -KeyAlias $alias -Status "not_found" -MaxBudgetBefore $null -MaxBudgetAfter $null -RequestedMaxBudget $MaxBudget -BudgetDurationBefore $null -BudgetDurationAfter $null -RequestedBudgetDuration $requestedBudgetDuration -Error "在 API 中找不到"
        continue
    }

    $info = $aliasInfoMap[$alias]
    $payload = [ordered]@{
        key        = $info.hash
        max_budget = $MaxBudget
    }

    if ($PSBoundParameters.ContainsKey('BudgetDuration')) {
        $payload['budget_duration'] = $BudgetDuration
    }

    if ($WhatIf) {
        $durationPreview = if ($PSBoundParameters.ContainsKey('BudgetDuration')) { $BudgetDuration } else { '(不傳送)' }
        Write-Host "  [WhatIf] $alias - max_budget: $($info.currentMaxBudget) -> $MaxBudget ; budget_duration: $($info.currentBudgetDuration) -> $durationPreview" -ForegroundColor Magenta
        $results += New-ResultRow -KeyAlias $alias -Status "whatif" -MaxBudgetBefore $info.currentMaxBudget -MaxBudgetAfter $info.currentMaxBudget -RequestedMaxBudget $MaxBudget -BudgetDurationBefore $info.currentBudgetDuration -BudgetDurationAfter $info.currentBudgetDuration -RequestedBudgetDuration $requestedBudgetDuration -Error ""
        continue
    }

    $updateUri = "$baseUrl/key/update"
    $updatePayload = $payload | ConvertTo-Json -Depth 10 -Compress

    try {
        $null = Invoke-RestMethod -Method Post -Uri $updateUri -Headers $adminHeaders -ContentType "application/json" -Body $updatePayload
        Write-Host "  [成功] $alias - 已設定 max_budget=$MaxBudget" -ForegroundColor Green
        $successCount++
        $effectiveBudgetDurationAfter = if ($PSBoundParameters.ContainsKey('BudgetDuration')) { $BudgetDuration } else { $info.currentBudgetDuration }
        $results += New-ResultRow -KeyAlias $alias -Status "updated" -MaxBudgetBefore $info.currentMaxBudget -MaxBudgetAfter $MaxBudget -RequestedMaxBudget $MaxBudget -BudgetDurationBefore $info.currentBudgetDuration -BudgetDurationAfter $effectiveBudgetDurationAfter -RequestedBudgetDuration $requestedBudgetDuration -Error ""
    }
    catch {
        $body = Get-ResponseBody -Exception $_.Exception
        Write-Host "  [失敗] $alias - $($_.Exception.Message)" -ForegroundColor Red
        if ($body) {
            Write-Host "         $body" -ForegroundColor Red
        }
        $failCount++
        $results += New-ResultRow -KeyAlias $alias -Status "update_failed" -MaxBudgetBefore $info.currentMaxBudget -MaxBudgetAfter $info.currentMaxBudget -RequestedMaxBudget $MaxBudget -BudgetDurationBefore $info.currentBudgetDuration -BudgetDurationAfter $info.currentBudgetDuration -RequestedBudgetDuration $requestedBudgetDuration -Error $(if ($body) { $body } else { $_.Exception.Message })
    }
}

$results | Export-Csv -Path $ResultPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "=========================================="
Write-Host " 完成！"
Write-Host "=========================================="
Write-Host "  成功更新: $successCount 筆"
Write-Host "  更新失敗: $failCount 筆"
Write-Host "  找不到 Key: $notFoundCount 筆"
Write-Host "  結果檔案: $ResultPath"
Write-Host "=========================================="
