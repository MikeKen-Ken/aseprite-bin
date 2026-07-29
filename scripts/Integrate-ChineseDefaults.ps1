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

$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
  throw "Output directory does not exist: $OutputDirectory"
}

$resolverArguments = @{
  AsepriteVersion = $AsepriteVersion
  RepositoryRoot = $RepositoryRoot
  GitHubToken = $GitHubToken
}
if ($ReleaseOverride) {
  $resolverArguments.ReleaseOverride = $ReleaseOverride
}
if ($ReleaseSupportedVersionOverride) {
  $resolverArguments.ReleaseSupportedVersionOverride = $ReleaseSupportedVersionOverride
}
$resolutionJson = & (Join-Path $RepositoryRoot "scripts/Resolve-ChineseRelease.ps1") @resolverArguments
$resolution = $resolutionJson | ConvertFrom-Json
$AsepriteVersion = [string]$resolution.asepriteVersion
$releaseTag = [string]$resolution.releaseTag
$supportedAsepriteVersion = [string]$resolution.supportedAsepriteVersion
$matchMode = [string]$resolution.matchMode
$useLatestAlias = [bool]$resolution.useLatestAlias

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
