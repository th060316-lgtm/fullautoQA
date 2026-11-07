# Rebuild and restore the last verified predecessor Candidate into a fresh
# directory.  The raw donor is only a build substrate; it is not itself the
# predecessor Candidate.
#
# The predecessor Source and acceptance bundle are preserved under this
# rollback directory as exact historical Git blobs.  This script validates
# every snapshot blob, validates the recovery archive and donor, rebuilds the
# historical source contract offline, extracts it freshly, validates package
# integrity, and optionally executes START_QA.cmd -SelfTest.
#
# A rebuilt ZIP is NOT assumed to be byte-identical to the historical ZIP.
# Historical byte identity is reported separately from functional rollback.
#
# ASCII-only invariant: this file must never contain a byte above 0x7F.
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
New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null

$ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $ps -PathType Leaf)) { throw 'WINDOWS_POWERSHELL_MISSING' }

function Get-GitBlobSha1([string]$Path) {
  $bytes=[IO.File]::ReadAllBytes($Path)
  $header=[Text.Encoding]::ASCII.GetBytes(('blob '+$bytes.Length+[char]0))
  $sha1=[Security.Cryptography.SHA1]::Create()
  try {
    [void]$sha1.TransformBlock($header,0,$header.Length,$header,0)
    [void]$sha1.TransformFinalBlock($bytes,0,$bytes.Length)
    return ([BitConverter]::ToString($sha1.Hash)).Replace('-','').ToLowerInvariant()
  } finally {
    $sha1.Dispose()
  }
}

function Copy-Tree([string]$Source,[string]$Target) {
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw ('ROLLBACK_COPY_SOURCE_MISSING:'+$Source)
  }
  New-Item -ItemType Directory -Path $Target -Force | Out-Null
  $robocopy=Join-Path $env:SystemRoot 'System32\robocopy.exe'
  if (Test-Path -LiteralPath $robocopy -PathType Leaf) {
    & $robocopy $Source $Target /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ('ROLLBACK_ROBOCOPY_FAILED:'+$LASTEXITCODE) }
  } else {
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $Target -Recurse -Force
    }
  }
}

function Find-RecoveredSourceRoot([string]$Root) {
  $matches=@(Get-ChildItem -LiteralPath $Root -Recurse -Filter 'test_core.py' |
    Where-Object { $_.Directory.Name -eq 'TESTS' })
  if ($matches.Count -ne 1) { throw ('ROLLBACK_SOURCE_ROOT_AMBIGUOUS:'+$matches.Count) }
  return $matches[0].Directory.Parent.FullName
}

