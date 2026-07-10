#!/usr/bin/env pwsh
<#
.SYNOPSIS
    查詢指定 virtual key（key_alias）的 usage（以 spend 與 model_spend 為主）

.DESCRIPTION
    1. 從環境變數載入具有管理權限的 token（優先順序：參數 > LITELLM_ADMIN_TOKEN > LITELLM_MASTER_KEY）
    2. 讀取 Key_List.csv（或指定 CSV）取得 key_alias 清單
    3. 透過 /key/list + /key/info 對照 key_alias 與 key hash
    4. 輸出單一/多筆查詢結果，並提供整體統計摘要

.PARAMETER KeyListPath
    Key_List.csv 路徑。預設為腳本所在目錄的 Key_List.csv

.PARAMETER KeyAlias
    指定單一 key_alias 查詢

.PARAMETER All
    查詢 Key_List.csv 內全部 key_alias

.PARAMETER ApiBaseUrl
    LiteLLM API Base URL。預設: http://localhost:4000

.PARAMETER AuthToken
    管理權限 Token（可省略，改由環境變數提供）

.PARAMETER OutputCsv
    匯出明細 CSV 路徑（可選）

.PARAMETER OutputJson
    匯出完整 JSON 路徑（可選）

.PARAMETER Top
    只輸出前 N 筆（依 SortBy 排序後）

.PARAMETER SortBy
    排序欄位：spend 或 model_spend_total（預設 spend）

.PARAMETER IncludeNotFound
    是否包含 not_found 資料列（預設：$true）

.PARAMETER IncludeTodayTotals
    單一 key 查詢時，是否額外查詢「當日 Total Spend / Total Tokens」（預設：$true）

.EXAMPLE
    # 查詢單一 alias
    pwsh ./QueryVirtualKeyUsage.ps1 -KeyAlias "rg-aoai-jia"

.EXAMPLE
    # 查詢 Key_List.csv 全部 alias
    pwsh ./QueryVirtualKeyUsage.ps1 -All

.EXAMPLE
    # 匯出結果
    pwsh ./QueryVirtualKeyUsage.ps1 -All -OutputCsv ./keyUsageResults.csv -OutputJson ./keyUsageResults.json
#>

[CmdletBinding(DefaultParameterSetName = "Single")]
param(
    [Parameter(Mandatory = $false)]
    [string]$KeyListPath = "",

    [Parameter(ParameterSetName = "Single", Mandatory = $true)]
    [string]$KeyAlias,

    [Parameter(ParameterSetName = "All", Mandatory = $true)]
    [switch]$All,

    [Parameter(Mandatory = $false)]
    [string]$ApiBaseUrl = "http://localhost:4000",

    [Parameter(Mandatory = $false)]
    [string]$AuthToken = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputJson = "",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000000)]
    [int]$Top = 0,

    [Parameter(Mandatory = $false)]
    [ValidateSet("spend", "model_spend_total")]
    [string]$SortBy = "spend",

    [Parameter(Mandatory = $false)]
    [bool]$IncludeNotFound = $true

    ,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeTodayTotals = $true
)

$ErrorActionPreference = "Stop"

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

    throw @"
找不到可用的管理權限 token。

請使用以下其中一種方式提供：
1) 參數：-AuthToken "<token 或 Bearer token>"
2) 環境變數：LITELLM_ADMIN_TOKEN
3) 環境變數：LITELLM_MASTER_KEY
"@
}

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

function To-Decimal {
    param($Value)
    if ($null -eq $Value) { return [decimal]0 }
    try { return [decimal]$Value } catch { return [decimal]0 }
}

function Sum-ModelSpend {
    param($ModelSpend)

    if ($null -eq $ModelSpend) { return [decimal]0 }

    $sum = [decimal]0
    if ($ModelSpend -is [System.Collections.IDictionary]) {
        foreach ($k in $ModelSpend.Keys) {
            $sum += To-Decimal $ModelSpend[$k]
        }
        return $sum
    }

    # PSObject 的屬性型態
    foreach ($p in $ModelSpend.PSObject.Properties) {
        $sum += To-Decimal $p.Value
    }
    return $sum
}

