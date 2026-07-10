#!/usr/bin/env pwsh
<#
.SYNOPSIS
    根據 Key_List.csv 為所有 Key 批次新增或移除 AI 模型存取權限，並可選擇在完成後測試呼叫。

.DESCRIPTION
    1. 讀取 Key_List.csv 取得所有 key_alias
    2. 透過 /key/list + /key/info 取得每個 key 的 token（hash）及目前 models 清單
    3. 依據 Action 參數，追加或移除指定的模型
    4. 呼叫 /key/update 更新 Key 的 models
    5. （可選）使用每個 key 的 API Key 呼叫 /chat/completions 測試模型是否可用

.PARAMETER KeyListPath
    Key_List.csv 的路徑，預設為腳本目錄下的 Key_List.csv。

.PARAMETER Models
    要追加或移除的模型名稱，以逗號分隔。
    例如 "gpt-5.3-codex-eu2,gpt-5.3-codex-sc"
    或分開傳入 "gpt-5.3-codex-eu2" "gpt-5.3-codex-sc"

.PARAMETER Action
    操作類型：Add（追加）或 Remove（移除）。預設為 Add。

.PARAMETER ApiBaseUrl
    LiteLLM API 的基底 URL。

.PARAMETER AuthToken
    管理員 Authorization Token（用於 /key/update 等管理端點）。

.PARAMETER TestAfterUpdate
    若指定此開關，更新完成後會使用每個 Key 逐一測試呼叫指定的模型。

.PARAMETER TestPrompt
    測試呼叫時使用的提示文字。

.PARAMETER WhatIf
    若指定此開關，僅列出將要執行的變更，不會實際更新。

.EXAMPLE
    # 從 bash 呼叫 - 為所有 Key 新增模型（逗號分隔，無空格）
    pwsh ./UpdateKey_HasModels.ps1 -Models "gpt-5.3-codex-eu2,gpt-5.3-codex-sc" -TestAfterUpdate

.EXAMPLE
    # 從 bash 呼叫 - 移除模型
    pwsh ./UpdateKey_HasModels.ps1 -Models "gpt-5.3-codex-eu2,gpt-5.3-codex-sc" -Action Remove

.EXAMPLE
    # 從 PowerShell 呼叫 - 多個模型
    .\UpdateKey_HasModels.ps1 -Models "gpt-5.3-codex-eu2","gpt-5.3-codex-sc" -Action Add

.EXAMPLE
    # 預覽模式：查看會更新哪些 Key，不實際執行
    pwsh ./UpdateKey_HasModels.ps1 -Models "gpt-5.3-codex-eu2" -WhatIf

.EXAMPLE
    # 移除錯誤的模型名稱
    pwsh ./UpdateKey_HasModels.ps1 -Models '@(gpt-5.3-codex-eu2, gpt-5.3-codex-sc)' -Action Remove
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$KeyListPath = "",

    [Parameter(Mandatory = $true)]
    [string[]]$Models,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Add", "Remove")]
    [string]$Action = "Add",

    [Parameter(Mandatory = $false)]
    [string]$ApiBaseUrl = "http://localhost:4000",

    [Parameter(Mandatory = $false)]
    [string]$AuthToken = "",

    [Parameter(Mandatory = $false)]
    [switch]$TestAfterUpdate,

    [Parameter(Mandatory = $false)]
    [string]$TestPrompt = "Say OK",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# ========== 正規化 Models 參數 ==========
# 支援逗號分隔字串、PowerShell 陣列、混合格式
# 在 Remove 模式下，也保留原始字串用於精確匹配（處理如 "@(a, b)" 被當成模型名的情況）
$rawModels = @($Models | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$parsedModels = @()
foreach ($item in $rawModels) {
    # 移除可能的 @( ) 包裝（防止 bash 傳入 PowerShell 陣列語法）
    $cleaned = $item
    if ($cleaned -match '^\@\((.+)\)$') {
        $cleaned = $Matches[1]
    }
    # 以逗號分割並修剪空白
    $parts = $cleaned -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $parsedModels += $parts
}

# 去重複
$parsedModels = @($parsedModels | Select-Object -Unique)

# Remove 模式額外保留原始字串，用於匹配那些被誤加為單一模型名稱的項目
# 例如 "@(gpt-5.3-codex-eu2, gpt-5.3-codex-sc)" 可能是一個完整的模型名稱
$removeExactModels = @()
if ($Action -eq "Remove") {
    $removeExactModels = @($rawModels + $parsedModels | Select-Object -Unique)
}

if ($parsedModels.Count -eq 0) {
    Write-Host "錯誤: 未提供有效的模型名稱" -ForegroundColor Red
    exit 1
}

# ========== 路徑設定 ==========
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

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($KeyListPath)) {
    $KeyListPath = Join-Path $ScriptDir "Key_List.csv"
}

