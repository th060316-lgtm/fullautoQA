# Reconstruct the preserved source substrate, then overlay the checked-out source.
# Recovery input is declared by TRANSFER_MANIFEST.json or explicitly supplied.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [Parameter(Mandatory=$true)][string]$Destination,
  [string]$RecoveryArchive='',
  [string]$ExpectedRecoverySha256=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-SHA256([string]$Path) {
  $stream=[IO.File]::OpenRead($Path)
  $hash=[Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
  finally { $hash.Dispose(); $stream.Dispose() }
}
function Resolve-RepositoryRelativePath([string]$Root,[string]$Relative) {
  if ([string]::IsNullOrWhiteSpace($Relative)) { throw 'DECLARED_REPOSITORY_PATH_EMPTY' }
  $normalized=$Relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
  if ([IO.Path]::IsPathRooted($normalized) -or $normalized -match '(^|[\\/])\.\.([\\/]|$)') {
    throw ('DECLARED_REPOSITORY_PATH_INVALID:'+ $Relative)
  }
  $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  $candidate=[IO.Path]::GetFullPath((Join-Path $rootFull $normalized))
  if (-not ($candidate.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))) {
    throw ('DECLARED_REPOSITORY_PATH_ESCAPE:'+ $Relative)
  }
  return $candidate
}

$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
$Destination=[IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'SOURCE_DESTINATION_MUST_BE_FRESH' }

if ([string]::IsNullOrWhiteSpace($RecoveryArchive)) {
  $transferManifestPath=Resolve-RepositoryRelativePath -Root $RepositoryRoot -Relative '開発版/transfer/TRANSFER_MANIFEST.json'
  if (-not (Test-Path -LiteralPath $transferManifestPath -PathType Leaf)) { throw 'TRANSFER_MANIFEST_MISSING' }
  $transfer=Get-Content -LiteralPath $transferManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $transfer.recovery_source -or [string]::IsNullOrWhiteSpace([string]$transfer.recovery_source.path)) {
    throw 'RECOVERY_SOURCE_DECLARATION_MISSING'
  }
  $RecoveryArchive=Resolve-RepositoryRelativePath -Root $RepositoryRoot -Relative ([string]$transfer.recovery_source.path)
  if ([string]::IsNullOrWhiteSpace($ExpectedRecoverySha256)) {
    $ExpectedRecoverySha256=[string]$transfer.recovery_source.sha256
  }
} else {
  $RecoveryArchive=[IO.Path]::GetFullPath($RecoveryArchive)
}

if (-not (Test-Path -LiteralPath $RecoveryArchive -PathType Leaf)) { throw 'RECOVERY_SOURCE_ARCHIVE_MISSING' }
$recoverySha=Get-SHA256 $RecoveryArchive
if (-not [string]::IsNullOrWhiteSpace($ExpectedRecoverySha256) -and
    $recoverySha -ne $ExpectedRecoverySha256.ToLowerInvariant()) {
  throw ('RECOVERY_SOURCE_SHA256_MISMATCH:'+ $recoverySha)
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory($RecoveryArchive,$Destination)

$matches=@(Get-ChildItem -LiteralPath $Destination -Recurse -File -Filter 'test_core.py' |
  Where-Object { $_.Directory.Name -eq 'TESTS' -and (Test-Path -LiteralPath (Join-Path $_.Directory.Parent.FullName 'CORE') -PathType Container) })
if ($matches.Count -ne 1) { throw ('RECOVERY_SOURCE_ROOT_AMBIGUOUS:'+ $matches.Count) }
$sourceRoot=$matches[0].Directory.Parent.FullName

$current=Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $current 'CORE') -PathType Container)) { throw 'CURRENT_SOURCE_ROOT_INVALID' }
Get-ChildItem -LiteralPath $current -Force | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $sourceRoot -Recurse -Force
}

Get-ChildItem -LiteralPath $sourceRoot -Directory -Recurse -Filter '__pycache__' |
  Remove-Item -Recurse -Force
Write-Output $sourceRoot
