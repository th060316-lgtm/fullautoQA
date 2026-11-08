# Reconstruct the preserved source substrate, then overlay the checked-out source.
# Recovery input is declared by TRANSFER_MANIFEST.json or explicitly supplied.
#
# ASCII-only invariant: this file must never contain a byte above 0x7F.
# Windows PowerShell 5.1 decodes a BOM-less script with the system ANSI code
# page, so a non-ASCII literal here would be mojibake on a real machine while
# a hosted PowerShell 7 run would still pass.  The repository source root is
# therefore resolved structurally through the shared entry contract in
# scripts/REPOSITORY_ENTRY.ps1 instead of by a hard-coded directory name.
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

# Captured before the shared contract is dot-sourced: dot-sourcing assigns the
# dot-sourced script's own $PSScriptRoot into the caller's scope.
$ScriptDirectory=$PSScriptRoot
. (Join-Path $ScriptDirectory 'REPOSITORY_ENTRY.ps1')

$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
$Destination=[IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'SOURCE_DESTINATION_MUST_BE_FRESH' }

if ([string]::IsNullOrWhiteSpace($RecoveryArchive)) {
  $transferManifestPath=Get-TransferManifestPath -SourceRoot (Get-RepositorySourceRoot)
  if (-not (Test-Path -LiteralPath $transferManifestPath -PathType Leaf)) {
    throw ('TRANSFER_MANIFEST_MISSING:'+$transferManifestPath)
  }
  $transfer=Read-TransferManifest -ManifestPath $transferManifestPath
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
$recoverySha=Get-Sha256File $RecoveryArchive
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

$current=Split-Path -Parent $ScriptDirectory
if (-not (Test-Path -LiteralPath (Join-Path $current 'CORE') -PathType Container)) { throw 'CURRENT_SOURCE_ROOT_INVALID' }
Get-ChildItem -LiteralPath $current -Force | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $sourceRoot -Recurse -Force
}

Get-ChildItem -LiteralPath $sourceRoot -Directory -Recurse -Filter '__pycache__' |
  Remove-Item -Recurse -Force
Write-Output $sourceRoot
