# Restore the preserved predecessor Candidate into a fresh directory.
# This proves byte-level rollback executability only; it does not promote the
# predecessor to Product Accepted / Stable or claim current-version QA.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Destination,
  [string]$RepositoryRoot='',
  [string]$EvidenceDirectory='',
  [switch]$SelfTest
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

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
  $RepositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
} else {
  $RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
}
$Destination=[IO.Path]::GetFullPath($Destination)
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
  $EvidenceDirectory=$Destination+'_evidence'
} else {
  $EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
}
if (Test-Path -LiteralPath $Destination) { throw 'ROLLBACK_DESTINATION_MUST_BE_FRESH' }
if (Test-Path -LiteralPath $EvidenceDirectory) { throw 'ROLLBACK_EVIDENCE_DESTINATION_MUST_BE_FRESH' }

$transferPath=Resolve-RepositoryRelativePath -Root $RepositoryRoot -Relative '開発版/transfer/TRANSFER_MANIFEST.json'
if (-not (Test-Path -LiteralPath $transferPath -PathType Leaf)) { throw 'TRANSFER_MANIFEST_MISSING' }
$transfer=Get-Content -LiteralPath $transferPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $transfer.latest_complete_candidate -or [string]::IsNullOrWhiteSpace([string]$transfer.latest_complete_candidate.path)) {
  throw 'ROLLBACK_PREDECESSOR_DECLARATION_MISSING'
}
$setRoot=Resolve-RepositoryRelativePath -Root $RepositoryRoot -Relative ([string]$transfer.latest_complete_candidate.path)
$manifestPath=Join-Path $setRoot 'manifest.json'
$joinPath=Join-Path $setRoot 'JOIN_COMPLETE.ps1'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $joinPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $setRoot 'blocks') -PathType Container)) {
  throw 'ROLLBACK_PREDECESSOR_SET_INVALID'
}
$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $ps -PathType Leaf)) { throw 'WINDOWS_POWERSHELL_MISSING' }
& $ps -NoLogo -NoProfile -ExecutionPolicy Bypass -File $joinPath
$joinExit=$LASTEXITCODE
if ($joinExit -ne 0) { throw ('ROLLBACK_PREDECESSOR_JOIN_FAILED:'+ $joinExit) }

$archive=Join-Path $setRoot ([string]$manifest.file)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw 'ROLLBACK_PREDECESSOR_ARCHIVE_MISSING' }
$size=(Get-Item -LiteralPath $archive).Length
$sha=Get-SHA256 $archive
if ($size -ne [long]$manifest.size) { throw 'ROLLBACK_PREDECESSOR_SIZE_MISMATCH' }
if ($sha -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw 'ROLLBACK_PREDECESSOR_SHA_MISMATCH' }

New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory($archive,$Destination)
$startQa=Join-Path $Destination 'START_QA.cmd'
if (-not (Test-Path -LiteralPath $startQa -PathType Leaf)) { throw 'ROLLBACK_START_QA_MISSING' }

$selftestStatus='NOT_RUN'
$selftestExit=$null
$resultZip=$null
if ($SelfTest) {
  $results=Join-Path $Destination 'RESULTS'
  $before=@()
  if (Test-Path -LiteralPath $results) {
    $before=@(Get-ChildItem -LiteralPath $results -Recurse -File -Filter 'RESULT_FOR_CHATGPT.zip' | ForEach-Object { $_.FullName })
  }
  $log=Join-Path $EvidenceDirectory 'ROLLBACK_PREDECESSOR_SELFTEST.log'
  Push-Location $Destination
  try {
    & $startQa -SelfTest *>&1 | Tee-Object -FilePath $log
    $selftestExit=$LASTEXITCODE
  } finally {
    Pop-Location
  }
  $after=@()
  if (Test-Path -LiteralPath $results) {
    $after=@(Get-ChildItem -LiteralPath $results -Recurse -File -Filter 'RESULT_FOR_CHATGPT.zip')
  }
  $new=@($after | Where-Object { $before -notcontains $_.FullName } | Sort-Object LastWriteTimeUtc -Descending)
  if ($selftestExit -eq 0 -and $new.Count -ge 1) {
    $selftestStatus='PASS'
    $resultZip=$new[0].FullName.Substring($Destination.Length).TrimStart('\').Replace('\','/')
  } else {
    $selftestStatus='FAIL'
  }
}

$proof=[ordered]@{
  schema_version=1
  predecessor_version=[string]$manifest.version
  predecessor_archive=[string]$manifest.file
  archive_size=[long]$size
  archive_sha256=$sha
  fresh_destination=$Destination
  byte_identity='PASS'
  start_qa_present=$true
  selftest_requested=[bool]$SelfTest
  selftest_status=$selftestStatus
  selftest_exit_code=$selftestExit
  result_zip=$resultZip
  runnable_rollback_status=$(if($SelfTest){$selftestStatus}else{'RESTORED_NOT_EXECUTED'})
  product_acceptance='NOT_CLAIMED'
  stable_certification='NOT_CLAIMED'
  claim_scope='Byte-identical preserved predecessor restored into a fresh destination. SelfTest PASS, when requested, proves predecessor executability only.'
}
$proofPath=Join-Path $EvidenceDirectory 'ROLLBACK_PREDECESSOR_QUALIFICATION.json'
$proof | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $proofPath -Encoding UTF8

if ($SelfTest -and $selftestStatus -ne 'PASS') {
  throw ('ROLLBACK_PREDECESSOR_SELFTEST_FAILED:'+ $selftestExit)
}
Write-Host ('ROLLBACK_RESTORE_PASS version={0} size={1} sha256={2} selftest={3}' -f $manifest.version,$size,$sha,$selftestStatus)
Write-Host ('Rollback destination: ' + $Destination)
Write-Host ('Rollback evidence: ' + $EvidenceDirectory)