function Get-ModelSpendEntryCount {
    param($ModelSpend)

    if ($null -eq $ModelSpend) { return 0 }

    if ($ModelSpend -is [System.Collections.IDictionary]) {
        return @($ModelSpend.Keys).Count
    }

    return @($ModelSpend.PSObject.Properties).Count
}

function Try-GetValue {
    param(
        [Parameter(Mandatory = $true)]$Obj,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Obj) { return $null }

    if ($Obj -is [System.Collections.IDictionary]) {
        foreach ($n in $Names) {
            if ($Obj.Contains($n)) { return $Obj[$n] }
        }
        return $null
    }

    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($p) { return $p.Value }
    }

    return $null
}

function Get-FirstMeaningfulValue {
    param(
        [Parameter(Mandatory = $true)]$Obj,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($n in $Names) {
        $value = Try-GetValue -Obj $Obj -Names @($n)
        if ($null -eq $value) { continue }
        if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { continue }
        return $value
    }

    return $null
}

function Get-LogSpendValue {
    param($Log)

    return To-Decimal (Get-FirstMeaningfulValue -Obj $Log -Names @("spend", "cost", "response_cost"))
}

function Get-LogTokenValue {
    param($Log)

    $tokenValue = Get-FirstMeaningfulValue -Obj $Log -Names @("total_tokens", "totalTokens")
    if ($null -eq $tokenValue) {
        $usageObj = Try-GetValue -Obj $Log -Names @("usage")
        if ($usageObj) {
            $tokenValue = Get-FirstMeaningfulValue -Obj $usageObj -Names @("total_tokens", "totalTokens")
        }
    }

    if ($null -eq $tokenValue) { return $null }

    try { return [int]$tokenValue } catch { return $null }
}

function Get-LogDateText {
    param($Log)

    $timeRaw = Get-FirstMeaningfulValue -Obj $Log -Names @("date", "startTime", "start_time", "created_at", "timestamp")
    if ([string]::IsNullOrWhiteSpace([string]$timeRaw)) {
        return $null
    }

    try {
        return ([datetime]$timeRaw).ToString("yyyy-MM-dd")
    }
    catch {
        return [string]$timeRaw
    }
}

function Resolve-LogsArray {
    param($Response)

    if ($null -eq $Response) { return @() }
    if ($Response -is [System.Array]) { return @($Response) }

    $fromKnownProps = Try-GetValue -Obj $Response -Names @("spend_logs", "logs", "data", "items")
    if ($fromKnownProps -is [System.Array]) { return @($fromKnownProps) }
    if ($fromKnownProps) { return @($fromKnownProps) }

    return @()
}

function Invoke-GetJson {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    try {
        $response = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ContentType "application/json"
        if ($response -is [string]) {
            $trimmedResponse = $response.Trim()
            if ($trimmedResponse.StartsWith("{") -or $trimmedResponse.StartsWith("[")) {
                return $trimmedResponse | ConvertFrom-Json -AsHashtable
            }
        }

        return $response
    }
    catch {
        return $null
    }
}

function Resolve-AggregatedTimezoneOffset {
    $offsetMinutes = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
    return -([int][math]::Round($offsetMinutes))
}

function Get-AggregatedApiKeyEntry {
    param(
        $Bucket,
        [string]$KeyHash,
        [string]$Alias
    )

    $breakdown = Try-GetValue -Obj $Bucket -Names @("breakdown")
    $apiKeys = Try-GetValue -Obj $breakdown -Names @("api_keys")
    if ($null -eq $apiKeys) { return $null }

    if ($apiKeys -is [System.Collections.IDictionary]) {
        if ($apiKeys.Contains($KeyHash)) {
            return $apiKeys[$KeyHash]
        }

        foreach ($entry in $apiKeys.GetEnumerator()) {
            $metadata = Try-GetValue -Obj $entry.Value -Names @("metadata")
            $aliasFromMeta = Get-FirstMeaningfulValue -Obj $metadata -Names @("key_alias", "user_api_key_alias", "virtual_key_alias")
            if ($aliasFromMeta -eq $Alias) {
                return $entry.Value
            }
        }

        return $null
    }

    $exactProperty = $apiKeys.PSObject.Properties[$KeyHash]
    if ($exactProperty) {
        return $exactProperty.Value
    }

    foreach ($property in $apiKeys.PSObject.Properties) {
        $metadata = Try-GetValue -Obj $property.Value -Names @("metadata")
        $aliasFromMeta = Get-FirstMeaningfulValue -Obj $metadata -Names @("key_alias", "user_api_key_alias", "virtual_key_alias")
        if ($aliasFromMeta -eq $Alias) {
            return $property.Value
        }
    }

    return $null
}

function Get-TodaySpendAndTokensFromAggregated {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$KeyHash,
        [string]$Alias
    )

    $today = (Get-Date).ToString("yyyy-MM-dd")
    $lookbackStart = (Get-Date).Date.AddDays(-7).ToString("yyyy-MM-dd")
    $timezoneOffset = Resolve-AggregatedTimezoneOffset
    $uri = "$BaseUrl/user/daily/activity/aggregated?start_date=$lookbackStart&end_date=$today&timezone=$timezoneOffset"
    $response = Invoke-GetJson -Uri $uri -Headers $Headers
    if ($null -eq $response) { return $null }

    $results = Try-GetValue -Obj $response -Names @("results")
    if (-not ($results -is [System.Array])) {
        return $null
    }

    $bucketMatches = @()
    foreach ($bucket in $results) {
        $bucketDate = Get-FirstMeaningfulValue -Obj $bucket -Names @("date")
        if ([string]::IsNullOrWhiteSpace([string]$bucketDate)) { continue }

        $targetEntry = Get-AggregatedApiKeyEntry -Bucket $bucket -KeyHash $KeyHash -Alias $Alias
        if ($null -ne $targetEntry) {
            $bucketMatches += [PSCustomObject]@{
                date = [string]$bucketDate
                entry = $targetEntry
            }
        }
    }

    if ($bucketMatches.Count -eq 0) {
        return [PSCustomObject]@{
            date = $today
            total_spend = [decimal]0
            total_tokens = 0
            source_logs_count = 0
            status = "no_logs"
            source = $null
            today_logs = @()
        }
    }

    $selectedDate = $today
    $hasTodayMatch = @($bucketMatches | Where-Object { $_.date -eq $today }).Count -gt 0
    if (-not $hasTodayMatch) {
        $selectedDate = @($bucketMatches | Sort-Object -Property date -Descending | Select-Object -First 1)[0].date
    }

    $matchedEntries = @($bucketMatches | Where-Object { $_.date -eq $selectedDate } | ForEach-Object { $_.entry })
    if ($matchedEntries.Count -eq 0) {
        return [PSCustomObject]@{
            date = $today
            total_spend = [decimal]0
            total_tokens = 0
            source_logs_count = 0
            status = "no_logs"
            source = $null
            today_logs = @()
        }
    }

    $totalSpend = [decimal]0
    $totalTokens = [long]0
    $todayLogs = @()

    foreach ($targetEntry in $matchedEntries) {
        $metrics = Try-GetValue -Obj $targetEntry -Names @("metrics")
        $metadata = Try-GetValue -Obj $targetEntry -Names @("metadata")
        $aliasFromMeta = Get-FirstMeaningfulValue -Obj $metadata -Names @("key_alias", "user_api_key_alias", "virtual_key_alias")
        $spend = To-Decimal (Get-FirstMeaningfulValue -Obj $metrics -Names @("spend"))
        $entryTotalTokens = [long]0
        try { $entryTotalTokens = [long](Get-FirstMeaningfulValue -Obj $metrics -Names @("total_tokens", "totalTokens")) } catch { }

        $totalSpend += $spend
        $totalTokens += $entryTotalTokens

        $todayLogs += [PSCustomObject]@{
            date = $selectedDate
            spend = $spend
            total_tokens = $entryTotalTokens
            api_key = $KeyHash
            key_alias = $aliasFromMeta
            source = "daily_activity_aggregated"
        }
    }

    return [PSCustomObject]@{
        date = $selectedDate
        total_spend = $totalSpend
        total_tokens = $totalTokens
        source_logs_count = $matchedEntries.Count
        status = if ($selectedDate -eq $today) { "ok" } else { "latest_available" }
        source = "daily_activity_aggregated"
        today_logs = $todayLogs
    }
}