function Test-PredecessorSnapshot([string]$SnapshotRoot,$Manifest) {
  if (-not $Manifest.snapshot -or -not $Manifest.snapshot.files) {
    throw 'ROLLBACK_SNAPSHOT_FILE_MANIFEST_MISSING'
  }
  $expected=@($Manifest.snapshot.files)
  $actual=@(Get-ChildItem -LiteralPath $SnapshotRoot -Recurse -File)
  if ($actual.Count -ne [int]$Manifest.snapshot.file_count -or
      $expected.Count -ne [int]$Manifest.snapshot.file_count) {
    throw ('ROLLBACK_SNAPSHOT_FILE_COUNT_MISMATCH:expected='+$Manifest.snapshot.file_count+
      ':manifest='+$expected.Count+':actual='+$actual.Count)
  }
  $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in $expected) {
    $relative=([string]$entry.path).Replace('/',[IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
      throw ('ROLLBACK_SNAPSHOT_PATH_INVALID:'+[string]$entry.path)
    }
    $full=[IO.Path]::GetFullPath((Join-Path $SnapshotRoot $relative))
    $prefix=[IO.Path]::GetFullPath($SnapshotRoot).TrimEnd('\')+'\'
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
      throw ('ROLLBACK_SNAPSHOT_PATH_ESCAPE:'+[string]$entry.path)
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
      throw ('ROLLBACK_SNAPSHOT_FILE_MISSING:'+[string]$entry.path)
    }
    if ((Get-Item -LiteralPath $full).Length -ne [long]$entry.size) {
      throw ('ROLLBACK_SNAPSHOT_SIZE_MISMATCH:'+[string]$entry.path)
    }
    $blob=Get-GitBlobSha1 $full
    if ($blob -ne ([string]$entry.git_blob_sha1).ToLowerInvariant()) {
      throw ('ROLLBACK_SNAPSHOT_BLOB_MISMATCH:'+[string]$entry.path)
    }
    [void]$seen.Add(([string]$entry.path).Replace('\','/'))
  }
  foreach ($file in $actual) {
    $rel=$file.FullName.Substring(([IO.Path]::GetFullPath($SnapshotRoot)).Length).TrimStart('\').Replace('\','/')
    if (-not $seen.Contains($rel)) { throw ('ROLLBACK_SNAPSHOT_UNDECLARED_FILE:'+$rel) }
  }
  return 'PASS'
}

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

$sourceRootForEntry=Get-RepositorySourceRoot
$transferPath=Get-TransferManifestPath -SourceRoot $sourceRootForEntry
$transfer=Read-TransferManifest -ManifestPath $transferPath
$entries=Get-DeclaredRepositoryEntries -RepositoryRoot $RepositoryRoot -SourceRoot $sourceRootForEntry -Manifest $transfer
$entryProblems=@(Test-DeclaredRepositoryEntries -Entries $entries)
if ($entryProblems.Count -gt 0) {
  throw ('ROLLBACK_DECLARED_ENTRY_INVALID:'+($entryProblems -join ','))
}

$predecessorRoot=Join-Path $ScriptDirectory 'predecessor_23e0f380'
$predecessorManifestPath=Join-Path $predecessorRoot 'manifest.json'
$snapshotRoot=Join-Path $predecessorRoot 'snapshot'
$snapshotSource=Join-Path $snapshotRoot 'source'
$snapshotAcceptance=Join-Path $snapshotRoot 'acceptance_targets'
foreach ($required in @($predecessorManifestPath,$snapshotSource,$snapshotAcceptance)) {
  if (-not (Test-Path -LiteralPath $required)) { throw ('ROLLBACK_PREDECESSOR_SNAPSHOT_MISSING:'+$required) }
}
$predecessorManifest=Get-Content -LiteralPath $predecessorManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$predecessorManifest.predecessor.source_commit -ne '23e0f3809ecb0da2ab68d62ffee443c68e68e408') {
  throw 'ROLLBACK_PREDECESSOR_SOURCE_COMMIT_UNEXPECTED'
}
$snapshotStatus=Test-PredecessorSnapshot -SnapshotRoot $snapshotRoot -Manifest $predecessorManifest

$recovery=[string]$entries.recovery_source
if (-not (Test-Path -LiteralPath $recovery -PathType Leaf)) { throw 'ROLLBACK_RECOVERY_SOURCE_MISSING' }
$recoverySha=Get-Sha256File $recovery
if ($recoverySha -ne ([string]$entries.recovery_source_sha256).ToLowerInvariant() -or
    $recoverySha -ne ([string]$predecessorManifest.recovery_source.sha256).ToLowerInvariant()) {
  throw 'ROLLBACK_RECOVERY_SOURCE_SHA_MISMATCH'
}

if ([string]::IsNullOrWhiteSpace($PredecessorSet)) {
  $donorSetRoot=[string]$entries.donor_root
} else {
  $donorSetRoot=[IO.Path]::GetFullPath($PredecessorSet)
}
$donorManifestPath=Join-Path $donorSetRoot 'manifest.json'
$donorJoinPath=Join-Path $donorSetRoot 'JOIN_COMPLETE.ps1'
if (-not (Test-Path -LiteralPath $donorManifestPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $donorJoinPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $donorSetRoot 'blocks') -PathType Container)) {
  throw 'ROLLBACK_DONOR_SET_INVALID'
}
$donorManifest=Get-Content -LiteralPath $donorManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
& $ps -NoLogo -NoProfile -ExecutionPolicy Bypass -File $donorJoinPath
if ($LASTEXITCODE -ne 0) { throw ('ROLLBACK_DONOR_JOIN_FAILED:'+$LASTEXITCODE) }
$donorArchive=Join-Path $donorSetRoot ([string]$donorManifest.file)
if (-not (Test-Path -LiteralPath $donorArchive -PathType Leaf)) { throw 'ROLLBACK_DONOR_ARCHIVE_MISSING' }
$donorSize=(Get-Item -LiteralPath $donorArchive).Length
$donorSha=Get-Sha256File $donorArchive
if ($donorSize -ne [long]$donorManifest.size -or
    $donorSha -ne ([string]$donorManifest.sha256).ToLowerInvariant() -or
    $donorSize -ne [long]$predecessorManifest.donor.size -or
    $donorSha -ne ([string]$predecessorManifest.donor.sha256).ToLowerInvariant()) {
  throw 'ROLLBACK_DONOR_IDENTITY_MISMATCH'
}

$workRoot=$Destination+'_rollback_work'
if (Test-Path -LiteralPath $workRoot) { throw 'ROLLBACK_WORK_ROOT_MUST_BE_FRESH' }
New-Item -ItemType Directory -Path $workRoot | Out-Null
$rebuiltCandidate=$null
$rebuiltSize=$null
$rebuiltSha=$null
$historicalByteIdentity='NOT_EVALUATED'
$packageIntegrity='NOT_RUN'
$selftestStatus='NOT_RUN'
$selftestExit=$null
$resultZip=$null
$diagnosticReadback=$null
$diagnosticReadbackError=$null
$workCleanup='NOT_RUN'

try {
  $recoveryExtract=Join-Path $workRoot 'recovery'
  [IO.Compression.ZipFile]::ExtractToDirectory($recovery,$recoveryExtract)
  $historicalSource=Find-RecoveredSourceRoot $recoveryExtract
  Copy-Tree -Source $snapshotSource -Target $historicalSource
  Get-ChildItem -LiteralPath $historicalSource -Directory -Recurse -Filter '__pycache__' |
    Remove-Item -Recurse -Force

  $acceptanceTarget=Join-Path $historicalSource 'ACCEPTANCE'
  if (Test-Path -LiteralPath $acceptanceTarget) {
    Remove-Item -LiteralPath $acceptanceTarget -Recurse -Force
  }
  Copy-Tree -Source $snapshotAcceptance -Target $acceptanceTarget

  $builder=Join-Path $historicalSource 'scripts/PHASE3_OVERLAY_REBUILD.ps1'
  if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) { throw 'ROLLBACK_HISTORICAL_BUILDER_MISSING' }
  $buildOut=Join-Path $workRoot 'build'
  New-Item -ItemType Directory -Path $buildOut | Out-Null
  $buildLog=Join-Path $EvidenceDirectory 'ROLLBACK_PREDECESSOR_REBUILD.log'
  & $ps -NoLogo -NoProfile -ExecutionPolicy Bypass -File $builder -DonorArchive $donorArchive -SourceRoot $historicalSource -OutputDir $buildOut -SourceBaseline ([string]$predecessorManifest.predecessor.source_commit) *>&1 |
    Tee-Object -FilePath $buildLog
  $buildExit=$LASTEXITCODE
  if ($buildExit -ne 0) { throw ('ROLLBACK_PREDECESSOR_REBUILD_FAILED:'+$buildExit) }

  $rebuiltCandidate=Join-Path $buildOut 'FullAutoQA_PHASE3_CANDIDATE.zip'
  $rebuiltIdentity=Join-Path $buildOut 'PHASE3_CANDIDATE_IDENTITY.json'
  if (-not (Test-Path -LiteralPath $rebuiltCandidate -PathType Leaf) -or
      -not (Test-Path -LiteralPath $rebuiltIdentity -PathType Leaf)) {
    throw 'ROLLBACK_REBUILT_CANDIDATE_MISSING'
  }
  $rebuiltId=Get-Content -LiteralPath $rebuiltIdentity -Raw -Encoding UTF8 | ConvertFrom-Json
  $rebuiltSize=(Get-Item -LiteralPath $rebuiltCandidate).Length
  $rebuiltSha=Get-Sha256File $rebuiltCandidate
  if ($rebuiltSize -ne [long]$rebuiltId.candidate_size -or
      $rebuiltSha -ne ([string]$rebuiltId.candidate_sha256).ToLowerInvariant()) {
    throw 'ROLLBACK_REBUILT_CANDIDATE_IDENTITY_MISMATCH'
  }
  $historicalExpectedSize=[long]$predecessorManifest.predecessor.verified_candidate.size
  $historicalExpectedSha=([string]$predecessorManifest.predecessor.verified_candidate.sha256).ToLowerInvariant()
  $historicalByteIdentity=$(if ($rebuiltSize -eq $historicalExpectedSize -and $rebuiltSha -eq $historicalExpectedSha) {
    'PASS'
  } else {
    'NOT_IDENTICAL_REBUILD'
  })

  [IO.Compression.ZipFile]::ExtractToDirectory($rebuiltCandidate,$Destination)
  $startQa=Join-Path $Destination 'START_QA.cmd'
  if (-not (Test-Path -LiteralPath $startQa -PathType Leaf)) { throw 'ROLLBACK_START_QA_MISSING' }
  $freshPython=Join-Path $Destination 'RUNTIME/python/python.exe'
  $freshIntegrity=Join-Path $Destination 'scripts/package_integrity.py'
  if (-not (Test-Path -LiteralPath $freshPython -PathType Leaf) -or
      -not (Test-Path -LiteralPath $freshIntegrity -PathType Leaf)) {
    throw 'ROLLBACK_FRESH_INTEGRITY_TOOL_MISSING'
  }
  $integrityLog=Join-Path $EvidenceDirectory 'ROLLBACK_PREDECESSOR_PACKAGE_INTEGRITY.log'
  & $freshPython -B -E -s $freshIntegrity --root $Destination --full-payload --require-fresh-marker *>&1 |
    Tee-Object -FilePath $integrityLog
  if ($LASTEXITCODE -ne 0) { throw ('ROLLBACK_FRESH_PACKAGE_INTEGRITY_FAILED:'+$LASTEXITCODE) }
  $packageIntegrity='PASS'

  Remove-Item -LiteralPath $workRoot -Recurse -Force
  $workCleanup='REMOVED'

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
    schema_version=3
    predecessor_source_commit=[string]$predecessorManifest.predecessor.source_commit
    predecessor_source_tree=[string]$predecessorManifest.predecessor.source_tree
    predecessor_acceptance_tree=[string]$predecessorManifest.predecessor.acceptance_tree
    snapshot_file_count=[int]$predecessorManifest.snapshot.file_count
    snapshot_git_blob_identity=$snapshotStatus
    recovery_source_sha256=$recoverySha
    donor_archive=[string]$donorManifest.file
    donor_size=[long]$donorSize
    donor_sha256=$donorSha
    donor_byte_identity='PASS'
    historical_candidate_size=[long]$predecessorManifest.predecessor.verified_candidate.size
    historical_candidate_sha256=[string]$predecessorManifest.predecessor.verified_candidate.sha256
    historical_candidate_build_run=[long]$predecessorManifest.predecessor.verified_candidate.build_run
    rebuilt_candidate_size=[long]$rebuiltSize
    rebuilt_candidate_sha256=$rebuiltSha
    historical_candidate_byte_identity=$historicalByteIdentity
    fresh_destination=$Destination
    package_integrity=$packageIntegrity
    selftest_requested=[bool]$SelfTest
    selftest_status=$selftestStatus
    selftest_exit_code=$selftestExit
    result_zip=$resultZip
    diagnostic_readback=$diagnosticReadback
    diagnostic_readback_error=$diagnosticReadbackError
    work_cleanup=$workCleanup
    runnable_rollback_status=$(if($SelfTest){$selftestStatus}else{'RESTORED_NOT_EXECUTED'})
    product_acceptance='NOT_CLAIMED'
    stable_certification='NOT_CLAIMED'
    claim_scope='Functional predecessor rebuilt from exact historical Source/acceptance Git blobs on the byte-identical preserved donor. Rebuilt ZIP byte identity is reported separately and never inferred.'
  }
  $proofPath=Join-Path $EvidenceDirectory 'ROLLBACK_PREDECESSOR_QUALIFICATION.json'
  $proof | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $proofPath -Encoding UTF8

  if ($SelfTest -and $selftestStatus -ne 'PASS') {
    throw ('ROLLBACK_PREDECESSOR_SELFTEST_FAILED:'+$selftestExit)
  }
  Write-Host ('ROLLBACK_RESTORE_PASS source={0} rebuilt_size={1} rebuilt_sha256={2} historical_byte_identity={3} selftest={4}' -f
    $predecessorManifest.predecessor.source_commit,$rebuiltSize,$rebuiltSha,$historicalByteIdentity,$selftestStatus)
  Write-Host ('Rollback destination: '+$Destination)
  Write-Host ('Rollback evidence: '+$EvidenceDirectory)
} catch {
  $failure=[ordered]@{
    schema_version=3
    status='FAIL'
    error=$_.Exception.Message
    predecessor_source_commit=$(if($predecessorManifest){[string]$predecessorManifest.predecessor.source_commit}else{$null})
    snapshot_git_blob_identity=$snapshotStatus
    recovery_source_sha256=$recoverySha
    donor_sha256=$donorSha
    rebuilt_candidate_size=$rebuiltSize
    rebuilt_candidate_sha256=$rebuiltSha
    historical_candidate_byte_identity=$historicalByteIdentity
    package_integrity=$packageIntegrity
    selftest_status=$selftestStatus
    selftest_exit_code=$selftestExit
    result_zip=$resultZip
    diagnostic_readback=$diagnosticReadback
    product_acceptance='NOT_CLAIMED'
    stable_certification='NOT_CLAIMED'
  }
  $failure | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'ROLLBACK_PREDECESSOR_FAILURE.json') -Encoding UTF8
  throw
} finally {
  if (Test-Path -LiteralPath $workRoot) {
    try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop; $workCleanup='REMOVED' } catch {}
  }
}
