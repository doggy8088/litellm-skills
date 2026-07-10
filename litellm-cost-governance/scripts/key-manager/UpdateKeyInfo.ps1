<#
.SYNOPSIS
    根據 userList.csv 中的 key_alias 查詢 API 取得 key_name 和 token，並更新 CSV

.DESCRIPTION
    1. 讀取 userList.csv
    2. 呼叫 /key/list 取得所有 Key Hash
    3. 對每個 Hash 呼叫 /key/info 取得 key_name, key_alias
    4. 將 key_name 和 token 對應回 CSV 並儲存

.EXAMPLE
    .\UpdateKeyInfo.ps1
#>

param(
    [string]$CsvPath = "",
    [string]$OutputPath = "",
    [string]$ApiBaseUrl = "http://localhost:4000",
    [string]$AuthToken = ""
)

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

# ========== 設定區 ==========
$BaseUrl = $ApiBaseUrl.TrimEnd("/")
$AuthToken = Resolve-AuthHeaderValue -TokenFromParam $AuthToken

# 處理路徑
if (-not $CsvPath) {
    $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $CsvPath = Join-Path $ScriptDir "userList.csv"
}
if (-not $OutputPath) {
    $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $OutputPath = Join-Path $ScriptDir "userList_updated.csv"
}

# ========== 讀取 CSV ==========
Write-Host "讀取 CSV: $CsvPath"
$csvData = Import-Csv -Path $CsvPath -Encoding UTF8

Write-Host "CSV 筆數: $($csvData.Count)"

# 建立 key_alias 查找表
$aliasSet = @{}
foreach ($row in $csvData) {
    $aliasSet[$row.key_alias] = $true
}

# ========== 取得所有 Key Hash ==========
Write-Host "`n取得所有 Key Hash..."

$allHashes = @()
$page = 1

do {
    $listUrl = "$BaseUrl/key/list?page=$page"
    try {
        $response = Invoke-RestMethod -Uri $listUrl -Method GET -Headers @{
            "Authorization" = $AuthToken
        }
        
        if ($response.keys) {
            $allHashes += $response.keys
        }
        
        $totalPages = if ($response.total_pages) { $response.total_pages } else { 1 }
        Write-Host "  第 $page 頁，取得 $($response.keys.Count) 個 Hash (共 $totalPages 頁)"
        $page++
    }
    catch {
        Write-Host "取得 Key 列表失敗: $_" -ForegroundColor Red
        break
    }
} while ($page -le $totalPages)

Write-Host "共取得 $($allHashes.Count) 個 Key Hash"

# ========== 查詢每個 Key 的詳細資訊 ==========
Write-Host "`n查詢 Key 詳細資訊..."

# 建立 alias -> info 的對應表
$keyInfoMap = @{}

$count = 0
foreach ($hash in $allHashes) {
    $count++
    $infoUrl = "$BaseUrl/key/info?key=$hash"
    
    try {
        $info = Invoke-RestMethod -Uri $infoUrl -Method GET -Headers @{
            "Authorization" = $AuthToken
        }
        
        # 從回傳中取得 key_alias
        $keyAlias = $null
        $keyName = $null
        
        if ($info.info) {
            $keyAlias = $info.info.key_alias
            $keyName = $info.info.key_name
        }
        elseif ($info.key_alias) {
            $keyAlias = $info.key_alias
            $keyName = $info.key_name
        }
        
        if ($keyAlias -and $aliasSet.ContainsKey($keyAlias)) {
            $keyInfoMap[$keyAlias] = @{
                token    = $hash
                key_name = $keyName
            }
            Write-Host "  [$count/$($allHashes.Count)] 找到目標: $keyAlias -> $keyName"
        }
    }
    catch {
        Write-Host "  [$count/$($allHashes.Count)] 查詢失敗: $hash - $_" -ForegroundColor Yellow
    }
}

Write-Host "`n共找到 $($keyInfoMap.Count) 個目標 Key"

# ========== 更新 CSV 資料 ==========
Write-Host "`n更新 CSV 資料..."

$results = @()
$foundCount = 0
$notFoundCount = 0

foreach ($row in $csvData) {
    $alias = $row.key_alias
    
    $newRow = [PSCustomObject]@{
        user_id   = $row.user_id
        Team      = $row.Team
        key_alias = $row.key_alias
        key_name  = ""
        token     = ""
        models    = $row.models
        key_type  = $row.key_type
        metadata  = $row.metadata
    }
    
    if ($keyInfoMap.ContainsKey($alias)) {
        $newRow.key_name = $keyInfoMap[$alias].key_name
        $newRow.token = $keyInfoMap[$alias].token
        $foundCount++
        Write-Host "  更新: $alias -> $($newRow.key_name)"
    }
    else {
        $notFoundCount++
        Write-Host "  未找到: $alias" -ForegroundColor Yellow
    }
    
    $results += $newRow
}

# ========== 儲存更新後的 CSV ==========
Write-Host "`n儲存結果到: $OutputPath"

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "`n=========================================="
Write-Host "完成！"
Write-Host "  已更新: $foundCount 筆"
Write-Host "  未找到: $notFoundCount 筆"
Write-Host "  輸出檔案: $OutputPath"
Write-Host "=========================================="
