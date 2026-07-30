[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$AsepriteSourceDirectory,

  [Parameter(Mandatory = $true)]
  [ValidateRange(1, 2147483647)]
  [int]$PackageRevision,

  [Parameter(Mandatory = $true)]
  [string]$UpdaterPackagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourceDirectory = [System.IO.Path]::GetFullPath($AsepriteSourceDirectory)
$aboutPath = Join-Path $sourceDirectory "data/widgets/about.xml"
$updaterPackagePath = [System.IO.Path]::GetFullPath($UpdaterPackagePath)

if (-not (Test-Path -LiteralPath $aboutPath -PathType Leaf)) {
  throw "Aseprite about window definition was not found: $aboutPath"
}
if (-not (Test-Path -LiteralPath $updaterPackagePath -PathType Leaf)) {
  throw "Updater package definition was not found: $updaterPackagePath"
}

$updaterPackage = Get-Content -Raw -LiteralPath $updaterPackagePath |
  ConvertFrom-Json
$updaterVersion = ([string]$updaterPackage.version).Trim()
if ($updaterVersion -notmatch '^[0-9]+(\.[0-9]+){2}([-.][0-9A-Za-z.-]+)?$') {
  throw "Unexpected updater version: $updaterVersion"
}

$aboutXml = [System.IO.File]::ReadAllText(
  $aboutPath,
  [System.Text.UTF8Encoding]::new($false))
$titleMarker = '<label text="" id="title" />'
$markerCount = [regex]::Matches(
  $aboutXml,
  [regex]::Escape($titleMarker)).Count
if ($markerCount -ne 1) {
  throw "Expected one Aseprite about title marker, found $markerCount"
}

$newline = if ($aboutXml.Contains("`r`n")) { "`r`n" } else { "`n" }
$versionLabel =
  "    <label text=`"中文增强版 pkg:$PackageRevision · 更新器 v$updaterVersion`" />"
$patchedXml = $aboutXml.Replace(
  $titleMarker,
  $titleMarker + $newline + $versionLabel)

try {
  [xml]$patchedXml | Out-Null
}
catch {
  throw "Patched Aseprite about window is not valid XML: $($_.Exception.Message)"
}

[System.IO.File]::WriteAllText(
  $aboutPath,
  $patchedXml,
  [System.Text.UTF8Encoding]::new($false))

Write-Host "About version: 中文增强版 pkg:$PackageRevision · 更新器 v$updaterVersion"