function Get-TodaySpendAndTokensFromSpendLogs {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$KeyHash,
        [string]$Alias
    )

    $today = (Get-Date).ToString("yyyy-MM-dd")

    $candidateUris = @(
        "$BaseUrl/spend/logs?api_key=$KeyHash&start_date=$today&end_date=$today",
        "$BaseUrl/global/spend/logs?api_key=$KeyHash&start_date=$today&end_date=$today",
        "$BaseUrl/spend/logs?start_date=$today&end_date=$today",
        "$BaseUrl/global/spend/logs?start_date=$today&end_date=$today"
    )

    $logs = @()
    foreach ($u in $candidateUris) {
        $resp = Invoke-GetJson -Uri $u -Headers $Headers
        if ($null -eq $resp) { continue }
        $arr = Resolve-LogsArray -Response $resp
        if ($arr.Count -gt 0) {
            $logs = $arr
            break
        }
    }

    if ($logs.Count -eq 0) {
        return [PSCustomObject]@{
            date = $today
            total_spend = [decimal]0
            total_tokens = 0
            source_logs_count = 0
            status = "no_logs"
            source = $null
            today_logs = @()
        }
    }

    $todayDate = (Get-Date).Date
    $filtered = @()

    foreach ($l in $logs) {
        $apiKey = Try-GetValue -Obj $l -Names @("api_key", "user_api_key")
        $metadata = Try-GetValue -Obj $l -Names @("metadata")
        $aliasFromMeta = $null
        if ($metadata) {
            $aliasFromMeta = Get-FirstMeaningfulValue -Obj $metadata -Names @("user_api_key_alias", "key_alias", "virtual_key_alias")
        }

        $timeRaw = Get-FirstMeaningfulValue -Obj $l -Names @("date", "startTime", "start_time", "created_at", "timestamp")
        $isToday = $true
        if (-not [string]::IsNullOrWhiteSpace([string]$timeRaw)) {
            try {
                $dt = [datetime]$timeRaw
                $isToday = ($dt.Date -eq $todayDate)
            }
            catch {
                $isToday = $true
            }
        }

        $isTargetKey = ($apiKey -eq $KeyHash) -or ($aliasFromMeta -eq $Alias)
        if ($isTargetKey -and $isToday) {
            $filtered += $l
        }
    }

    if ($filtered.Count -eq 0) {
        return [PSCustomObject]@{
            date = $today
            total_spend = [decimal]0
            total_tokens = 0
            source_logs_count = 0
            status = "no_logs"
            source = $null
            today_logs = @()
        }
    }

    $totalSpend = [decimal]0
    $totalTokens = 0
    $hasTokenValue = $false
    $todayLogs = @()

    foreach ($l in $filtered) {
        $logSpend = Get-LogSpendValue -Log $l
        $logTokens = Get-LogTokenValue -Log $l
        $apiKey = Try-GetValue -Obj $l -Names @("api_key", "user_api_key")
        $metadata = Try-GetValue -Obj $l -Names @("metadata")
        $aliasFromMeta = $null
        if ($metadata) {
            $aliasFromMeta = Get-FirstMeaningfulValue -Obj $metadata -Names @("user_api_key_alias", "key_alias", "virtual_key_alias")
        }

        $logDateText = Get-LogDateText -Log $l

        $totalSpend += $logSpend
        if ($null -ne $logTokens) {
            $hasTokenValue = $true
            $totalTokens += $logTokens
        }

        $todayLogs += [PSCustomObject]@{
            date = $logDateText
            spend = $logSpend
            total_tokens = $logTokens
            api_key = $apiKey
            key_alias = $aliasFromMeta
            source = if ($null -ne $logDateText -and $logDateText -match '^\d{4}-\d{2}-\d{2}$') { "daily_aggregate" } else { "request_log" }
        }
    }

    $uniqueSources = @($todayLogs | ForEach-Object { $_.source } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $source = if ($uniqueSources.Count -eq 1) {
        $uniqueSources[0]
    }
    elseif ($uniqueSources.Count -gt 1) {
        "mixed"
    }
    else {
        $null
    }

    return [PSCustomObject]@{
        date = $today
        total_spend = $totalSpend
        total_tokens = if ($hasTokenValue) { $totalTokens } else { $null }
        source_logs_count = $filtered.Count
        status = "ok"
        source = $source
        today_logs = $todayLogs
    }
}

