# 根據 userList.csv 中的 key_alias 刪除舊 Key，再重新建立新 Key 並保存回傳結果

[CmdletBinding()]
param(
	[Parameter(Mandatory = $false)]
	[string]$CsvPath,

	[Parameter(Mandatory = $false)]
	[string]$ApiBaseUrl = "http://localhost:4000",

	[Parameter(Mandatory = $false)]
	[string]$AuthHeaderName = "Authorization",

	[Parameter(Mandatory = $false)]
	[string]$AuthToken = "",

	[Parameter(Mandatory = $false)]
	[string]$ResultPath,

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
	throw "Provide -AuthToken or set LITELLM_ADMIN_TOKEN / LITELLM_MASTER_KEY."
}

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
	$CsvPath = Join-Path $scriptRoot "userList.csv"
}
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
	$ResultPath = Join-Path $scriptRoot "keyRecreateResults.csv"
}

if (-not (Test-Path -Path $CsvPath)) {
	throw "找不到 CSV 檔案：$CsvPath"
}

$rows = Import-Csv -Path $CsvPath
if (-not $rows -or $rows.Count -eq 0) {
	throw "CSV 無資料：$CsvPath"
}

$baseUrl = $ApiBaseUrl.TrimEnd("/")

$headers = @{}
$headers[$AuthHeaderName] = Resolve-AuthHeaderValue -TokenFromParam $AuthToken

function Parse-JsonOrDefault {
	param([string]$Value, $DefaultValue)
	if ([string]::IsNullOrWhiteSpace($Value)) { return $DefaultValue }
	try { return ($Value | ConvertFrom-Json) }
	catch { throw "欄位 JSON 解析失敗：$Value" }
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
	} catch { return $null }
}

# 建立 CSV 中 key_alias 的清單
$targetAliases = @{}
foreach ($row in $rows) {
	if (-not [string]::IsNullOrWhiteSpace($row.key_alias)) {
		$targetAliases[$row.key_alias] = $true
	}
}

Write-Host "目標 key_alias 數量：$($targetAliases.Count)"

# 取得所有 Key hash（支援分頁）
Write-Host "取得所有 Key Hash..."
$allKeyHashes = @()
$page = 1
do {
	$listUri = "$baseUrl/key/list?page=$page"
	try {
		$listResponse = Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers -ContentType "application/json"
	} catch {
		$body = Get-ResponseBody -Exception $_.Exception
		throw "呼叫 /key/list 失敗：$($_.Exception.Message)`n$body"
	}

	if ($listResponse.keys) {
		$allKeyHashes += $listResponse.keys
	}

	$totalPages = if ($listResponse.total_pages) { $listResponse.total_pages } else { 1 }
	$page++
} while ($page -le $totalPages)

Write-Host "共取得 $($allKeyHashes.Count) 個 Key Hash"

# 取得每個 key 的詳細資訊，只保留在目標清單中的
Write-Host "篩選目標 Key..."
$aliasToHashMap = @{}

foreach ($hash in $allKeyHashes) {
	$infoUri = "$baseUrl/key/info?key=$hash"
	try {
		$infoResponse = Invoke-RestMethod -Method Get -Uri $infoUri -Headers $headers -ContentType "application/json"
		$keyAlias = $infoResponse.info.key_alias
		if (-not [string]::IsNullOrWhiteSpace($keyAlias) -and $targetAliases.ContainsKey($keyAlias)) {
			$aliasToHashMap[$keyAlias] = $hash
			Write-Host "  找到目標：$keyAlias -> $hash"
		}
	} catch {
		Write-Host "  取得 $hash 資訊失敗，略過"
	}
}

Write-Host "共找到 $($aliasToHashMap.Count) 個目標 Key"

$resultRows = @()

