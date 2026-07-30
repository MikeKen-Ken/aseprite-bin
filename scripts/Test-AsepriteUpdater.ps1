[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = [System.IO.Path]::GetFullPath(
  (Join-Path $PSScriptRoot ".."))
$helperSourcePath = Join-Path $PSScriptRoot "Invoke-AsepriteUpdate.ps1"
$testRoot = Join-Path (
  [System.IO.Path]::GetTempPath()) (
  "aseprite-bin-updater-test-" + [Guid]::NewGuid().ToString("N"))
$installation = Join-Path $testRoot "installation"
$payload = Join-Path $testRoot "payload\portable"
$archivePath = Join-Path $testRoot "artifact.zip"
$manifestPath = Join-Path $testRoot "manifest.json"
$downloadResultPath = Join-Path $testRoot "download-result.json"
$checkResultPath = Join-Path $testRoot "check-result.json"
$cancelResultPath = Join-Path $testRoot "cancel-result.json"
$cancellationPath = Join-Path $testRoot "cancel.flag"
$helperPath = Join-Path $testRoot "Invoke-AsepriteUpdate.ps1"
$downloadedStagingRoot = $null

function Write-Utf8Json([string]$Path, $Value) {
  $json = $Value | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText(
    $Path,
    $json + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message（期望：$Expected；实际：$Actual）"
  }
}

try {
  [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
  $helperText = Get-Content -Raw -Encoding UTF8 -LiteralPath $helperSourcePath
  [System.IO.File]::WriteAllText(
    $helperPath,
    $helperText,
    [System.Text.UTF8Encoding]::new($true))
  [System.IO.Directory]::CreateDirectory($installation) | Out-Null
  [System.IO.Directory]::CreateDirectory($payload) | Out-Null
  $localBuildKey = "updater-test-local"
  $remoteBuildKey = "updater-test-remote"
  Write-Utf8Json (Join-Path $installation "build-info.json") @{
    buildKey = $localBuildKey
  }
  Write-Utf8Json (Join-Path $payload "build-info.json") @{
    buildKey = $remoteBuildKey
  }
  Set-Content -LiteralPath (Join-Path $payload "aseprite.exe") -Value "fixture"
  Set-Content -LiteralPath (Join-Path $payload "update-existing.cmd") -Value "@echo off"
  Compress-Archive -LiteralPath $payload -DestinationPath $archivePath

  $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash
  Write-Utf8Json $manifestPath ([ordered]@{
    schemaVersion = 1
    status = "published"
    buildKey = $remoteBuildKey
    artifactId = 1
    artifactName = "updater-test"
    artifactDigest = "sha256:$digest"
    asepriteVersion = "v-test"
    chineseRelease = "test"
    expiresAt = [DateTimeOffset]::UtcNow.AddDays(1).ToString("o")
  })

  & $helperPath `
    -Mode Check `
    -InstallationDirectory $installation `
    -ResultPath $checkResultPath `
    -ManifestUri $manifestPath `
    -RequestId "check-test"
  $checkResult = Get-Content -Raw -LiteralPath $checkResultPath | ConvertFrom-Json
  Assert-Equal "update-available" $checkResult.status "更新检查状态错误"
  Assert-Equal "check-test" $checkResult.requestId "检查请求编号未保留"

  Set-Content -LiteralPath $cancellationPath -Value "cancel"
  & $helperPath `
    -Mode Check `
    -InstallationDirectory $installation `
    -ResultPath $cancelResultPath `
    -ManifestUri $manifestPath `
    -RequestId "cancel-test" `
    -CancellationPath $cancellationPath
  Assert-Equal 2 $LASTEXITCODE "取消操作退出代码错误"
  if (Test-Path -LiteralPath $cancelResultPath) {
    throw "取消后不应保留结果文件"
  }
  if (Test-Path -LiteralPath $cancellationPath) {
    throw "取消信号文件未清理"
  }

  & $helperPath `
    -Mode Download `
    -InstallationDirectory $installation `
    -ResultPath $downloadResultPath `
    -ManifestUri $manifestPath `
    -ArtifactArchivePath $archivePath `
    -RequestId "download-test"
  $downloadResult =
    Get-Content -Raw -LiteralPath $downloadResultPath | ConvertFrom-Json
  Assert-Equal "downloaded" $downloadResult.status "离线下载状态错误"
  Assert-Equal "download-test" $downloadResult.requestId "下载请求编号未保留"
  $downloadedBuildPath =
    Join-Path ([string]$downloadResult.stagingSource) "build-info.json"
  $downloadedBuild =
    Get-Content -Raw -LiteralPath $downloadedBuildPath | ConvertFrom-Json
  Assert-Equal $remoteBuildKey $downloadedBuild.buildKey "下载产物版本错误"
  $downloadedStagingRoot = [System.IO.Directory]::GetParent(
    [System.IO.Directory]::GetParent(
      [string]$downloadResult.stagingSource).FullName).FullName

  Write-Host "Updater tests passed."
}
finally {
  $temporaryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath()).TrimEnd("\", "/")
  if ($downloadedStagingRoot) {
    $normalizedStagingRoot =
      [System.IO.Path]::GetFullPath($downloadedStagingRoot)
    $requiredPrefix =
      $temporaryRoot + [System.IO.Path]::DirectorySeparatorChar +
      "aseprite-bin-update-"
    if ($normalizedStagingRoot.StartsWith(
        $requiredPrefix,
        [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $normalizedStagingRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
    }
  }
  $normalizedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
  $testPrefix =
    $temporaryRoot + [System.IO.Path]::DirectorySeparatorChar +
    "aseprite-bin-updater-test-"
  if ($normalizedTestRoot.StartsWith(
      $testPrefix,
      [System.StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $normalizedTestRoot -Recurse -Force `
      -ErrorAction SilentlyContinue
  }
}
