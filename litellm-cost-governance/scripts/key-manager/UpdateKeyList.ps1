<#
.SYNOPSIS
    讀取 keyRecreateResults.csv 並將 new_key 更新至 Key_List.csv

.DESCRIPTION
    1. 讀取 keyRecreateResults.csv 取得 key_alias 與 new_key 的對應
    2. 讀取 Key_List.csv
    3. 根據 key_alias 更新 new_key 欄位
    4. 儲存更新後的 Key_List.csv

.EXAMPLE
    .\UpdateKeyList.ps1
    .\UpdateKeyList.ps1 -RecreateResultsPath ".\keyRecreateResults.csv" -KeyListPath ".\Key_List.csv"
#>

param(
    [string]$RecreateResultsPath = "",
    [string]$KeyListPath = "",
    [switch]$Backup = $true
)

# ========== 設定路徑 ==========
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

if (-not $RecreateResultsPath) {
    $RecreateResultsPath = Join-Path $ScriptDir "keyRecreateResults.csv"
}
if (-not $KeyListPath) {
    $KeyListPath = Join-Path $ScriptDir "Key_List.csv"
}

# ========== 檢查檔案是否存在 ==========
if (-not (Test-Path $RecreateResultsPath)) {
    Write-Host "錯誤: 找不到 keyRecreateResults.csv: $RecreateResultsPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $KeyListPath)) {
    Write-Host "錯誤: 找不到 Key_List.csv: $KeyListPath" -ForegroundColor Red
    exit 1
}

# ========== 讀取 keyRecreateResults.csv ==========
Write-Host "讀取 keyRecreateResults.csv: $RecreateResultsPath"
$recreateData = Import-Csv -Path $RecreateResultsPath -Encoding UTF8

Write-Host "keyRecreateResults.csv 筆數: $($recreateData.Count)"

# 建立 key_alias -> new_key 的對應表 (只處理 create_status 為 ok 的)
$newKeyMap = @{}
foreach ($row in $recreateData) {
    if ($row.create_status -eq "ok" -and $row.new_key) {
        $newKeyMap[$row.key_alias] = $row.new_key
    }
}

Write-Host "成功建立的新 Key 數量: $($newKeyMap.Count)"

# ========== 讀取 Key_List.csv ==========
Write-Host "`n讀取 Key_List.csv: $KeyListPath"
$keyListData = Import-Csv -Path $KeyListPath -Encoding UTF8

Write-Host "Key_List.csv 筆數: $($keyListData.Count)"

# ========== 備份原始檔案 ==========
if ($Backup) {
    $backupPath = $KeyListPath -replace '\.csv$', "_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    Write-Host "`n備份原始檔案到: $backupPath"
    Copy-Item -Path $KeyListPath -Destination $backupPath
}

# ========== 更新 Key_List.csv ==========
Write-Host "`n更新 Key_List.csv..."

$updatedCount = 0
$notFoundCount = 0
$results = @()

foreach ($row in $keyListData) {
    $alias = $row.key_alias
    
    # 複製原始欄位結構
    $newRow = [PSCustomObject]@{
        key_alias = $row.key_alias
        new_key   = $row.new_key
    }
    
    if ($newKeyMap.ContainsKey($alias)) {
        $oldKey = $row.new_key
        $newRow.new_key = $newKeyMap[$alias]
        $updatedCount++
        Write-Host "  更新: $alias"
        Write-Host "    舊值: $oldKey" -ForegroundColor DarkGray
        Write-Host "    新值: $($newRow.new_key)" -ForegroundColor Green
    }
    else {
        $notFoundCount++
        Write-Host "  未在 keyRecreateResults.csv 中找到: $alias" -ForegroundColor Yellow
    }
    
    $results += $newRow
}

# ========== 儲存更新後的 Key_List.csv ==========
Write-Host "`n儲存結果到: $KeyListPath"

$results | Export-Csv -Path $KeyListPath -NoTypeInformation -Encoding UTF8

Write-Host "`n=========================================="
Write-Host "完成！"
Write-Host "  已更新: $updatedCount 筆"
Write-Host "  未找到: $notFoundCount 筆"
Write-Host "  輸出檔案: $KeyListPath"
if ($Backup) {
    Write-Host "  備份檔案: $backupPath"
}
Write-Host "=========================================="