if (-not (Test-Path -Path $KeyListPath)) {
    Write-Host "錯誤: 找不到 Key_List.csv: $KeyListPath" -ForegroundColor Red
    exit 1
}

$baseUrl = $ApiBaseUrl.TrimEnd("/")
$adminHeaders = @{ "Authorization" = (Resolve-AuthHeaderValue -TokenFromParam $AuthToken) }

# ========== 輔助函式 ==========
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
    catch { return $null }
}

# ========== 讀取 Key_List.csv ==========
$actionLabel = if ($Action -eq "Add") { "新增" } else { "移除" }

Write-Host "=========================================="
Write-Host " UpdateKey_HasModels - 批次${actionLabel}模型權限"
Write-Host "=========================================="
Write-Host ""
Write-Host "讀取 Key_List.csv: $KeyListPath"
$keyListData = Import-Csv -Path $KeyListPath -Encoding UTF8

if (-not $keyListData -or $keyListData.Count -eq 0) {
    Write-Host "錯誤: Key_List.csv 無資料" -ForegroundColor Red
    exit 1
}

Write-Host "Key_List.csv 筆數: $($keyListData.Count)"
Write-Host "操作模式: $actionLabel"
Write-Host "目標模型: $([string]::Join(', ', $parsedModels))"
Write-Host ""

# 建立 key_alias 集合
$targetAliases = @{}
foreach ($row in $keyListData) {
    if (-not [string]::IsNullOrWhiteSpace($row.key_alias)) {
        $targetAliases[$row.key_alias] = $row.new_key
    }
}

# ========== 取得所有 Key Hash（分頁） ==========
Write-Host "步驟 1/4: 取得所有 Key Hash..."
$allKeyHashes = @()
$page = 1

do {
    $listUri = "$baseUrl/key/list?page=$page"
    try {
        $listResponse = Invoke-RestMethod -Method Get -Uri $listUri -Headers $adminHeaders -ContentType "application/json"
    }
    catch {
        $body = Get-ResponseBody -Exception $_.Exception
        Write-Host "呼叫 /key/list 失敗: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $body -ForegroundColor Red
        exit 1
    }

    if ($listResponse.keys) {
        $allKeyHashes += $listResponse.keys
    }

    $totalPages = if ($listResponse.total_pages) { $listResponse.total_pages } else { 1 }
    Write-Host "  第 $page/$totalPages 頁，取得 $($listResponse.keys.Count) 個 Hash"
    $page++
} while ($page -le $totalPages)

Write-Host "  共取得 $($allKeyHashes.Count) 個 Key Hash"
Write-Host ""

# ========== 篩選目標 Key 並取得詳細資訊 ==========
Write-Host "步驟 2/4: 篩選目標 Key 並取得 models 資訊..."
$aliasInfoMap = @{}

$count = 0
foreach ($hash in $allKeyHashes) {
    $count++
    $infoUri = "$baseUrl/key/info?key=$hash"
    try {
        $infoResponse = Invoke-RestMethod -Method Get -Uri $infoUri -Headers $adminHeaders -ContentType "application/json"

        $keyAlias = $null
        $keyName = $null
        $currentModels = @()

        if ($infoResponse.info) {
            $keyAlias = $infoResponse.info.key_alias
            $keyName = $infoResponse.info.key_name
            if ($infoResponse.info.models) {
                $currentModels = @($infoResponse.info.models)
            }
        }
        elseif ($infoResponse.key_alias) {
            $keyAlias = $infoResponse.key_alias
            $keyName = $infoResponse.key_name
            if ($infoResponse.models) {
                $currentModels = @($infoResponse.models)
            }
        }

        if ($keyAlias -and $targetAliases.ContainsKey($keyAlias)) {
            $aliasInfoMap[$keyAlias] = @{
                hash          = $hash
                key_name      = $keyName
                currentModels = $currentModels
            }
            Write-Host "  [$count/$($allKeyHashes.Count)] 找到目標: $keyAlias (models: $($currentModels.Count))"
        }
    }
    catch {
        # 略過查詢失敗的 hash
    }
}

Write-Host "  共找到 $($aliasInfoMap.Count) / $($targetAliases.Count) 個目標 Key"
Write-Host ""

