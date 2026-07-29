[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Check", "Download", "Apply")]
  [string]$Mode,

  [Parameter(Mandatory = $true)]
  [string]$InstallationDirectory,

  [Parameter(Mandatory = $true)]
  [string]$ResultPath,

  [string]$Repository = "MikeKen-Ken/aseprite-bin",
  [string]$StagingSource = "",
  [string]$ManifestUri = "",
  [string]$ArtifactArchivePath = "",
  [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedDirectory([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar)
}

function Write-JsonFile([string]$Path, $Value) {
  $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
  [System.IO.Directory]::CreateDirectory($directory) | Out-Null
  $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
  $json = $Value | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText(
    $temporaryPath,
    $json + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Write-UpdateResult([string]$Status, [hashtable]$Data = @{}) {
  $result = [ordered]@{
    schemaVersion = 1
    operation = $Mode
    status = $Status
    timestamp = [DateTimeOffset]::UtcNow.ToString("o")
  }
  foreach ($key in $Data.Keys) {
    $result[$key] = $Data[$key]
  }
  Write-JsonFile $ResultPath $result
}

function Get-UpdateManifest {
  if ($Repository -notmatch '^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$') {
    throw "更新仓库地址无效：$Repository"
  }
  if ($ManifestUri -and (Test-Path -LiteralPath $ManifestUri -PathType Leaf)) {
    $manifest = Get-Content -Raw -LiteralPath $ManifestUri | ConvertFrom-Json
  }
  else {
    $uri = if ($ManifestUri) {
      $ManifestUri
    }
    else {
      "https://raw.githubusercontent.com/$Repository/HEAD/.github/update-manifest.json"
    }
    $headers = @{
      Accept = "application/vnd.github.raw+json"
      "User-Agent" = "MikeKen-Ken-aseprite-bin-updater"
      "Cache-Control" = "no-cache"
    }
    $manifest = Invoke-RestMethod -Headers $headers -Uri $uri
  }
  if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.status -ne "published") {
    throw "更新清单尚未发布，请稍后再试"
  }
  foreach ($property in @(
      "buildKey",
      "artifactId",
      "artifactName",
      "artifactDigest",
      "asepriteVersion",
      "chineseRelease",
      "expiresAt")) {
    if (-not [string]$manifest.$property) {
      throw "更新清单缺少必要信息：$property"
    }
  }
  if ([DateTimeOffset]::Parse([string]$manifest.expiresAt) -le [DateTimeOffset]::UtcNow) {
    throw "最新的 GitHub Actions 构建产物已经过期"
  }
  return $manifest
}

function Get-LocalBuildInfo {
  $path = Join-Path $InstallationDirectory "build-info.json"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "当前便携版缺少 build-info.json"
  }
  return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Test-UpdateAvailable($Manifest, $LocalBuild) {
  $localBuildKey = [string]$LocalBuild.buildKey
  if (-not $localBuildKey) {
    return $true
  }
  return $localBuildKey -ne [string]$Manifest.buildKey
}

function Expand-ZipSafely([string]$ArchivePath, [string]$DestinationPath) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Directory]::CreateDirectory($DestinationPath) | Out-Null
  $destinationRoot = Get-NormalizedDirectory $DestinationPath
  $destinationPrefix = $destinationRoot + [System.IO.Path]::DirectorySeparatorChar
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    foreach ($entry in $archive.Entries) {
      $target = [System.IO.Path]::GetFullPath((Join-Path $destinationRoot $entry.FullName))
      if (-not $target.StartsWith(
          $destinationPrefix,
          [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "压缩包包含不安全路径：$($entry.FullName)"
      }
      if (-not $entry.Name) {
        [System.IO.Directory]::CreateDirectory($target) | Out-Null
        continue
      }
      [System.IO.Directory]::CreateDirectory(
        [System.IO.Path]::GetDirectoryName($target)) | Out-Null
      $inputStream = $entry.Open()
      try {
        $outputStream = [System.IO.File]::Create($target)
        try {
          $inputStream.CopyTo($outputStream)
        }
        finally {
          $outputStream.Dispose()
        }
      }
      finally {
        $inputStream.Dispose()
      }
    }
  }
  finally {
    $archive.Dispose()
  }
}

function Get-GitHubToken {
  $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
  if (-not $gh) {
    return $null
  }
  & $gh.Source auth status --hostname github.com 1>$null 2>$null
  if ($LASTEXITCODE -ne 0) {
    return $null
  }
  $token = (& $gh.Source auth token --hostname github.com 2>$null | Out-String).Trim()
  if (-not $token) {
    return $null
  }
  return $token
}

function Invoke-Download($Manifest) {
  Write-UpdateResult "downloading" @{ manifest = $Manifest }
  $stagingRoot = Join-Path (
    [System.IO.Path]::GetTempPath()) (
    "aseprite-bin-update-" + [Guid]::NewGuid().ToString("N"))
  $archivePath = Join-Path $stagingRoot "artifact.zip"
  $extractPath = Join-Path $stagingRoot "extracted"
  [System.IO.Directory]::CreateDirectory($stagingRoot) | Out-Null

  try {
    if ($ArtifactArchivePath) {
      Copy-Item -LiteralPath $ArtifactArchivePath -Destination $archivePath
    }
    else {
      $token = Get-GitHubToken
      if (-not $token) {
        Write-UpdateResult "auth-required" @{
          message = "GitHub CLI is missing or is not logged in. Run: gh auth login"
          manifest = $Manifest
        }
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        return
      }
      $uri =
        "https://api.github.com/repos/$Repository/actions/artifacts/" +
        "$([string]$Manifest.artifactId)/zip"
      $headers = @{
        Accept = "application/vnd.github+json"
        Authorization = "Bearer $token"
        "User-Agent" = "MikeKen-Ken-aseprite-bin-updater"
        "X-GitHub-Api-Version" = "2022-11-28"
      }
      Invoke-WebRequest `
        -UseBasicParsing `
        -Headers $headers `
        -Uri $uri `
        -OutFile $archivePath
    }

    $expectedDigest = ([string]$Manifest.artifactDigest) -replace '^sha256:', ''
    $actualDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash
    if ($actualDigest -ne $expectedDigest) {
      throw "构建产物的 SHA-256 完整性校验失败"
    }

    Expand-ZipSafely $archivePath $extractPath
    $candidates = @(
      Get-ChildItem -LiteralPath $extractPath -Filter "build-info.json" -Recurse -File |
        Where-Object {
          Test-Path -LiteralPath (
            Join-Path $_.Directory.FullName "aseprite.exe") -PathType Leaf
        }
    )
    if ($candidates.Count -ne 1) {
      throw "压缩包内应只有一个 Aseprite 便携目录，实际找到 $($candidates.Count) 个"
    }

    $source = $candidates[0].Directory.FullName
    $downloadedBuild = Get-Content -Raw -LiteralPath $candidates[0].FullName |
      ConvertFrom-Json
    if ([string]$downloadedBuild.buildKey -ne [string]$Manifest.buildKey) {
      throw "下载的版本与更新清单不一致"
    }

    Remove-Item -LiteralPath $archivePath -Force
    Write-UpdateResult "downloaded" @{
      manifest = $Manifest
      stagingSource = $source
    }
  }
  catch {
    if (Test-Path -LiteralPath $stagingRoot) {
      Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    throw
  }
}

function Test-AsepriteIsRunning([string]$ExecutablePath) {
  foreach ($process in @(Get-Process -Name "aseprite" -ErrorAction SilentlyContinue)) {
    try {
      if ([string]$process.Path -and
          [System.IO.Path]::GetFullPath([string]$process.Path).Equals(
            $ExecutablePath,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    }
    catch {
      # A process can exit while its Path property is being read.
    }
  }
  return $false
}

function Invoke-Apply {
  if (-not $StagingSource) {
    throw "缺少已下载的更新目录"
  }

  $source = Get-NormalizedDirectory $StagingSource
  $temporaryRoot = Get-NormalizedDirectory ([System.IO.Path]::GetTempPath())
  $requiredPrefix =
    $temporaryRoot + [System.IO.Path]::DirectorySeparatorChar +
    "aseprite-bin-update-"
  if (-not $source.StartsWith(
      $requiredPrefix,
      [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "出于安全考虑，拒绝使用临时更新目录以外的文件"
  }
  foreach ($requiredFile in @("aseprite.exe", "build-info.json", "update-existing.cmd")) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $requiredFile) -PathType Leaf)) {
      throw "已下载的更新缺少文件：$requiredFile"
    }
  }

  $destination = Get-NormalizedDirectory $InstallationDirectory
  $destinationRoot = [System.IO.Path]::GetPathRoot($destination).TrimEnd('\', '/')
  if ($destination -eq $destinationRoot) {
    throw "出于安全考虑，不能把磁盘根目录作为更新目标"
  }
  $executablePath = Join-Path $destination "aseprite.exe"
  if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "当前目录缺少 aseprite.exe"
  }

  Write-UpdateResult "waiting-for-exit" @{ stagingSource = $source }
  $deadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
  while ((Test-AsepriteIsRunning $executablePath) -and
         [DateTimeOffset]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 500
  }
  if (Test-AsepriteIsRunning $executablePath) {
    throw "等待 10 分钟后 Aseprite 仍未退出，更新已取消"
  }

  & robocopy.exe `
    $source `
    $destination `
    /E /R:2 /W:1 /XF aseprite.ini /NFL /NDL /NJH /NJS /NP
  $robocopyExitCode = $LASTEXITCODE
  if ($robocopyExitCode -ge 8) {
    throw "复制新版文件失败（代码 $robocopyExitCode）"
  }

  Write-UpdateResult "installed" @{
    destination = $destination
    restarted = -not $NoRestart
  }

  $stagingRoot = [System.IO.Directory]::GetParent(
    [System.IO.Directory]::GetParent($source).FullName).FullName
  $normalizedStagingRoot = Get-NormalizedDirectory $stagingRoot
  if ($normalizedStagingRoot.StartsWith(
      $requiredPrefix,
      [System.StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $normalizedStagingRoot)) {
    Remove-Item -LiteralPath $normalizedStagingRoot -Recurse -Force
  }

  if (-not $NoRestart) {
    Start-Process -FilePath $executablePath -WorkingDirectory $destination
  }
}

$InstallationDirectory = Get-NormalizedDirectory $InstallationDirectory
$ResultPath = [System.IO.Path]::GetFullPath($ResultPath)

try {
  switch ($Mode) {
    "Check" {
      Write-UpdateResult "checking"
      $manifest = Get-UpdateManifest
      $localBuild = Get-LocalBuildInfo
      if (Test-UpdateAvailable $manifest $localBuild) {
        Write-UpdateResult "update-available" @{ manifest = $manifest }
      }
      else {
        Write-UpdateResult "up-to-date" @{ manifest = $manifest }
      }
    }
    "Download" {
      $manifest = Get-UpdateManifest
      $localBuild = Get-LocalBuildInfo
      if (-not (Test-UpdateAvailable $manifest $localBuild)) {
        Write-UpdateResult "up-to-date" @{ manifest = $manifest }
      }
      else {
        Invoke-Download $manifest
      }
    }
    "Apply" {
      Invoke-Apply
    }
  }
}
catch {
  Write-UpdateResult "error" @{ message = $_.Exception.Message }
  exit 1
}
