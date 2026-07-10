# 依據 key_alias 先查詢 /key/list 取得 hash，再呼叫 /key/info 取得詳細資訊，
# 最後呼叫 /key/{hash}/regenerate 重新產生 Key，並輸出結果

[CmdletBinding()]
param(
	[Parameter(Mandatory = $false)]
	[string]$CsvPath,

	[Parameter(Mandatory = $false)]
	[string]$ApiBaseUrl = "http://localhost:4000",

	[Parameter(Mandatory = $false)]
	[string]$RegenerateEndpointTemplate = "/key/{key}/regenerate",

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
	$ResultPath = Join-Path $scriptRoot "keyRegenerateResults.csv"
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

function Get-ResponseBody {
	param(
		[System.Exception]$Exception
	)

	try {
		$response = $Exception.Response
		if (-not $response) {
			return $null
		}
		$stream = $response.GetResponseStream()
		if (-not $stream) {
			return $null
		}
		$reader = New-Object System.IO.StreamReader($stream)
		return $reader.ReadToEnd()
	} catch {
		return $null
	}
}

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

# 取得每個 key 的詳細資訊，建立 key_alias -> hash 對照表
Write-Host "取得每個 Key 的詳細資訊..."
$aliasToHashMap = @{}
$hashToInfoMap = @{}

foreach ($hash in $allKeyHashes) {
	$infoUri = "$baseUrl/key/info?key=$hash"
	try {
		$infoResponse = Invoke-RestMethod -Method Get -Uri $infoUri -Headers $headers -ContentType "application/json"
		$keyAlias = $infoResponse.info.key_alias
		if (-not [string]::IsNullOrWhiteSpace($keyAlias)) {
			$aliasToHashMap[$keyAlias] = $hash
			$hashToInfoMap[$hash] = $infoResponse.info
		}
	} catch {
		Write-Host "取得 $hash 資訊失敗，略過"
	}
}

Write-Host "共對照到 $($aliasToHashMap.Count) 個 key_alias"

$resultRows = @()

foreach ($row in $rows) {
	$alias = $row.key_alias
	if ([string]::IsNullOrWhiteSpace($alias)) {
		throw "CSV 欄位 key_alias 為空"
	}

	if (-not $aliasToHashMap.ContainsKey($alias)) {
		Write-Host "找不到 key_alias：$alias"
		$resultRows += [pscustomobject]@{
			key_alias = $alias
			key_hash = $null
			new_key = $null
			key_info_json = $null
			response_json = $null
			status = "not_found"
		}
		continue
	}

	$keyHash = $aliasToHashMap[$alias]
	$keyInfo = $hashToInfoMap[$keyHash]

	$regenPath = $RegenerateEndpointTemplate.Replace("{key}", $keyHash)
	$regenUri = $baseUrl + $regenPath

	if ($WhatIf) {
		Write-Host "[WhatIf] 送出呼叫：$regenUri"
		$resultRows += [pscustomobject]@{
			key_alias = $alias
			key_hash = $keyHash
			new_key = $null
			key_info_json = ($keyInfo | ConvertTo-Json -Depth 10 -Compress)
			response_json = $null
			status = "whatif"
		}
		continue
	}

	Write-Host "重新產生 Key：$alias"
	try {
		$regenResponse = Invoke-RestMethod -Method Post -Uri $regenUri -Headers $headers -ContentType "application/json"
	} catch {
		$body = Get-ResponseBody -Exception $_.Exception
		Write-Host "重新產生失敗：$alias`n$($body)"
		$resultRows += [pscustomobject]@{
			key_alias = $alias
			key_hash = $keyHash
			new_key = $null
			key_info_json = ($keyInfo | ConvertTo-Json -Depth 10 -Compress)
			response_json = $body
			status = "regenerate_failed"
		}
		continue
	}
	$regenResponseJson = $regenResponse | ConvertTo-Json -Depth 10 -Compress

	$newKeyValue = $null
	if ($regenResponse -and $regenResponse.PSObject.Properties.Name -contains "key") {
		$newKeyValue = $regenResponse.key
	} elseif ($regenResponse -and $regenResponse.PSObject.Properties.Name -contains "api_key") {
		$newKeyValue = $regenResponse.api_key
	} elseif ($regenResponse -and $regenResponse.PSObject.Properties.Name -contains "access_key") {
		$newKeyValue = $regenResponse.access_key
	}

	$resultRows += [pscustomobject]@{
		key_alias = $alias
		key_hash = $keyHash
		new_key = $newKeyValue
		key_info_json = ($keyInfo | ConvertTo-Json -Depth 10 -Compress)
		response_json = $regenResponseJson
		status = "ok"
	}
}

if ($resultRows.Count -gt 0) {
	$resultRows | Export-Csv -Path $ResultPath -NoTypeInformation -Encoding UTF8
	Write-Host "已輸出回傳結果：$ResultPath"
}
