# Restore the preserved predecessor Candidate into a fresh directory.
# This proves byte-level rollback executability only; it does not promote the
# predecessor to Product Accepted / Stable or claim current-version QA.
#
# ASCII-only invariant: this file must never contain a byte above 0x7F.
# The predecessor set is resolved through the shared entry contract in
# ../source/scripts/REPOSITORY_ENTRY.ps1 so that the non-ASCII source-root
# name is never written into a script that Windows PowerShell 5.1 executes.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Destination,
  [string]$RepositoryRoot='',
  [string]$PredecessorSet='',
  [string]$EvidenceDirectory='',
  [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Captured before the shared contract is dot-sourced: dot-sourcing assigns the
# dot-sourced script's own $PSScriptRoot into the caller's scope.
$ScriptDirectory=$PSScriptRoot
$RepositoryEntryModule=Join-Path (Split-Path -Parent $ScriptDirectory) 'source/scripts/REPOSITORY_ENTRY.ps1'
if (-not (Test-Path -LiteralPath $RepositoryEntryModule -PathType Leaf)) {
  throw ('REPOSITORY_ENTRY_MODULE_MISSING:'+$RepositoryEntryModule)
}
. $RepositoryEntryModule

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
  $RepositoryRoot=[IO.Path]::GetFullPath((Join-Path $ScriptDirectory '..\..'))
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

if ([string]::IsNullOrWhiteSpace($PredecessorSet)) {
  $transferPath=Get-TransferManifestPath -SourceRoot (Get-RepositorySourceRoot)
  if (-not (Test-Path -LiteralPath $transferPath -PathType Leaf)) {
    throw ('TRANSFER_MANIFEST_MISSING:'+$transferPath)
  }
  $transfer=Read-TransferManifest -ManifestPath $transferPath
  if (-not $transfer.latest_complete_candidate -or [string]::IsNullOrWhiteSpace([string]$transfer.latest_complete_candidate.path)) {
    throw 'ROLLBACK_PREDECESSOR_DECLARATION_MISSING'
  }
  $setRoot=Resolve-RepositoryRelativePath -Root $RepositoryRoot -Relative ([string]$transfer.latest_complete_candidate.path)
} else {
  $setRoot=[IO.Path]::GetFullPath($PredecessorSet)
}
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
$sha=Get-Sha256File $archive
if ($size -ne [long]$manifest.size) { throw 'ROLLBACK_PREDECESSOR_SIZE_MISMATCH' }
if ($sha -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw 'ROLLBACK_PREDECESSOR_SHA_MISMATCH' }

New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory($archive,$Destination)
$startQa=Join-Path $Destination 'START_QA.cmd'
if (-not (Test-Path -LiteralPath $startQa -PathType Leaf)) { throw 'ROLLBACK_START_QA_MISSING' }

function Export-ResultDiagnosticReadback([string]$ResultZipPath,[string]$EvidenceRoot) {
  if ([string]::IsNullOrWhiteSpace($ResultZipPath) -or
      -not (Test-Path -LiteralPath $ResultZipPath -PathType Leaf)) {
    return $null
  }
  $readbackRoot=Join-Path $EvidenceRoot 'result_readback'
  New-Item -ItemType Directory -Path $readbackRoot -Force | Out-Null
  $records=New-Object 'System.Collections.Generic.List[object]'
  $archiveHandle=$null
  $total=[long]0
  $maxEntry=[long](5*1024*1024)
  $maxTotal=[long](50*1024*1024)
  try {
    $archiveHandle=[IO.Compression.ZipFile]::OpenRead($ResultZipPath)
    $index=0
    foreach ($entry in @($archiveHandle.Entries | Sort-Object FullName)) {
      if ([string]::IsNullOrWhiteSpace($entry.Name)) { continue }
      $extension=[IO.Path]::GetExtension($entry.Name).ToLowerInvariant()
      if (@('.json','.txt','.log','.md','.csv','.yaml','.yml') -notcontains $extension) { continue }
      if ([long]$entry.Length -gt $maxEntry) { continue }
      if (($total+[long]$entry.Length) -gt $maxTotal) { continue }
      $index++
      $fileName=('{0:D4}{1}' -f $index,$extension)
      $target=Join-Path $readbackRoot $fileName
      $input=$null
      $output=$null
      try {
        $input=$entry.Open()
        $output=[IO.File]::Create($target)
        $input.CopyTo($output)
      } finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
      }
      $total += [long]$entry.Length
      $records.Add([ordered]@{
        entry=[string]$entry.FullName
        file=$fileName
        size=[long]$entry.Length
      })
    }
    $indexDocument=[ordered]@{
      schema_version=1
      source_result_zip=[IO.Path]::GetFileName($ResultZipPath)
      extracted_count=$records.Count
      extracted_bytes=$total
      max_entry_bytes=$maxEntry
      max_total_bytes=$maxTotal
      entries=@($records)
    }
    $indexPath=Join-Path $readbackRoot 'INDEX.json'
    $indexDocument | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $indexPath -Encoding UTF8
    return $indexPath
  } finally {
    if ($archiveHandle) { $archiveHandle.Dispose() }
  }
}

$selftestStatus='NOT_RUN'
$selftestExit=$null
$resultZip=$null
$diagnosticReadback=$null
$diagnosticReadbackError=$null
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
  if ($new.Count -ge 1) {
    $resultZipFull=$new[0].FullName
    $resultZip=$resultZipFull.Substring($Destination.Length).TrimStart('\').Replace('\','/')
    try {
      $diagnosticReadback=Export-ResultDiagnosticReadback -ResultZipPath $resultZipFull -EvidenceRoot $EvidenceDirectory
      if ($diagnosticReadback) {
        $diagnosticReadback=$diagnosticReadback.Substring($EvidenceDirectory.Length).TrimStart('\').Replace('\','/')
      }
    } catch {
      $diagnosticReadbackError=$_.Exception.GetType().Name
      Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'ROLLBACK_DIAGNOSTIC_EXPORT_ERROR.txt') -Value $diagnosticReadbackError -Encoding ASCII
    }
  }
  if ($selftestExit -eq 0 -and $new.Count -ge 1) {
    $selftestStatus='PASS'
  } else {
    $selftestStatus='FAIL'
  }
}

$proof=[ordered]@{
  schema_version=2
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
  diagnostic_readback=$diagnosticReadback
  diagnostic_readback_error=$diagnosticReadbackError
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
