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
  [string]$RequestId = "",
  [string]$CancellationPath = "",
  [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:CheckTimeoutSec = 20
$script:DownloadTimeoutSec = 300
$script:GhTimeoutSec = 15

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
  if ($RequestId) {
    $result.requestId = $RequestId
  }
  foreach ($key in $Data.Keys) {
    $result[$key] = $Data[$key]
  }
  Write-JsonFile $ResultPath $result
}

function Test-UpdateCancelled {
  return $CancellationPath -and (Test-Path -LiteralPath $CancellationPath)
}

function Assert-UpdateNotCancelled {
  if (Test-UpdateCancelled) {
    throw [System.OperationCanceledException]::new("更新已取消")
  }
}

function Invoke-ExternalWithTimeout {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds,
    [string]$TimeoutMessage = "外部命令执行超时"
  )

  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()
  try {
    Assert-UpdateNotCancelled
    $process = Start-Process `
      -FilePath $FilePath `
      -ArgumentList $ArgumentList `
      -NoNewWindow `
      -PassThru `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $process.WaitForExit(250)) {
      if (Test-UpdateCancelled) {
        try { $process.Kill() } catch { }
        throw [System.OperationCanceledException]::new("更新已取消")
      }
      if ([DateTimeOffset]::UtcNow -ge $deadline) {
        try { $process.Kill() } catch { }
        throw $TimeoutMessage
      }
    }
    # WaitForExit(timeout) can return before redirected file handles finish
    # flushing. The parameterless call is immediate after process exit and
    # guarantees that gh auth token output is complete before we read it.
    $process.WaitForExit()
    $stdout = (Get-Content -Raw -LiteralPath $stdoutPath -ErrorAction SilentlyContinue)
    $stderr = (Get-Content -Raw -LiteralPath $stderrPath -ErrorAction SilentlyContinue)
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      StandardOutput = if ($null -eq $stdout) { "" } else { $stdout }
      StandardError = if ($null -eq $stderr) { "" } else { $stderr }
    }
  }
  finally {
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Write-DownloadProgress($Manifest, [long]$DownloadedBytes, $TotalBytes) {
  $data = @{
    manifest = $Manifest
    bytesDownloaded = $DownloadedBytes
  }
  if ($null -ne $TotalBytes -and [long]$TotalBytes -gt 0) {
    $total = [long]$TotalBytes
    $data.totalBytes = $total
    $data.progressPercent = [Math]::Min(
      100,
      [Math]::Floor(($DownloadedBytes * 100.0) / $total))
  }
  Write-UpdateResult "downloading" $data
}

function Invoke-StreamingDownload {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri,
    [Parameter(Mandatory = $true)]
    [hashtable]$Headers,
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,
    [Parameter(Mandatory = $true)]
    $Manifest
  )

  Add-Type -AssemblyName System.Net.Http
  $handler = [System.Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $true
  $client = [System.Net.Http.HttpClient]::new($handler)
  $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
  $request = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::Get,
    $Uri)
  foreach ($header in $Headers.GetEnumerator()) {
    $request.Headers.TryAddWithoutValidation(
      [string]$header.Key,
      [string]$header.Value) | Out-Null
  }

  $response = $null
  $inputStream = $null
  $outputStream = $null
  try {
    Assert-UpdateNotCancelled
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($script:DownloadTimeoutSec)
    $responseTask = $client.SendAsync(
      $request,
      [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    while (-not $responseTask.IsCompleted) {
      Assert-UpdateNotCancelled
      if ([DateTimeOffset]::UtcNow -ge $deadline) {
        throw "下载构建产物超时"
      }
      Start-Sleep -Milliseconds 250
    }
    $response = $responseTask.GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode() | Out-Null
    $totalBytes = $response.Content.Headers.ContentLength
    $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $outputStream = [System.IO.File]::Create($DestinationPath)
    $buffer = [byte[]]::new(128 * 1024)
    [long]$downloadedBytes = 0
    $lastProgressAt = [DateTimeOffset]::MinValue
    Write-DownloadProgress $Manifest 0 $totalBytes

    while ($true) {
      Assert-UpdateNotCancelled
      if ([DateTimeOffset]::UtcNow -ge $deadline) {
        throw "下载构建产物超时"
      }
      $readTask = $inputStream.ReadAsync($buffer, 0, $buffer.Length)
      while (-not $readTask.IsCompleted) {
        Assert-UpdateNotCancelled
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
          throw "下载构建产物超时"
        }
        Start-Sleep -Milliseconds 250
      }
      $count = $readTask.GetAwaiter().GetResult()
      if ($count -le 0) {
        break
      }
      $outputStream.Write($buffer, 0, $count)
      $downloadedBytes += $count
      $now = [DateTimeOffset]::UtcNow
      if (($now - $lastProgressAt).TotalMilliseconds -ge 400) {
        Write-DownloadProgress $Manifest $downloadedBytes $totalBytes
        $lastProgressAt = $now
      }
    }
    $outputStream.Flush()
    Write-DownloadProgress $Manifest $downloadedBytes $totalBytes
  }
  finally {
    if ($outputStream) { $outputStream.Dispose() }
    if ($inputStream) { $inputStream.Dispose() }
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
    $handler.Dispose()
  }
}

function Get-UpdateManifest {
  Assert-UpdateNotCancelled
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
    $manifest = Invoke-RestMethod `
      -Headers $headers `
      -Uri $uri `
      -TimeoutSec $script:CheckTimeoutSec
  }
  Assert-UpdateNotCancelled
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
      Assert-UpdateNotCancelled
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
  Assert-UpdateNotCancelled
  $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
  if (-not $gh) {
    return $null
  }

  $tokenResult = Invoke-ExternalWithTimeout `
    -FilePath $gh.Source `
    -ArgumentList @("auth", "token", "--hostname", "github.com") `
    -TimeoutSeconds $script:GhTimeoutSec `
    -TimeoutMessage "读取 GitHub CLI 令牌超时"
  Assert-UpdateNotCancelled
  # Windows PowerShell 5 can leave Start-Process.ExitCode unset even after
  # the process exits. A non-empty token is authoritative; when an exit code
  # is available, still reject explicit failures.
  if ($null -ne $tokenResult.ExitCode -and $tokenResult.ExitCode -ne 0) {
    return $null
  }
  $token = $tokenResult.StandardOutput.Trim()
  if (-not $token) {
    return $null
  }
  return $token
}

