<#
.SYNOPSIS
  Upload a local file to Azure Blob Storage via SAS URL using Invoke-WebRequest.

.DESCRIPTION
  Uses HTTP PUT with the required x-ms-blob-type header and determines the
  Content-Type from common file extensions, falling back to system MIME mapping
  or application/octet-stream. Supports ShouldProcess for safety.

  上傳完成後會以 Write-Verbose 顯示上傳的 Blob URL；請用 -Verbose 來查看該資訊。

.PARAMETER FilePath
  Path to the local file to upload. Supports HTTP/HTTPS URLs and will download
  to a temporary file before uploading.

.PARAMETER SasUrl
  Container SAS URL (sr=c) that includes the SAS token. Example:
  https://account.blob.core.windows.net/container?sv=...

.PARAMETER BlobName
  Optional blob name (can include virtual folders like folder/file.txt).
  Defaults to the local file name.

.PARAMETER ContentType
  Optional override for the Content-Type header.

.PARAMETER SkipUrlValidation
  Skip the SAS URL querystring check (use only if the URL truly has no query).

.PARAMETER Open
  Open the uploaded file with the system default program after upload completes.

.PARAMETER Force
  Force overwrite if the blob already exists. Without this flag, existing blobs are skipped.

.EXAMPLE
  .\Upload-AzureBlobWithSas.ps1 -FilePath .\report.pdf -SasUrl "https://account.blob.core.windows.net/docs?sv=..." -Verbose

.EXAMPLE
  .\Upload-AzureBlobWithSas.ps1 -FilePath .\photo.jpg -BlobName "images/2025/photo.jpg" -SasUrl "https://account.blob.core.windows.net/assets?sv=..." -ContentType "image/jpeg"

.EXAMPLE
  .\Upload-AzureBlobWithSas.ps1 -FilePath "https://example.com/sample.pdf" -SasUrl "https://account.blob.core.windows.net/docs?sv=..." -Open
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [string]$FilePath,

  [string]$SasUrl = $env:AZURE_BACKUP_SAS_URL,

  [string]$BlobName,

  [string]$ContentType,

  [switch]$SkipUrlValidation,

  [switch]$Open,

  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SasUrl)) {
  throw "SasUrl is required. Pass -SasUrl or set AZURE_BACKUP_SAS_URL."
}

function Resolve-ContentType {
  param(
    [string]$Path,
    [string]$Override
  )

  if ($Override) { return $Override }

  $map = @{
    '.txt'  = 'text/plain'
    '.log'  = 'text/plain'
    '.md'   = 'text/markdown'
    '.csv'  = 'text/csv'
    '.tsv'  = 'text/tab-separated-values'
    '.json' = 'application/json'
    '.xml'  = 'application/xml'
    '.html' = 'text/html'
    '.htm'  = 'text/html'
    '.css'  = 'text/css'
    '.js'   = 'application/javascript'
    '.mjs'  = 'application/javascript'
    '.ts'   = 'application/typescript'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.bmp'  = 'image/bmp'
    '.webp' = 'image/webp'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/vnd.microsoft.icon'
    '.mp4'  = 'video/mp4'
    '.webm' = 'video/webm'
    '.mov'  = 'video/quicktime'
    '.pdf'  = 'application/pdf'
    '.zip'  = 'application/zip'
    '.gz'   = 'application/gzip'
    '.tar'  = 'application/x-tar'
    '.7z'   = 'application/x-7z-compressed'
    '.rar'  = 'application/vnd.rar'
  }

  $ext = [System.IO.Path]::GetExtension($Path)
  if ($ext) {
    $ext = $ext.ToLowerInvariant()
  }

  if ($ext -and $map.ContainsKey($ext)) {
    return $map[$ext]
  }

  try {
    $fromDotNet = [System.Web.MimeMapping]::GetMimeMapping($Path)
    if ($fromDotNet) {
      return $fromDotNet
    }
  } catch {
    Write-Verbose "System.Web.MimeMapping unavailable; using default MIME type."
  }

  return 'application/octet-stream'
}