function Get-TodaySpendAndTokens {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$KeyHash,
        [string]$Alias
    )

    $aggregatedResult = Get-TodaySpendAndTokensFromAggregated -BaseUrl $BaseUrl -Headers $Headers -KeyHash $KeyHash -Alias $Alias
    if ($null -ne $aggregatedResult) {
        return $aggregatedResult
    }

    return Get-TodaySpendAndTokensFromSpendLogs -BaseUrl $BaseUrl -Headers $Headers -KeyHash $KeyHash -Alias $Alias
}

function Get-SpendAnalysis {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$KeyHash,
        [string]$Alias,
        [decimal]$KeyInfoSpend
    )

    $candidateUris = @(
        "$BaseUrl/global/spend/logs?api_key=$KeyHash",
        "$BaseUrl/spend/logs?api_key=$KeyHash"
    )

    $logs = @()
    $source = $null
    foreach ($uri in $candidateUris) {
        $response = Invoke-GetJson -Uri $uri -Headers $Headers
        if ($null -eq $response) { continue }

        $resolvedLogs = Resolve-LogsArray -Response $response
        if ($resolvedLogs.Count -gt 0) {
            $logs = $resolvedLogs
            $source = if ($uri -match '/global/spend/logs') { 'global_spend_logs' } else { 'spend_logs' }
            break
        }
    }

    if ($logs.Count -eq 0) {
        return [PSCustomObject]@{
            key_info_spend = $KeyInfoSpend
            reference_spend = $null
            absolute_delta = $null
            relative_delta = $null
            coverage_count = 0
            source = $null
            status = 'unavailable'
        }
    }

    $filteredLogs = @()
    foreach ($log in $logs) {
        $apiKey = Try-GetValue -Obj $log -Names @('api_key', 'user_api_key')
        $metadata = Try-GetValue -Obj $log -Names @('metadata')
        $aliasFromMeta = $null
        if ($metadata) {
            $aliasFromMeta = Get-FirstMeaningfulValue -Obj $metadata -Names @('user_api_key_alias', 'key_alias', 'virtual_key_alias')
        }

        if (($apiKey -eq $KeyHash) -or ($aliasFromMeta -eq $Alias)) {
            $filteredLogs += $log
        }
    }

    if ($filteredLogs.Count -eq 0) {
        return [PSCustomObject]@{
            key_info_spend = $KeyInfoSpend
            reference_spend = $null
            absolute_delta = $null
            relative_delta = $null
            coverage_count = 0
            source = $source
            status = 'unavailable'
        }
    }

    $referenceSpend = [decimal]0
    $coverageKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($log in $filteredLogs) {
        $referenceSpend += Get-LogSpendValue -Log $log
        $logDateText = Get-LogDateText -Log $log
        if (-not [string]::IsNullOrWhiteSpace($logDateText)) {
            [void]$coverageKeys.Add($logDateText)
        }
    }

    $absoluteDelta = $referenceSpend - $KeyInfoSpend
    if ($absoluteDelta -lt 0) {
        $absoluteDelta = -1 * $absoluteDelta
    }

    $relativeDelta = $null
    if ($referenceSpend -gt 0) {
        $relativeDelta = [double]($absoluteDelta / $referenceSpend)
    }
    elseif ($KeyInfoSpend -gt 0) {
        $relativeDelta = 1.0
    }
    else {
        $relativeDelta = 0.0
    }

    $status = 'ok'
    if ($referenceSpend -gt 0 -and $KeyInfoSpend -eq 0) {
        $status = 'mismatch'
    }
    elseif ($absoluteDelta -ge [decimal]1 -and $relativeDelta -ge 0.1) {
        $status = 'mismatch'
    }

    return [PSCustomObject]@{
        key_info_spend = $KeyInfoSpend
        reference_spend = $referenceSpend
        absolute_delta = $absoluteDelta
        relative_delta = $relativeDelta
        coverage_count = $coverageKeys.Count
        source = $source
        status = $status
    }
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($KeyListPath)) {
    $KeyListPath = Join-Path $scriptRoot "Key_List.csv"
}

