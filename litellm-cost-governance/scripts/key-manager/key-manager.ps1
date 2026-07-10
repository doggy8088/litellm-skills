#!/usr/bin/env pwsh
# key-manager.ps1 - CSV 金鑰管理工具

# 完整呼叫範例，如果是外部使用 SSH 呼叫，則前面使用 `ssh user@host` 後面接以下指令：
# 1. 列出清單：
#    ./key-manager.ps1 -Path ./Key_List.csv -List
# 2. 依 name 取 key（第一筆）：
#    ./key-manager.ps1 -Path ./Key_List.csv -Name "rg-aoai-jia"
# 3. 依 name 取 key（全部）：
#    ./key-manager.ps1 -Path ./Key_List.csv -Name "rg-aoai-jia" -All
# 4. 新增一筆：
#    ./key-manager.ps1 -Path ./Key_List.csv -Create -Name "rg-aoai-new" -Key "REDACTED_KEY"
# 5. 更新一筆：
#    ./key-manager.ps1 -Path ./Key_List.csv -Update -Name "rg-aoai-new" -Key "REDACTED_KEY"
# 6. 刪除一筆：
#    ./key-manager.ps1 -Path ./Key_List.csv -Delete -Name "rg-aoai-new"

<#
用法：
  # 列出完整清單
  .\key-manager.ps1 -Path .\data.csv -List

  # 依 name 取 key（第一筆）
  .\key-manager.ps1 -Path .\data.csv -Name "Alice"

  # 依 name 取 key（全部）
  .\key-manager.ps1 -Path .\data.csv -Name "Alice" -All

  # 新增一筆
  .\key-manager.ps1 -Path .\data.csv -Create -Name "Alice" -Key "REDACTED_KEY"

  # 更新一筆
  .\key-manager.ps1 -Path .\data.csv -Update -Name "Alice" -Key "REDACTED_KEY"

  # 刪除一筆
  .\key-manager.ps1 -Path .\data.csv -Delete -Name "Alice"
#>

[CmdletBinding(DefaultParameterSetName = "Get")]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Path,

  [Parameter(ParameterSetName = "List", Mandatory = $true)]
  [switch]$List,

  [Parameter(ParameterSetName = "Get", Mandatory = $true)]
  [Parameter(ParameterSetName = "Create", Mandatory = $true)]
  [Parameter(ParameterSetName = "Update", Mandatory = $true)]
  [Parameter(ParameterSetName = "Delete", Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Name,

  [Parameter(ParameterSetName = "Create", Mandatory = $true)]
  [switch]$Create,

  [Parameter(ParameterSetName = "Update", Mandatory = $true)]
  [switch]$Update,

  [Parameter(ParameterSetName = "Delete", Mandatory = $true)]
  [switch]$Delete,

  [Parameter(ParameterSetName = "Create", Mandatory = $true)]
  [Parameter(ParameterSetName = "Update", Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Key,

  [Parameter(ParameterSetName = "Get")]
  [switch]$All
)

if (-not (Test-Path -LiteralPath $Path)) {
  Write-Error "CSV 檔不存在：$Path"
  exit 2
}

# 讀取 CSV（期待欄位 name, key）
$rows = Import-Csv -LiteralPath $Path

# 欄位檢查（避免拼錯欄名）
if ($rows.Count -gt 0) {
  $props = $rows[0].PSObject.Properties.Name
  if (-not ($props -contains 'key_alias' -and $props -contains 'new_key')) {
    Write-Error "CSV 必須包含欄位：key_alias, new_key（目前欄位：$($props -join ', ')）"
    exit 2
  }
}

switch ($PSCmdlet.ParameterSetName) {
  "List" {
    # 輸出完整清單（可改成 Format-Table 顯示）
    $rows |
      Select-Object key_alias, new_key |
      Format-Table -AutoSize |
      Out-String |
      Write-Output
    exit 0
  }

  "Get" {
    $matches = $rows | Where-Object { $_.key_alias -eq $Name }

    if (-not $matches) {
      # 找不到：用 exit code 3 方便腳本判斷
      exit 3
    }

    if ($All) {
      # 回傳所有符合的 key（每行一個）
      $matches | ForEach-Object { $_.new_key }
    } else {
      # 回傳第一筆 key（純文字，方便接其他命令）
      $matches[0].new_key
    }
    exit 0
  }

  "Create" {
    if ($rows | Where-Object { $_.key_alias -eq $Name }) {
      Write-Error "已存在相同的 name：$Name"
      exit 4
    }

    $newRow = [PSCustomObject]@{
      key_alias = $Name
      new_key   = $Key
    }

    @($rows + $newRow) | Export-Csv -LiteralPath $Path -NoTypeInformation
    exit 0
  }

  "Update" {
    $matches = $rows | Where-Object { $_.key_alias -eq $Name }
    if (-not $matches) {
      exit 3
    }

    $rows | ForEach-Object {
      if ($_.key_alias -eq $Name) {
        $_.new_key = $Key
      }
    }

    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation
    exit 0
  }

  "Delete" {
    $remaining = $rows | Where-Object { $_.key_alias -ne $Name }
    if ($remaining.Count -eq $rows.Count) {
      exit 3
    }

    $remaining | Export-Csv -LiteralPath $Path -NoTypeInformation
    exit 0
  }
}