function Validate-SasUrl {
  param(
    [string]$Url,
    [switch]$AllowMissingQuery
  )

  if (-not $Url.StartsWith('https://') -and -not $Url.StartsWith('http://')) {
    throw "SAS URL must start with http:// or https://."
  }

  if (-not $AllowMissingQuery -and -not $Url.Contains('?')) {
    throw "SAS URL should include query parameters. Use -SkipUrlValidation only when intentionally uploading without a SAS querystring."
  }

  if (-not $AllowMissingQuery) {
    $uri = [System.Uri]$Url
    if ($uri.Segments.Count -gt 2) {
      throw "SAS URL看起來是 Blob 級別（包含檔名）。請改用容器級別 SAS URL，或加上 -SkipUrlValidation 以略過檢查。"
    }
  }
}

Validate-SasUrl -Url $SasUrl -AllowMissingQuery:$SkipUrlValidation

function Get-BlobNameFromHash {
  param(
    [string]$Path
  )

  $git = Get-Command git.exe -ErrorAction SilentlyContinue
  if (-not $git) {
    throw "找不到 git，無法以檔案內容雜湊命名。請改用 -BlobName。"
  }

  $hash = & $git.Path 'hash-object' '--' $Path 2>$null
  if (-not $hash) {
    throw "git hash-object 執行失敗，請檢查檔案是否存在或手動指定 -BlobName。"
  }

  return $hash.Trim()
}

function Test-BlobExists {
  param(
    [string]$BlobUri
  )

  try {
    $response = Invoke-WebRequest -Uri $BlobUri -Method Head -UseBasicParsing -ErrorAction Stop
    $status = $null
    try { $status = $response.StatusCode } catch { }

    if ($status -eq 200 -or -not $status) {
      return $true
    }
  } catch [System.Net.WebException] {
    return $false
  } catch {
    Write-Verbose "檢查 Blob 是否存在時發生錯誤：$($_.Exception.Message)"
    return $false
  }

  return $false
}

function Build-BlobUri {
  param(
    [string]$ContainerSasUrl,
    [string]$BlobNameToUse
  )

  $uri = [System.Uri]$ContainerSasUrl
  $builder = [System.UriBuilder]$uri

  $path = $builder.Path.TrimEnd('/')
  $segments = $BlobNameToUse -split '/'
  $escaped = $segments | ForEach-Object { [System.Uri]::EscapeDataString($_) }
  $blobPath = ($escaped -join '/')

  $builder.Path = "$path/$blobPath"
  return $builder.Uri.AbsoluteUri
}

$downloadedTempFile = $null
$localPath = $FilePath