# ========== 更新 Key 的 models ==========
Write-Host "步驟 3/4: ${actionLabel} Key 的 models..."

$updateSuccessCount = 0
$updateSkipCount = 0
$updateFailCount = 0
$notFoundAliases = @()
$updateResults = @()

foreach ($row in $keyListData) {
    $alias = $row.key_alias
    if ([string]::IsNullOrWhiteSpace($alias)) { continue }

    if (-not $aliasInfoMap.ContainsKey($alias)) {
        Write-Host "  [略過] $alias - 在 API 中找不到對應的 Key" -ForegroundColor Yellow
        $notFoundAliases += $alias
        $updateResults += [PSCustomObject]@{
            key_alias      = $alias
            action         = $Action
            status         = "not_found"
            models_changed = ""
            error          = "在 API 中找不到"
        }
        continue
    }

    $info = $aliasInfoMap[$alias]
    $currentModels = @($info.currentModels)
    $modelsChanged = @()
    $newModels = @()

    if ($Action -eq "Add") {
        # 追加模式：計算要新增的模型（排除已存在的）
        foreach ($model in $parsedModels) {
            if ($currentModels -notcontains $model) {
                $modelsChanged += $model
            }
        }
        $newModels = @($currentModels) + @($modelsChanged)
    }
    else {
        # 移除模式：使用 removeExactModels（包含原始字串 + 解析後的模型名）
        foreach ($model in $removeExactModels) {
            if ($currentModels -contains $model) {
                $modelsChanged += $model
            }
        }
        $newModels = @($currentModels | Where-Object { $removeExactModels -notcontains $_ })
    }

    if ($modelsChanged.Count -eq 0) {
        $skipReason = if ($Action -eq "Add") { "所有指定模型已存在" } else { "指定的模型均不在清單中" }
        Write-Host "  [略過] $alias - $skipReason" -ForegroundColor Cyan
        $updateSkipCount++
        $updateResults += [PSCustomObject]@{
            key_alias      = $alias
            action         = $Action
            status         = "skipped"
            models_changed = ""
            error          = ""
        }
        continue
    }

    $modelsChangedStr = [string]::Join(", ", $modelsChanged)

    if ($WhatIf) {
        Write-Host "  [WhatIf] $alias - 將${actionLabel}: $modelsChangedStr" -ForegroundColor Magenta
        $updateResults += [PSCustomObject]@{
            key_alias      = $alias
            action         = $Action
            status         = "whatif"
            models_changed = $modelsChangedStr
            error          = ""
        }
        continue
    }

    # 呼叫 /key/update
    $updateUri = "$baseUrl/key/update"
    $updatePayload = @{
        key    = $info.hash
        models = @($newModels)
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        $null = Invoke-RestMethod -Method Post -Uri $updateUri -Headers $adminHeaders -ContentType "application/json" -Body $updatePayload
        Write-Host "  [成功] $alias - 已${actionLabel}: $modelsChangedStr" -ForegroundColor Green
        $updateSuccessCount++
        $updateResults += [PSCustomObject]@{
            key_alias      = $alias
            action         = $Action
            status         = "updated"
            models_changed = $modelsChangedStr
            error          = ""
        }
    }
    catch {
        $body = Get-ResponseBody -Exception $_.Exception
        Write-Host "  [失敗] $alias - $($_.Exception.Message)" -ForegroundColor Red
        if ($body) { Write-Host "         $body" -ForegroundColor Red }
        $updateFailCount++
        $updateResults += [PSCustomObject]@{
            key_alias      = $alias
            action         = $Action
            status         = "update_failed"
            models_changed = $modelsChangedStr
            error          = if ($body) { $body } else { $_.Exception.Message }
        }
    }
}

Write-Host ""
Write-Host "=========================================="
Write-Host " ${actionLabel}結果摘要"
Write-Host "=========================================="
Write-Host "  成功更新: $updateSuccessCount 筆"
Write-Host "  略過: $updateSkipCount 筆"
Write-Host "  更新失敗: $updateFailCount 筆"
Write-Host "  找不到 Key: $($notFoundAliases.Count) 筆"
Write-Host "=========================================="
Write-Host ""

# 匯出更新結果
$resultPath = Join-Path $ScriptDir "updateModelsResults.csv"
$updateResults | Export-Csv -Path $resultPath -NoTypeInformation -Encoding UTF8
Write-Host "更新結果已匯出至: $resultPath"
Write-Host ""