foreach ($row in $rows) {
	$alias = $row.key_alias
	if ([string]::IsNullOrWhiteSpace($alias)) {
		throw "CSV 欄位 key_alias 為空"
	}

	$oldKeyHash = $null
	$deleteStatus = "no_existing_key"

	# 步驟1：如果有舊 Key，先刪除
	if ($aliasToHashMap.ContainsKey($alias)) {
		$oldKeyHash = $aliasToHashMap[$alias]

		if ($WhatIf) {
			Write-Host "[WhatIf] 刪除舊 Key：$alias ($oldKeyHash)"
			$deleteStatus = "whatif_delete"
		} else {
			Write-Host "刪除舊 Key：$alias ($oldKeyHash)"
			$deleteUri = "$baseUrl/key/delete"
			$deleteBody = @{ keys = @($oldKeyHash) } | ConvertTo-Json
			try {
				$deleteResponse = Invoke-RestMethod -Method Post -Uri $deleteUri -Headers $headers -ContentType "application/json" -Body $deleteBody
				$deleteStatus = "deleted"
				Write-Host "  刪除成功"
			} catch {
				$body = Get-ResponseBody -Exception $_.Exception
				Write-Host "  刪除失敗：$body"
				$deleteStatus = "delete_failed"
				$resultRows += [pscustomobject]@{
					key_alias       = $alias
					old_key_hash    = $oldKeyHash
					delete_status   = $deleteStatus
					new_key         = $null
					create_status   = "skipped"
					response_json   = $body
				}
				continue
			}
		}
	} else {
		Write-Host "無舊 Key：$alias"
	}

	# 步驟2：建立新 Key
	$models = Parse-JsonOrDefault -Value $row.models -DefaultValue @()
	# 移除模型名稱的 azure- 前綴
	$models = $models | ForEach-Object { $_ -replace '^azure-', '' }
	$metadata = Parse-JsonOrDefault -Value $row.metadata -DefaultValue @{}

	$payload = [ordered]@{
		user_id   = $row.user_id
		key_alias = $row.key_alias
		models    = $models
		key_type  = $row.key_type
		metadata  = $metadata
	}

	$jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress

	if ($WhatIf) {
		Write-Host "[WhatIf] 建立新 Key：$alias"
		$resultRows += [pscustomobject]@{
			key_alias       = $alias
			old_key_hash    = $oldKeyHash
			delete_status   = $deleteStatus
			new_key         = $null
			create_status   = "whatif_create"
			response_json   = $jsonBody
		}
		continue
	}

	Write-Host "建立新 Key：$alias"
	$createUri = "$baseUrl/key/generate"
	try {
		$createResponse = Invoke-RestMethod -Method Post -Uri $createUri -Headers $headers -ContentType "application/json" -Body $jsonBody
	} catch {
		$body = Get-ResponseBody -Exception $_.Exception
		Write-Host "  建立失敗：$body"
		$resultRows += [pscustomobject]@{
			key_alias       = $alias
			old_key_hash    = $oldKeyHash
			delete_status   = $deleteStatus
			new_key         = $null
			create_status   = "create_failed"
			response_json   = $body
		}
		continue
	}

	$responseJson = $createResponse | ConvertTo-Json -Depth 10 -Compress

	# 取得新 Key 值
	$newKeyValue = $null
	if ($createResponse -and $createResponse.PSObject.Properties.Name -contains "key") {
		$newKeyValue = $createResponse.key
	} elseif ($createResponse -and $createResponse.PSObject.Properties.Name -contains "api_key") {
		$newKeyValue = $createResponse.api_key
	} elseif ($createResponse -and $createResponse.PSObject.Properties.Name -contains "access_key") {
		$newKeyValue = $createResponse.access_key
	}

	if ([string]::IsNullOrWhiteSpace($newKeyValue)) {
		Write-Host "  警告：API 回傳成功但未找到 key 欄位"
		Write-Host "  回傳內容：$responseJson"
	} else {
		Write-Host "  建立成功：$newKeyValue"
	}

	$resultRows += [pscustomobject]@{
		key_alias       = $alias
		old_key_hash    = $oldKeyHash
		delete_status   = $deleteStatus
		new_key         = $newKeyValue
		create_status   = "ok"
		response_json   = $responseJson
	}
}

if ($resultRows.Count -gt 0) {
	$resultRows | Export-Csv -Path $ResultPath -NoTypeInformation -Encoding UTF8
	Write-Host ""
	Write-Host "=========================================="
	Write-Host "已輸出回傳結果：$ResultPath"
	Write-Host "共處理 $($resultRows.Count) 筆"
	Write-Host "=========================================="
}
