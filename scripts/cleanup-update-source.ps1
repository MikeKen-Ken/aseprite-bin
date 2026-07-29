[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SourceDirectory,

  [Parameter(Mandatory = $true)]
  [string]$DestinationDirectory,

  [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedDirectory([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar)
}

$source = Get-NormalizedDirectory $SourceDirectory
$destination = Get-NormalizedDirectory $DestinationDirectory
$sourceRoot = [System.IO.Path]::GetPathRoot($source).TrimEnd(
  [System.IO.Path]::DirectorySeparatorChar,
  [System.IO.Path]::AltDirectorySeparatorChar)

if ($source -eq $sourceRoot) {
  throw "Refusing to clean a drive root: $source"
}
if ($source.Equals($destination, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "The source and destination folders are the same"
}
$sourcePrefix = $source + [System.IO.Path]::DirectorySeparatorChar
if ($destination.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "The destination folder is inside the update source"
}

$manifestPath = Join-Path $source "build-info.json"
foreach ($requiredFile in @("aseprite.exe", "update-existing.cmd", "build-info.json")) {
  if (-not (Test-Path -LiteralPath (Join-Path $source $requiredFile) -PathType Leaf)) {
    throw "The update source is missing required file: $requiredFile"
  }
}

if ($ValidateOnly) {
  exit 0
}

# Give update-existing.cmd time to finish so it is no longer reading files
# from the directory that will be removed.
Start-Sleep -Milliseconds 800

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$artifactName = [string]$manifest.artifactName
$parent = [System.IO.Directory]::GetParent($source).FullName
$removeParentWhenEmpty =
  [System.IO.Path]::GetFileName($parent).Equals(
    $artifactName,
    [System.StringComparison]::OrdinalIgnoreCase)

Remove-Item -LiteralPath $source -Recurse -Force

# GitHub's downloaded artifact normally adds an outer directory named after
# the artifact. Remove it only when the name matches and it is now empty.
if ($removeParentWhenEmpty -and
    (Test-Path -LiteralPath $parent -PathType Container) -and
    @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) {
  Remove-Item -LiteralPath $parent -Force
}