# ========== 測試呼叫 ==========
if ($TestAfterUpdate -and -not $WhatIf) {
    Write-Host "步驟 4/4: 測試呼叫${actionLabel}的模型..."
    Write-Host ""

    $testSuccessCount = 0
    $testFailCount = 0

    foreach ($row in $keyListData) {
        $alias = $row.key_alias
        $userApiKey = $row.new_key
        if ([string]::IsNullOrWhiteSpace($alias) -or [string]::IsNullOrWhiteSpace($userApiKey)) { continue }

        # 只測試更新成功的 Key
        $result = $updateResults | Where-Object { $_.key_alias -eq $alias -and $_.status -eq "updated" }
        if (-not $result) { continue }

        # 測試時只測 Add 模式的模型（Remove 模式測試意義不大）
        if ($Action -eq "Remove") {
            Write-Host "  [略過測試] $alias - 移除模式不需測試" -ForegroundColor Cyan
            continue
        }

        foreach ($model in $parsedModels) {
            Write-Host "  測試 $alias -> $model ... " -NoNewline

            # 根據模型名稱判斷使用的端點：
            #   - transcribe 模型      → /v1/audio/transcriptions（需上傳音訊檔案）
            #   - image 模型           → /v1/responses（mode: responses，圖片生成）
            #   - responses 模型       → /v1/responses（codex / gpt-5.4* / gpt-5.5* 等）
            #   - 其他模型             → /chat/completions（使用 messages 參數）
            $isTranscribeModel = $model -match 'transcribe'
            $isImageModel = $model -match 'gpt-image'
            $isResponsesModel = $model -match 'codex|gpt-5\.[4-9]|gpt-[6-9]\.'

            if ($isImageModel) {
                # 圖片生成模型：使用 /v1/responses（mode: responses）
                $testHeaders = @{
                    "Authorization" = "Bearer $userApiKey"
                    "Content-Type"  = "application/json"
                }
                $testUri = "$baseUrl/v1/responses"
                $testBody = @{
                    model = $model
                    input = "Generate a 1x1 pixel white image"
                } | ConvertTo-Json -Depth 10 -Compress

                try {
                    $testResponse = Invoke-RestMethod -Method Post -Uri $testUri -Headers $testHeaders -Body $testBody -TimeoutSec 120
                    $reply = ""
                    if ($testResponse.output -and $testResponse.output.Count -gt 0) {
                        $outputTypes = @($testResponse.output | ForEach-Object { $_.type }) -join ", "
                        $reply = "output types: $outputTypes"
                    }
                    Write-Host "OK - $reply" -ForegroundColor Green
                    $testSuccessCount++
                }
                catch {
                    $body = Get-ResponseBody -Exception $_.Exception
                    $errMsg = if ($body) { $body } else { $_.Exception.Message }
                    Write-Host "FAIL - $errMsg" -ForegroundColor Red
                    $testFailCount++
                }
            }
            elseif ($isTranscribeModel) {
                # Transcribe 模型：使用 /v1/audio/transcriptions，需上傳音訊檔案
                $testUri = "$baseUrl/v1/audio/transcriptions"

                # 產生最小的 1 秒靜音 WAV 檔作為測試用
                $testWavPath = Join-Path ([System.IO.Path]::GetTempPath()) "test_transcribe.wav"
                if (-not (Test-Path $testWavPath)) {
                    $sampleRate = 8000
                    $bitsPerSample = 16
                    $channels = 1
                    $duration = 1
                    $dataSize = $sampleRate * $duration * $channels * ($bitsPerSample / 8)
                    $ms = New-Object System.IO.MemoryStream
                    $bw = New-Object System.IO.BinaryWriter($ms)
                    # RIFF header
                    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("RIFF"))
                    $bw.Write([int](36 + $dataSize))
                    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("WAVEfmt "))
                    $bw.Write([int]16)                # chunk size
                    $bw.Write([int16]1)               # PCM format
                    $bw.Write([int16]$channels)
                    $bw.Write([int]$sampleRate)
                    $bw.Write([int]($sampleRate * $channels * $bitsPerSample / 8))
                    $bw.Write([int16]($channels * $bitsPerSample / 8))
                    $bw.Write([int16]$bitsPerSample)
                    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("data"))
                    $bw.Write([int]$dataSize)
                    $bw.Write((New-Object byte[] $dataSize))  # 靜音
                    [System.IO.File]::WriteAllBytes($testWavPath, $ms.ToArray())
                    $bw.Close(); $ms.Close()
                }

                try {
                    # 使用 curl 上傳 multipart form-data（PowerShell Invoke-RestMethod 對 multipart 支援較差）
                    $curlArgs = @(
                        '-s', '-w', '\nHTTP_CODE:%{http_code}',
                        $testUri,
                        '-H', "Authorization: Bearer $userApiKey",
                        '-F', "model=$model",
                        '-F', "file=@$testWavPath",
                        '--max-time', '60'
                    )
                    $curlOutput = & curl @curlArgs 2>&1 | Out-String
                    $httpCodeMatch = [regex]::Match($curlOutput, 'HTTP_CODE:(\d+)')
                    $httpCode = if ($httpCodeMatch.Success) { $httpCodeMatch.Groups[1].Value } else { "000" }
                    $responseBody = ($curlOutput -replace 'HTTP_CODE:\d+', '').Trim()

                    if ($httpCode -eq "200") {
                        $parsed = $responseBody | ConvertFrom-Json -ErrorAction SilentlyContinue
                        $reply = if ($parsed -and $parsed.text -ne $null) { "text='$($parsed.text)'" } else { "(OK)" }
                        Write-Host "OK - $reply" -ForegroundColor Green
                        $testSuccessCount++
                    }
                    else {
                        Write-Host "FAIL - HTTP $httpCode - $responseBody" -ForegroundColor Red
                        $testFailCount++
                    }
                }
                catch {
                    Write-Host "FAIL - $($_.Exception.Message)" -ForegroundColor Red
                    $testFailCount++
                }
            }
            elseif ($isResponsesModel) {
                $testHeaders = @{
                    "Authorization" = "Bearer $userApiKey"
                    "Content-Type"  = "application/json"
                }
                $testUri = "$baseUrl/v1/responses"
                $testBody = @{
                    model = $model
                    input = $TestPrompt
                } | ConvertTo-Json -Depth 10 -Compress

                try {
                    $testResponse = Invoke-RestMethod -Method Post -Uri $testUri -Headers $testHeaders -Body $testBody -TimeoutSec 60
                    $reply = ""
                    if ($testResponse.output -and $testResponse.output.Count -gt 0) {
                        $firstOutput = $testResponse.output[0]
                        if ($firstOutput.content -and $firstOutput.content.Count -gt 0) {
                            $reply = $firstOutput.content[0].text
                        }
                    }
                    Write-Host "OK - 回覆: $reply" -ForegroundColor Green
                    $testSuccessCount++
                }
                catch {
                    $body = Get-ResponseBody -Exception $_.Exception
                    $errMsg = if ($body) { $body } else { $_.Exception.Message }
                    Write-Host "FAIL - $errMsg" -ForegroundColor Red
                    $testFailCount++
                }
            }
            else {
                $testHeaders = @{
                    "Authorization" = "Bearer $userApiKey"
                    "Content-Type"  = "application/json"
                }
                $testUri = "$baseUrl/chat/completions"
                $testBody = @{
                    model    = $model
                    messages = @(
                        @{
                            role    = "user"
                            content = $TestPrompt
                        }
                    )
                    max_completion_tokens = 10
                } | ConvertTo-Json -Depth 10 -Compress

                try {
                    $testResponse = Invoke-RestMethod -Method Post -Uri $testUri -Headers $testHeaders -Body $testBody -TimeoutSec 60
                    $reply = ""
                    if ($testResponse.choices -and $testResponse.choices.Count -gt 0) {
                        $reply = $testResponse.choices[0].message.content
                    }
                    Write-Host "OK - 回覆: $reply" -ForegroundColor Green
                    $testSuccessCount++
                }
                catch {
                    $body = Get-ResponseBody -Exception $_.Exception
                    $errMsg = if ($body) { $body } else { $_.Exception.Message }
                    Write-Host "FAIL - $errMsg" -ForegroundColor Red
                    $testFailCount++
                }
            }
        }
    }

    Write-Host ""
    Write-Host "=========================================="
    Write-Host " 測試結果摘要"
    Write-Host "=========================================="
    Write-Host "  測試成功: $testSuccessCount 次"
    Write-Host "  測試失敗: $testFailCount 次"
    Write-Host "=========================================="
}
elseif ($TestAfterUpdate -and $WhatIf) {
    Write-Host "步驟 4/4: [WhatIf] 略過測試呼叫"
}
else {
    Write-Host "步驟 4/4: 未啟用測試（加 -TestAfterUpdate 可啟用）"
}

Write-Host ""
Write-Host "完成！"