if (-not (Test-Path -Path $KeyListPath)) {
    throw "找不到 Key_List.csv：$KeyListPath"
}

$authHeaderValue = Resolve-AuthHeaderValue -TokenFromParam $AuthToken
$headers = @{ "Authorization" = $authHeaderValue }
$baseUrl = $ApiBaseUrl.TrimEnd("/")

Write-Host "=========================================="
Write-Host " QueryVirtualKeyUsage"
Write-Host "=========================================="
Write-Host "KeyListPath: $KeyListPath"
Write-Host "ApiBaseUrl : $baseUrl"
Write-Host "SortBy     : $SortBy"
Write-Host "Top        : $Top"
Write-Host "IncludeNF  : $IncludeNotFound"
Write-Host "TodayTotal : $IncludeTodayTotals"
Write-Host ""

# 讀取 alias 清單
$csvRows = Import-Csv -Path $KeyListPath -Encoding UTF8
if (-not $csvRows -or $csvRows.Count -eq 0) {
    throw "Key_List.csv 無資料：$KeyListPath"
}

$targetAliases = @()
if ($All) {
    $targetAliases = @(
        $csvRows |
            ForEach-Object { $_.key_alias } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}
else {
    $targetAliases = @($KeyAlias)
}

if ($targetAliases.Count -eq 0) {
    throw "沒有可查詢的 key_alias"
}

Write-Host "目標 key_alias 數量: $($targetAliases.Count)"
Write-Host ""

# 1) 取得所有 key hash（分頁）
Write-Host "步驟 1/3: 讀取 /key/list ..."
$allKeyHashes = @()
$page = 1
do {
    $listUri = "$baseUrl/key/list?page=$page"
    try {
        $listResponse = Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers -ContentType "application/json"
    }
    catch {
        $body = Get-ResponseBody -Exception $_.Exception
        throw "呼叫 /key/list 失敗：$($_.Exception.Message)`n$body"
    }

    if ($listResponse.keys) {
        $allKeyHashes += $listResponse.keys
    }

    $totalPages = if ($listResponse.total_pages) { [int]$listResponse.total_pages } else { 1 }
    Write-Host "  第 $page/$totalPages 頁，取得 $($listResponse.keys.Count) 個 hash"
    $page++
} while ($page -le $totalPages)

Write-Host "  共取得 hash 數量: $($allKeyHashes.Count)"
Write-Host ""

# 2) 讀取 /key/info 建立 alias 對照
Write-Host "步驟 2/3: 對照 key_alias -> key hash / info ..."

$targetSet = @{}
foreach ($a in $targetAliases) { $targetSet[$a] = $true }

$aliasInfoMap = @{}
$processed = 0
foreach ($hash in $allKeyHashes) {
    $processed++
    $infoUri = "$baseUrl/key/info?key=$hash"
    try {
        $infoResponse = Invoke-RestMethod -Method Get -Uri $infoUri -Headers $headers -ContentType "application/json"
    }
    catch {
        continue
    }

    $info = $null
    if ($infoResponse.info) { $info = $infoResponse.info }
    else { $info = $infoResponse }

    $alias = $info.key_alias
    if (-not [string]::IsNullOrWhiteSpace($alias) -and $targetSet.ContainsKey($alias)) {
        $aliasInfoMap[$alias] = @{
            hash = $hash
            info = $info
        }
    }
}

Write-Host "  對照成功: $($aliasInfoMap.Count) / $($targetAliases.Count)"
Write-Host ""

# 3) 產生結果與統計
Write-Host "步驟 3/3: 產生 usage 統計 ..."

$resultRows = @()
$notFound = @()

foreach ($alias in $targetAliases) {
    if (-not $aliasInfoMap.ContainsKey($alias)) {
        $notFound += $alias
        $resultRows += [PSCustomObject]@{
            key_alias          = $alias
            key_hash           = $null
            key_name           = $null
            spend              = [decimal]0
            model_spend_total  = [decimal]0
            model_count        = 0
            updated_at         = $null
            status             = "not_found"
        }
        continue
    }

    $row = $aliasInfoMap[$alias]
    $info = $row.info
    $spend = To-Decimal $info.spend
    $modelSpendTotal = Sum-ModelSpend $info.model_spend
    $modelSpendEntryCount = Get-ModelSpendEntryCount $info.model_spend

    $modelCount = 0
    if ($info.models) {
        $modelCount = @($info.models).Count
    }

    $resultRows += [PSCustomObject]@{
        key_alias          = $alias
        key_hash           = $row.hash
        key_name           = $info.key_name
        spend              = $spend
        model_spend_total  = $modelSpendTotal
        has_model_spend_breakdown = ($modelSpendEntryCount -gt 0)
        model_count        = $modelCount
        updated_at         = $info.updated_at
        status             = "ok"
    }
}

$okRows = @($resultRows | Where-Object { $_.status -eq "ok" })
$summary = [PSCustomObject]@{
    total_aliases        = $targetAliases.Count
    found_aliases        = $okRows.Count
    not_found_aliases    = $notFound.Count
    total_spend          = (($okRows | Measure-Object -Property spend -Sum).Sum)
    total_model_spend    = (($okRows | Measure-Object -Property model_spend_total -Sum).Sum)
}

$resultRowsFiltered = if ($IncludeNotFound) {
    @($resultRows)
}
else {
    @($resultRows | Where-Object { $_.status -ne "not_found" })
}

$sortedRows = @($resultRowsFiltered | Sort-Object -Property $SortBy -Descending)
if ($Top -gt 0) {
    $sortedRows = @($sortedRows | Select-Object -First $Top)
}

Write-Host ""
Write-Host "========== 查詢摘要 =========="
Write-Host "  目標 key_alias 數量 : $($summary.total_aliases)"
Write-Host "  成功查詢數量       : $($summary.found_aliases)"
Write-Host "  未找到數量         : $($summary.not_found_aliases)"
Write-Host "  總 spend           : $($summary.total_spend)"
Write-Host "  總 model_spend     : $($summary.total_model_spend)"
Write-Host "=============================="
Write-Host ""

$sortedRows |
    Select-Object key_alias, spend, model_spend_total, model_count, status |
    Format-Table -AutoSize |
    Out-String |
    Write-Output

if (-not [string]::IsNullOrWhiteSpace($OutputCsv)) {
    $sortedRows | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "已輸出 CSV：$OutputCsv"
}

if (-not [string]::IsNullOrWhiteSpace($OutputJson)) {
    $todayTotals = $null
    $spendAnalysis = $null
    if ((-not $All) -and $IncludeTodayTotals -and $targetAliases.Count -eq 1) {
        $singleAlias = $targetAliases[0]
        if ($aliasInfoMap.ContainsKey($singleAlias)) {
            $todayTotals = Get-TodaySpendAndTokens -BaseUrl $baseUrl -Headers $headers -KeyHash $aliasInfoMap[$singleAlias].hash -Alias $singleAlias
            $spendAnalysis = Get-SpendAnalysis -BaseUrl $baseUrl -Headers $headers -KeyHash $aliasInfoMap[$singleAlias].hash -Alias $singleAlias -KeyInfoSpend (To-Decimal $aliasInfoMap[$singleAlias].info.spend)
        }
    }

    $payload = [PSCustomObject]@{
        summary = $summary
        sort_by = $SortBy
        top = $Top
        include_not_found = $IncludeNotFound
        results = $sortedRows
        not_found_aliases = $notFound
        spend_analysis = $spendAnalysis
        today_totals = $todayTotals
        today_logs = if ($todayTotals) { $todayTotals.today_logs } else { $null }
        generated_at = (Get-Date).ToString("o")
    }
    $payload | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputJson -Encoding utf8
    Write-Host "已輸出 JSON：$OutputJson"
}

if ((-not $All) -and $IncludeTodayTotals -and $targetAliases.Count -eq 1) {
    $singleAlias = $targetAliases[0]
    if ($aliasInfoMap.ContainsKey($singleAlias)) {
        $daily = Get-TodaySpendAndTokens -BaseUrl $baseUrl -Headers $headers -KeyHash $aliasInfoMap[$singleAlias].hash -Alias $singleAlias
        Write-Host ""
        Write-Host "====== 單一 Key 當日統計 ======"
        Write-Host "  key_alias     : $singleAlias"
        Write-Host "  date          : $($daily.date)"
        Write-Host "  total_spend   : $($daily.total_spend)"
        Write-Host "  total_tokens  : $($daily.total_tokens)"
        Write-Host "  logs_count    : $($daily.source_logs_count)"
        Write-Host "  status        : $($daily.status)"
        Write-Host "=============================="
    }
    else {
        Write-Host ""
        Write-Host "單一 Key 當日統計：找不到對應 key_alias，無法計算。"
    }
}

Write-Host "完成。"