try {
  $uriCandidate = $null
  $isRemote = [System.Uri]::TryCreate($FilePath, [System.UriKind]::Absolute, [ref]$uriCandidate) -and
    @('http', 'https') -contains $uriCandidate.Scheme.ToLowerInvariant()

  if ($isRemote) {
    $tempDir = [System.IO.Path]::GetTempPath()
    $nameFromUrl = [System.IO.Path]::GetFileName($uriCandidate.AbsolutePath)
    if (-not $nameFromUrl) {
      $nameFromUrl = "$([guid]::NewGuid().ToString()).bin"
    }

    $tempPath = [System.IO.Path]::Combine($tempDir, $nameFromUrl)
    if (-not $PSCmdlet.ShouldProcess($uriCandidate.AbsoluteUri, "Download to temporary file $tempPath")) { return }

    Write-Verbose "偵測到遠端 URL，下載至暫存檔案：$tempPath"
    Invoke-WebRequest -Uri $uriCandidate.AbsoluteUri -OutFile $tempPath -UseBasicParsing
    $downloadedTempFile = $tempPath
    $localPath = $tempPath
  }

  $resolvedPath = Resolve-Path -LiteralPath $localPath -ErrorAction Stop
  $fileInfo = Get-Item -LiteralPath $resolvedPath

  if ($fileInfo.PSIsContainer) {
    throw "FilePath must reference a file, not a directory."
  }

  $blobNameToUpload = if ($BlobName) { $BlobName } else { Get-BlobNameFromHash -Path $fileInfo.FullName }
  $blobNameToUploadSource = if ($BlobName) { 'explicit argument' } else { 'git hash-object' }
  $blobUri = Build-BlobUri -ContainerSasUrl $SasUrl -BlobNameToUse $blobNameToUpload
  $publicBlobUri = if ($blobUri -and $blobUri.Contains('?')) { ($blobUri -split '\?')[0] } else { $blobUri }

  $contentTypeToUse = Resolve-ContentType -Path $fileInfo.FullName -Override $ContentType
  $headers = @{ 'x-ms-blob-type' = 'BlockBlob' }

  # 為壓縮檔或預設內容類型加入 Content-Disposition 以保留原始檔名
  $needsContentDisposition = @(
    'application/zip', 'application/gzip', 'application/x-tar',
    'application/x-7z-compressed', 'application/vnd.rar', 'application/octet-stream'
  ) -contains $contentTypeToUse

  if ($needsContentDisposition) {
    # 使用 RFC 5987 格式對非 ASCII 字元進行 URL 編碼
    $encodedFileName = [System.Uri]::EscapeDataString($fileInfo.Name)
    $headers['x-ms-blob-content-disposition'] = "attachment; filename*=UTF-8''$encodedFileName"
    Write-Verbose "已加入 x-ms-blob-content-disposition header: attachment; filename*=UTF-8''$encodedFileName"
  }

  $target = "$($fileInfo.Name) -> $blobUri"
  $uploadResultUri = $null

  if ($PSCmdlet.ShouldProcess($target, "Upload $($fileInfo.Length) bytes as $contentTypeToUse")) {
    Write-Verbose "Uploading: $($fileInfo.FullName)"
    Write-Verbose "Content-Type: $contentTypeToUse"
    Write-Verbose "Blob name: $blobNameToUpload (source: $blobNameToUploadSource)"

    $shouldUpload = $true
    if (-not $Force) {
      Write-Verbose "Checking if blob already exists before upload..."
      if (Test-BlobExists -BlobUri $blobUri) {
        Write-Verbose "Blob 已存在，跳過上傳： $publicBlobUri"
        $uploadResultUri = $publicBlobUri
        Write-Output $uploadResultUri
        $shouldUpload = $false
      }
    } else {
      Write-Verbose "Force 模式：將覆蓋已存在的 Blob"
    }

    if ($shouldUpload) {
      Write-Verbose "Using PUT with x-ms-blob-type=BlockBlob to $blobUri"

      $response = Invoke-WebRequest -Uri $blobUri -Method Put -InFile $fileInfo.FullName -ContentType $contentTypeToUse -Headers $headers -UseBasicParsing
      $status = $null
      try { $status = $response.StatusCode } catch { }

      if ($status) {
        $uploadResultUri = $publicBlobUri
        Write-Output $uploadResultUri
        Write-Verbose "Blob SAS URL（含憑證）: $blobUri（HTTP 狀態: $status）。"
      } else {
        $uploadResultUri = $publicBlobUri
        Write-Output $uploadResultUri
        Write-Verbose "Blob SAS URL（含憑證）: $blobUri。"
      }
    }
  }

  if ($Open -and $uploadResultUri) {
    Write-Verbose "開啟連結：$($blobUri)"
    Start-Process -FilePath $uploadResultUri
  }
} finally {
  if ($downloadedTempFile -and (Test-Path -LiteralPath $downloadedTempFile)) {
    try {
      Remove-Item -LiteralPath $downloadedTempFile -Force
      Write-Verbose "已刪除暫存檔案：$downloadedTempFile"
    } catch {
      Write-Verbose "刪除暫存檔案時發生錯誤：$($_.Exception.Message)"
    }
  }
}