function Invoke-Download($Manifest) {
  $stagingRoot = Join-Path (
    [System.IO.Path]::GetTempPath()) (
    "aseprite-bin-update-" + [Guid]::NewGuid().ToString("N"))
  $archivePath = Join-Path $stagingRoot "artifact.zip"
  $extractPath = Join-Path $stagingRoot "extracted"
  [System.IO.Directory]::CreateDirectory($stagingRoot) | Out-Null

  try {
    Assert-UpdateNotCancelled
    if ($ArtifactArchivePath) {
      $archiveSize = (Get-Item -LiteralPath $ArtifactArchivePath).Length
      Write-DownloadProgress $Manifest 0 $archiveSize
      Copy-Item -LiteralPath $ArtifactArchivePath -Destination $archivePath
      Assert-UpdateNotCancelled
      Write-DownloadProgress $Manifest $archiveSize $archiveSize
    }
    else {
      Write-UpdateResult "authenticating" @{ manifest = $Manifest }
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
      Invoke-StreamingDownload `
        -Uri $uri `
        -Headers $headers `
        -DestinationPath $archivePath `
        -Manifest $Manifest
    }

    Assert-UpdateNotCancelled
    Write-UpdateResult "verifying" @{ manifest = $Manifest }
    $expectedDigest = ([string]$Manifest.artifactDigest) -replace '^sha256:', ''
    $actualDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash
    if ($actualDigest -ne $expectedDigest) {
      throw "构建产物的 SHA-256 完整性校验失败"
    }

    Assert-UpdateNotCancelled
    Write-UpdateResult "extracting" @{ manifest = $Manifest }
    Expand-ZipSafely $archivePath $extractPath
    Assert-UpdateNotCancelled
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

    Assert-UpdateNotCancelled
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
if ($CancellationPath) {
  $CancellationPath = [System.IO.Path]::GetFullPath($CancellationPath)
}

$scriptExitCode = 0
try {
  switch ($Mode) {
    "Check" {
      Assert-UpdateNotCancelled
      Write-UpdateResult "checking"
      $manifest = Get-UpdateManifest
      $localBuild = Get-LocalBuildInfo
      Assert-UpdateNotCancelled
      if (Test-UpdateAvailable $manifest $localBuild) {
        Write-UpdateResult "update-available" @{ manifest = $manifest }
      }
      else {
        Write-UpdateResult "up-to-date" @{ manifest = $manifest }
      }
    }
    "Download" {
      Assert-UpdateNotCancelled
      Write-UpdateResult "checking"
      $manifest = Get-UpdateManifest
      $localBuild = Get-LocalBuildInfo
      Assert-UpdateNotCancelled
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
  if ((Test-UpdateCancelled) -or
      $_.Exception -is [System.OperationCanceledException]) {
    Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue
    $scriptExitCode = 2
  }
  else {
    Write-UpdateResult "error" @{ message = $_.Exception.Message }
    $scriptExitCode = 1
  }
}
finally {
  if ($CancellationPath) {
    Remove-Item -LiteralPath $CancellationPath -Force -ErrorAction SilentlyContinue
  }
}
if ($scriptExitCode -ne 0) {
  exit $scriptExitCode
}
