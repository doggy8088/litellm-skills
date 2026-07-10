#!/usr/bin/env pwsh
<#
.SYNOPSIS
    依使用者名稱或信箱建立一把新的 LiteLLM virtual key，並複製指定樣板 key_alias 的模型權限。

.DESCRIPTION
    1. 接受使用者名稱或信箱作為唯一必要輸入
    2. 若輸入為信箱，取 local-part 並轉成 key_alias（預設格式：rg-aoai-<name>）
    3. 從 API 讀取指定樣板 key_alias 的模型清單
    4. 建立新的 Key
    5. 將新 key 寫回 Key_List.csv（存在則更新，不存在則追加）

.PARAMETER UserNameOrEmail
    使用者名稱或信箱。若為信箱，會使用 @ 前面的 local-part。

.PARAMETER TemplateKeyAlias
    要複製模型權限的樣板 key_alias。

.PARAMETER KeyListPath
    Key_List.csv 路徑。預設為腳本目錄下的 Key_List.csv。

.PARAMETER ApiBaseUrl
    LiteLLM API Base URL。預設為 http://localhost:4000。

.PARAMETER AuthToken
    管理權限 token。若未提供，會依序讀取：LITELLM_ADMIN_TOKEN、LITELLM_MASTER_KEY。

.PARAMETER DefaultUserId
    建立新 key 時使用的 user_id；若樣板 key 含有 user_id，會優先沿用樣板值。

.PARAMETER DefaultKeyType
    建立新 key 時使用的 key_type。

.PARAMETER WhatIf
    僅顯示即將執行的內容，不實際建立或寫回 CSV。

.EXAMPLE
    pwsh ./NewKeyFromCopy.ps1 -UserNameOrEmail student1 -TemplateKeyAlias course-template

.EXAMPLE
    pwsh ./NewKeyFromCopy.ps1 -UserNameOrEmail student1@example.com -TemplateKeyAlias course-template
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$UserNameOrEmail,

    [Parameter(Mandatory = $true)]
    [string]$TemplateKeyAlias,

    [Parameter(Mandatory = $false)]
    [string]$KeyListPath = "",

    [Parameter(Mandatory = $false)]
    [string]$ApiBaseUrl = "http://localhost:4000",

    [Parameter(Mandatory = $false)]
    [string]$AuthToken = "",

    [Parameter(Mandatory = $false)]
    [string]$DefaultUserId = "default_user_id",

    [Parameter(Mandatory = $false)]
    [string]$DefaultKeyType = "llm_api",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
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

function Resolve-CanonicalUserName {
    param([string]$Value)

    $normalized = $Value.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "使用者名稱或信箱不可為空"
    }

    if ($normalized -match '@') {
        $normalized = $normalized.Split('@')[0]
    }

    if ($normalized.StartsWith('rg-aoai-')) {
        $normalized = $normalized.Substring('rg-aoai-'.Length)
    }

    $normalized = $normalized -replace '\s+', '.'
    $normalized = $normalized -replace '[^a-z0-9._-]', ''
    $normalized = $normalized.Trim('.-_')

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "無法從輸入值推導出有效的使用者名稱：$Value"
    }

    return $normalized
}

function Normalize-Models {
    param($Models)

    $result = @()
    foreach ($model in @($Models)) {
        if ([string]::IsNullOrWhiteSpace([string]$model)) { continue }
        $cleaned = ([string]$model).Trim()
        $cleaned = $cleaned -replace '^azure-', ''
        if (-not [string]::IsNullOrWhiteSpace($cleaned)) {
            $result += $cleaned
        }
    }

    return @($result | Select-Object -Unique)
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
            $listResponse = Invoke-RestMethod -Method Get -Uri $listUri -Headers $Headers -ContentType 'application/json'
        }
        catch {
            $body = Get-ResponseBody -Exception $_.Exception
            throw "呼叫 /key/list 失敗：$($_.Exception.Message)`n$body"
        }

        if ($listResponse.keys) {
            $allKeyHashes += $listResponse.keys
        }

        $totalPages = if ($listResponse.total_pages) { [int]$listResponse.total_pages } else { 1 }
        $page++
    } while ($page -le $totalPages)

    return $allKeyHashes
}

function Get-KeyInfoByHash {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$KeyHash
    )

    $infoUri = "$BaseUrl/key/info?key=$KeyHash"
    $response = Invoke-RestMethod -Method Get -Uri $infoUri -Headers $Headers -ContentType 'application/json'
    if ($response.info) { return $response.info }
    return $response
}

function Resolve-NewKeyValue {
    param($CreateResponse)

    if ($CreateResponse -and $CreateResponse.PSObject.Properties.Name -contains 'key') {
        return $CreateResponse.key
    }
    if ($CreateResponse -and $CreateResponse.PSObject.Properties.Name -contains 'api_key') {
        return $CreateResponse.api_key
    }
    if ($CreateResponse -and $CreateResponse.PSObject.Properties.Name -contains 'access_key') {
        return $CreateResponse.access_key
    }

    return $null
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($KeyListPath)) {
    $KeyListPath = Join-Path $scriptRoot 'Key_List.csv'
}

if (-not (Test-Path -Path $KeyListPath)) {
    throw "找不到 Key_List.csv：$KeyListPath"
}

$canonicalUserName = Resolve-CanonicalUserName -Value $UserNameOrEmail
$newKeyAlias = "rg-aoai-$canonicalUserName"
$baseUrl = $ApiBaseUrl.TrimEnd('/')
$authHeaderValue = Resolve-AuthHeaderValue -TokenFromParam $AuthToken
$headers = @{ Authorization = $authHeaderValue }

