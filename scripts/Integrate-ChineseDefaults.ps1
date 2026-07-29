[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$AsepriteVersion,

  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,

  [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
  [ValidateSet("dark", "light")]
  [string]$ThemeVariant = "dark",
  [string]$ReleaseOverride = $env:CHINESE_EXTENSION_RELEASE,
  [string]$ReleaseSupportedVersionOverride = $env:CHINESE_EXTENSION_SUPPORTED_ASEPRITE_VERSION,
  [string]$LanguageArchivePath = "",
  [string]$ThemeArchivePath = "",
  [string]$GitHubToken = $env:GH_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$extensionRepository = "Cetaceaqua/Aseprite-Simplified-Chinese-Extension"
$languageAssetName = "aseprite-simplified-chinese-extension.aseprite-extension"
$themeAssetName = "aseprite-theme-boutique.aseprite-extension"

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

function Expand-ZipSafely([string]$ArchivePath, [string]$DestinationPath) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Directory]::CreateDirectory($DestinationPath) | Out-Null
  $destinationRoot = [System.IO.Path]::GetFullPath($DestinationPath)
  if (-not $destinationRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $destinationRoot += [System.IO.Path]::DirectorySeparatorChar
  }

  $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    foreach ($entry in $archive.Entries) {
      $target = [System.IO.Path]::GetFullPath((Join-Path $destinationRoot $entry.FullName))
      if (-not $target.StartsWith($destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe archive entry: $($entry.FullName)"
      }
      if (-not $entry.Name) {
        [System.IO.Directory]::CreateDirectory($target) | Out-Null
        continue
      }
      [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)) | Out-Null
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

function Reset-ChildDirectory([string]$Parent, [string]$Child) {
  $parentPath = [System.IO.Path]::GetFullPath($Parent)
  $childPath = [System.IO.Path]::GetFullPath($Child)
  $requiredPrefix = $parentPath.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
  if (-not $childPath.StartsWith($requiredPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to reset a directory outside the output: $childPath"
  }
  if (Test-Path -LiteralPath $childPath) {
    Remove-Item -LiteralPath $childPath -Recurse -Force
  }
  New-Item -ItemType Directory -Path $childPath -Force | Out-Null
}

function Write-JsonFile([string]$Path, $Value) {
  $json = $Value | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

$AsepriteVersion = Normalize-AsepriteVersion $AsepriteVersion
$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
  throw "Output directory does not exist: $OutputDirectory"
}

$compatibilityFile = Join-Path $RepositoryRoot "config/chinese-extension-compatibility.json"
$compatibilityDocument = Get-Content -Raw -LiteralPath $compatibilityFile | ConvertFrom-Json
$compatibility = $compatibilityDocument.compatibility
$mappedProperty = $compatibility.PSObject.Properties | Where-Object Name -EQ $AsepriteVersion | Select-Object -First 1

$releaseTag = $null
$supportedAsepriteVersion = $null
$matchMode = $null
$useLatestAlias = $false

if ($ReleaseOverride) {
  $releaseTag = $ReleaseOverride.Trim()
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
elseif ($mappedProperty) {
  $releaseTag = [string]$mappedProperty.Value.release
  $supportedAsepriteVersion = Normalize-AsepriteVersion ([string]$mappedProperty.Value.supportedAsepriteVersion)
}
else {
  try {
    $releases = @(
      Invoke-GitHubJson "https://api.github.com/repos/$extensionRepository/releases?per_page=30" |
        Where-Object { -not $_.draft -and -not $_.prerelease }
    )
    if ($releases.Count -eq 0) {
      throw "No stable Chinese extension releases were returned"
    }

    foreach ($release in $releases) {
      $releaseSupportedVersion = Get-ReleaseSupportedVersion $release $compatibility
      if ($releaseSupportedVersion -eq $AsepriteVersion) {
        $releaseTag = [string]$release.tag_name
        $supportedAsepriteVersion = $releaseSupportedVersion
        break
      }
    }

    if (-not $releaseTag) {
      $latestRelease = $releases[0]
      $releaseTag = [string]$latestRelease.tag_name
      $supportedAsepriteVersion = Get-ReleaseSupportedVersion $latestRelease $compatibility
    }
  }
  catch {
    Write-Warning "Could not query release metadata; using GitHub's latest-release alias. $($_.Exception.Message)"
    $releaseTag = "latest"
    $useLatestAlias = $true
  }
}

if ($supportedAsepriteVersion -eq $AsepriteVersion) {
  $matchMode = "exact"
}
elseif ($supportedAsepriteVersion) {
  $matchMode = "fallback"
}
else {
  $matchMode = "unverified"
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("aseprite-chinese-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
  if (-not $LanguageArchivePath) {
    $LanguageArchivePath = Join-Path $temporaryRoot $languageAssetName
    $releasePath = if ($useLatestAlias) { "latest/download" } else { "download/$([Uri]::EscapeDataString($releaseTag))" }
    $uri = "https://github.com/$extensionRepository/releases/$releasePath/$languageAssetName"
    Invoke-WebRequest -Headers @{ "User-Agent" = "MikeKen-Ken-aseprite-bin" } -Uri $uri -OutFile $LanguageArchivePath
  }
  if (-not $ThemeArchivePath) {
    $ThemeArchivePath = Join-Path $temporaryRoot $themeAssetName
    $releasePath = if ($useLatestAlias) { "latest/download" } else { "download/$([Uri]::EscapeDataString($releaseTag))" }
    $uri = "https://github.com/$extensionRepository/releases/$releasePath/$themeAssetName"
    Invoke-WebRequest -Headers @{ "User-Agent" = "MikeKen-Ken-aseprite-bin" } -Uri $uri -OutFile $ThemeArchivePath
  }

  $extensionsRoot = Join-Path $OutputDirectory "data/extensions"
  New-Item -ItemType Directory -Path $extensionsRoot -Force | Out-Null
  $languageDirectory = Join-Path $extensionsRoot "aseprite-simplified-chinese-extension"
  $themeDirectory = Join-Path $extensionsRoot "aseprite-theme-boutique"
  Reset-ChildDirectory $extensionsRoot $languageDirectory
  Reset-ChildDirectory $extensionsRoot $themeDirectory
  Expand-ZipSafely $LanguageArchivePath $languageDirectory
  Expand-ZipSafely $ThemeArchivePath $themeDirectory

  $languagePackagePath = Join-Path $languageDirectory "package.json"
  $languagePackage = Get-Content -Raw -LiteralPath $languagePackagePath | ConvertFrom-Json
  $extensionVersion = [string]$languagePackage.version
  $displaySuffix = switch ($matchMode) {
    "exact" { " $extensionVersion" }
    "fallback" { " $extensionVersion [旧版回退：$supportedAsepriteVersion]" }
    default { " $extensionVersion [兼容性未验证]" }
  }
  $languagePackage.displayName = "鲸流的中文 (简体)$displaySuffix"
  foreach ($language in $languagePackage.contributes.languages) {
    if ([string]$language.id -eq "zh_Hans_ceta") {
      $language.displayName = "鲸流的中文 (简体)$displaySuffix"
    }
  }
  Write-JsonFile $languagePackagePath $languagePackage

  $themeFontDirectory = Join-Path $themeDirectory "font"
  $coverageScript = Join-Path $RepositoryRoot "scripts/check-font-coverage.py"
  $boutiqueFont = Join-Path $themeFontDirectory "BoutiqueBitmap9x9_1.92.ttf"
  & python $coverageScript $boutiqueFont (Join-Path $languageDirectory "zh_Hans_ceta.ini")
  if ($LASTEXITCODE -ne 0) {
    throw "BoutiqueBitmap 9x9 does not cover every CJK character used by the selected translation"
  }

  $selectedTheme = if ($ThemeVariant -eq "dark") { "boutique-dark" } else { "boutique" }
  $ini = @"
# This file is here so Aseprite behaves as a portable program.
# These are first-run defaults; users can change them in Preferences.

[general]
language = zh_Hans_ceta

[theme]
selected = $selectedTheme
"@
  [System.IO.File]::WriteAllText(
    (Join-Path $OutputDirectory "aseprite.ini"),
    $ini.TrimStart() + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText(
    (Join-Path $OutputDirectory "aseprite.defaults.ini"),
    $ini.TrimStart() + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
  Copy-Item `
    -LiteralPath (Join-Path $RepositoryRoot "scripts/update-existing.cmd") `
    -Destination (Join-Path $OutputDirectory "update-existing.cmd")

  $releaseLabel = $releaseTag.TrimStart("v")
  $artifactName = "aseprite-$AsepriteVersion-zh-$releaseLabel-boutique"
  if ($matchMode -eq "fallback") {
    $artifactName += "-fallback-from-$($supportedAsepriteVersion.TrimStart('v'))"
  }
  elseif ($matchMode -eq "unverified") {
    $artifactName += "-compat-unverified"
  }
  $artifactName = $artifactName -replace '[^0-9A-Za-z._-]', '-'

  $buildInfo = [ordered]@{
    asepriteVersion = $AsepriteVersion
    chineseExtension = [ordered]@{
      repository = $extensionRepository
      release = $releaseTag
      packageVersion = $extensionVersion
      matchMode = $matchMode
      supportedAsepriteVersion = $supportedAsepriteVersion
    }
    theme = [ordered]@{
      selected = $selectedTheme
      fontFamily = "BoutiqueBitmap9x9"
      miniFontFamily = "BoutiqueBitmap7x7"
    }
    artifactName = $artifactName
  }
  Write-JsonFile (Join-Path $OutputDirectory "build-info.json") $buildInfo

  if ($env:GITHUB_OUTPUT) {
    "CHINESE_EXTENSION_VERSION=$extensionVersion" >> $env:GITHUB_OUTPUT
    "CHINESE_RELEASE=$releaseTag" >> $env:GITHUB_OUTPUT
    "CHINESE_MATCH_MODE=$matchMode" >> $env:GITHUB_OUTPUT
    "CHINESE_SUPPORTED_ASEPRITE_VERSION=$supportedAsepriteVersion" >> $env:GITHUB_OUTPUT
    "ARTIFACT_NAME=$artifactName" >> $env:GITHUB_OUTPUT
  }
  if ($env:GITHUB_STEP_SUMMARY) {
    "### Simplified Chinese defaults" >> $env:GITHUB_STEP_SUMMARY
    "- Chinese release: ``$releaseTag`` (package ``$extensionVersion``)" >> $env:GITHUB_STEP_SUMMARY
    "- Compatibility: ``$matchMode``" >> $env:GITHUB_STEP_SUMMARY
    if ($supportedAsepriteVersion) {
      "- Translation target: ``$supportedAsepriteVersion``" >> $env:GITHUB_STEP_SUMMARY
    }
    else {
      "- Translation target: unknown; latest stable release was used" >> $env:GITHUB_STEP_SUMMARY
    }
    "- Default language: ``zh_Hans_ceta``" >> $env:GITHUB_STEP_SUMMARY
    "- Default theme: ``$selectedTheme``" >> $env:GITHUB_STEP_SUMMARY
    "- UI fonts: ``BoutiqueBitmap9x9`` / ``BoutiqueBitmap7x7``" >> $env:GITHUB_STEP_SUMMARY
    "- Artifact: ``$artifactName``" >> $env:GITHUB_STEP_SUMMARY
  }

  Write-Output "Chinese extension release: $releaseTag"
  Write-Output "Compatibility mode: $matchMode"
  Write-Output "Artifact name: $artifactName"
}
finally {
  $systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  $temporaryPath = [System.IO.Path]::GetFullPath($temporaryRoot)
  if ($temporaryPath.StartsWith($systemTemp, [System.StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $temporaryPath)) {
    Remove-Item -LiteralPath $temporaryPath -Recurse -Force
  }
}
