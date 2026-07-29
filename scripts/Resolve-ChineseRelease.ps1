[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$AsepriteVersion,

  [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ReleaseOverride = $env:CHINESE_EXTENSION_RELEASE,
  [string]$ReleaseSupportedVersionOverride = $env:CHINESE_EXTENSION_SUPPORTED_ASEPRITE_VERSION,
  [string]$GitHubToken = $env:GH_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$extensionRepository = "Cetaceaqua/Aseprite-Simplified-Chinese-Extension"

function Normalize-AsepriteVersion([string]$Version) {
  $normalized = $Version.Trim()
  if (-not $normalized.StartsWith("v")) {
    $normalized = "v$normalized"
  }
  if ($normalized -notmatch '^v[0-9]+(\.[0-9]+){2,3}([\-+][0-9A-Za-z.-]+)?$') {
    throw "Unexpected Aseprite version: $Version"
  }
  return $normalized
}

function Find-AsepriteVersion([string]$Text) {
  if ($Text -and $Text -match '(?i)\bAseprite\s+v?([0-9]+(?:\.[0-9]+){2,3}(?:[\-+][0-9A-Za-z.-]+)?)') {
    return Normalize-AsepriteVersion $Matches[1]
  }
  return $null
}

function Get-ApiHeaders {
  $headers = @{
    Accept = "application/vnd.github+json"
    "User-Agent" = "MikeKen-Ken-aseprite-bin"
    "X-GitHub-Api-Version" = "2022-11-28"
  }
  if ($GitHubToken) {
    $headers.Authorization = "Bearer $GitHubToken"
  }
  return $headers
}

function Invoke-GitHubJson([string]$Uri) {
  return Invoke-RestMethod -Headers (Get-ApiHeaders) -Uri $Uri
}

function Get-ReleaseCommitMessage($Release) {
  try {
    $tag = [Uri]::EscapeDataString([string]$Release.tag_name)
    $reference = Invoke-GitHubJson "https://api.github.com/repos/$extensionRepository/git/ref/tags/$tag"
    $objectType = [string]$reference.object.type
    $objectSha = [string]$reference.object.sha

    if ($objectType -eq "tag") {
      $tagObject = Invoke-GitHubJson "https://api.github.com/repos/$extensionRepository/git/tags/$objectSha"
      $objectType = [string]$tagObject.object.type
      $objectSha = [string]$tagObject.object.sha
    }
    if ($objectType -ne "commit") {
      return $null
    }

    $commit = Invoke-GitHubJson "https://api.github.com/repos/$extensionRepository/commits/$objectSha"
    return [string]$commit.commit.message
  }
  catch {
    Write-Warning "Could not inspect release tag '$($Release.tag_name)': $($_.Exception.Message)"
    return $null
  }
}

function Get-MappedEntryByRelease($Compatibility, [string]$Release) {
  foreach ($property in $Compatibility.PSObject.Properties) {
    if ([string]$property.Value.release -eq $Release) {
      return $property.Value
    }
  }
  return $null
}

function Get-ReleaseSupportedVersion($Release, $Compatibility) {
  $mapped = Get-MappedEntryByRelease $Compatibility ([string]$Release.tag_name)
  if ($mapped) {
    return Normalize-AsepriteVersion ([string]$mapped.supportedAsepriteVersion)
  }

  foreach ($text in @([string]$Release.name, [string]$Release.body)) {
    $found = Find-AsepriteVersion $text
    if ($found) {
      return $found
    }
  }

  return Find-AsepriteVersion (Get-ReleaseCommitMessage $Release)
}

$AsepriteVersion = Normalize-AsepriteVersion $AsepriteVersion
$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
$compatibilityFile = Join-Path $RepositoryRoot "config/chinese-extension-compatibility.json"
$compatibilityDocument = Get-Content -Raw -LiteralPath $compatibilityFile | ConvertFrom-Json
$compatibility = $compatibilityDocument.compatibility
$mappedProperty = $compatibility.PSObject.Properties |
  Where-Object Name -EQ $AsepriteVersion |
  Select-Object -First 1

$releaseTag = $null
$supportedAsepriteVersion = $null
$useLatestAlias = $false
$resolutionSource = $null

if ($ReleaseOverride) {
  $releaseTag = $ReleaseOverride.Trim()
  $resolutionSource = "manual-override"
  if ($ReleaseSupportedVersionOverride) {
    $supportedAsepriteVersion = Normalize-AsepriteVersion $ReleaseSupportedVersionOverride
  }
  else {
    $mappedOverride = Get-MappedEntryByRelease $compatibility $releaseTag
    if ($mappedOverride) {
      $supportedAsepriteVersion = Normalize-AsepriteVersion ([string]$mappedOverride.supportedAsepriteVersion)
    }
  }
}
else {
  try {
    # Store the response first so PowerShell enumerates the JSON array when it
    # enters the pipeline. Piping Invoke-RestMethod directly can treat the
    # complete response array as one object and filter every release out.
    $releaseResponse =
      Invoke-GitHubJson "https://api.github.com/repos/$extensionRepository/releases?per_page=30"
    $releases = @($releaseResponse | Where-Object { -not $_.draft -and -not $_.prerelease })
    if ($releases.Count -eq 0) {
      throw "No stable Chinese extension releases were returned"
    }

    # GitHub returns releases newest first. The first exact match is therefore
    # the newest translation compatible with this Aseprite version.
    foreach ($release in $releases) {
      $releaseSupportedVersion = Get-ReleaseSupportedVersion $release $compatibility
      if ($releaseSupportedVersion -eq $AsepriteVersion) {
        $releaseTag = [string]$release.tag_name
        $supportedAsepriteVersion = $releaseSupportedVersion
        $resolutionSource = "latest-exact-release"
        break
      }
    }

    if (-not $releaseTag) {
      $latestRelease = $releases[0]
      $releaseTag = [string]$latestRelease.tag_name
      $supportedAsepriteVersion = Get-ReleaseSupportedVersion $latestRelease $compatibility
      $resolutionSource = "latest-stable-fallback"
    }
  }
  catch {
    if ($mappedProperty) {
      Write-Warning "Could not query release metadata; using compatibility map. $($_.Exception.Message)"
      $releaseTag = [string]$mappedProperty.Value.release
      $supportedAsepriteVersion =
        Normalize-AsepriteVersion ([string]$mappedProperty.Value.supportedAsepriteVersion)
      $resolutionSource = "compatibility-map-fallback"
    }
    else {
      Write-Warning "Could not query release metadata; using GitHub's latest-release alias. $($_.Exception.Message)"
      $releaseTag = "latest"
      $useLatestAlias = $true
      $resolutionSource = "latest-alias-unverified"
    }
  }
}

$matchMode = if ($supportedAsepriteVersion -eq $AsepriteVersion) {
  "exact"
}
elseif ($supportedAsepriteVersion) {
  "fallback"
}
else {
  "unverified"
}

[ordered]@{
  asepriteVersion = $AsepriteVersion
  releaseTag = $releaseTag
  supportedAsepriteVersion = $supportedAsepriteVersion
  matchMode = $matchMode
  useLatestAlias = $useLatestAlias
  resolutionSource = $resolutionSource
} | ConvertTo-Json -Compress