Write-Host '=========================================='
Write-Host ' NewKeyFromCopy'
Write-Host '=========================================='
Write-Host "輸入值           : $UserNameOrEmail"
Write-Host "正規化使用者名稱 : $canonicalUserName"
Write-Host "新 key_alias      : $newKeyAlias"
Write-Host "樣板 key_alias    : $TemplateKeyAlias"
Write-Host "Key_List.csv      : $KeyListPath"
Write-Host "ApiBaseUrl        : $baseUrl"
Write-Host "WhatIf            : $WhatIf"
Write-Host ''

$keyListRows = @(Import-Csv -Path $KeyListPath -Encoding UTF8)
$existingCsvRow = $keyListRows | Where-Object { $_.key_alias -eq $newKeyAlias } | Select-Object -First 1

Write-Host '步驟 1/4: 讀取所有 Key Hash...'
$allKeyHashes = Get-AllKeyHashes -BaseUrl $baseUrl -Headers $headers
Write-Host "  共取得 $($allKeyHashes.Count) 個 hash"
Write-Host ''

Write-Host '步驟 2/4: 讀取樣板 key 與檢查 alias 是否已存在...'
$templateInfo = $null
$existingTargetInfo = $null

foreach ($hash in $allKeyHashes) {
    try {
        $info = Get-KeyInfoByHash -BaseUrl $baseUrl -Headers $headers -KeyHash $hash
    }
    catch {
        continue
    }

    if ($info.key_alias -eq $TemplateKeyAlias) {
        $templateInfo = $info
    }

    if ($info.key_alias -eq $newKeyAlias) {
        $existingTargetInfo = $info
    }

    if ($templateInfo -and $existingTargetInfo) {
        break
    }
}

if (-not $templateInfo) {
    throw "找不到樣板 Key：$TemplateKeyAlias"
}

if ($existingTargetInfo) {
    throw "API 中已存在相同 key_alias：$newKeyAlias，為避免重複建立已停止執行。"
}

$templateModels = Normalize-Models -Models $templateInfo.models
if (-not $templateModels -or $templateModels.Count -eq 0) {
    throw "樣板 Key $TemplateKeyAlias 沒有可複製的模型清單"
}

Write-Host "  樣板模型數量：$($templateModels.Count)"
Write-Host ''

$templateMetadata = @{}
if ($templateInfo.metadata) {
    $templateMetadata = $templateInfo.metadata
}

$userId = if (-not [string]::IsNullOrWhiteSpace([string]$templateInfo.user_id)) { [string]$templateInfo.user_id } else { $DefaultUserId }

$payload = [ordered]@{
    user_id   = $userId
    key_alias = $newKeyAlias
    models    = @($templateModels)
    key_type  = $DefaultKeyType
    metadata  = $templateMetadata
}

Write-Host '步驟 3/4: 建立新 Key...'
if ($WhatIf) {
    Write-Host '  [WhatIf] 不實際建立新 Key'
    Write-Host "  [WhatIf] 將使用 $($templateModels.Count) 個模型建立 $newKeyAlias"
    Write-Host ''
    Write-Host '步驟 4/4: [WhatIf] 不寫回 Key_List.csv'
    Write-Host '完成（WhatIf）。'
    return
}

$jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress
$createUri = "$baseUrl/key/generate"

try {
    $createResponse = Invoke-RestMethod -Method Post -Uri $createUri -Headers $headers -ContentType 'application/json' -Body $jsonBody
}
catch {
    $body = Get-ResponseBody -Exception $_.Exception
    throw "建立新 Key 失敗：$($_.Exception.Message)`n$body"
}

$newKeyValue = Resolve-NewKeyValue -CreateResponse $createResponse
if ([string]::IsNullOrWhiteSpace($newKeyValue)) {
    $responseJson = $createResponse | ConvertTo-Json -Depth 10 -Compress
    throw "API 已回應，但找不到新 key 欄位。回應內容：$responseJson"
}

Write-Host "  建立成功：$newKeyAlias"
Write-Host ''

Write-Host '步驟 4/4: 更新 Key_List.csv...'
$backupPath = $KeyListPath -replace '\.csv$', "_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
Copy-Item -Path $KeyListPath -Destination $backupPath

$resultRows = @()
$updated = $false
foreach ($row in $keyListRows) {
    if ($row.key_alias -eq $newKeyAlias) {
        $row.new_key = $newKeyValue
        $updated = $true
    }

    $resultRows += [PSCustomObject]@{
        key_alias = $row.key_alias
        new_key   = $row.new_key
    }
}

if (-not $updated) {
    $resultRows += [PSCustomObject]@{
        key_alias = $newKeyAlias
        new_key   = $newKeyValue
    }
}

$csvActionLabel = if ($updated) { '更新' } else { '追加' }

$resultRows | Export-Csv -Path $KeyListPath -NoTypeInformation -Encoding UTF8

Write-Host "  Key_List.csv 已$csvActionLabel：$newKeyAlias"
Write-Host ''
Write-Host '=========================================='
Write-Host '完成！'
Write-Host "  新 key_alias : $newKeyAlias"
Write-Host "  模型來源     : $TemplateKeyAlias"
Write-Host "  模型數量     : $($templateModels.Count)"
Write-Host "  Key_List.csv : $KeyListPath"
Write-Host "  備份檔案     : $backupPath"
Write-Host '=========================================='
