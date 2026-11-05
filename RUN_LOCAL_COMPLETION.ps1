# FullAutoQA local final-completion runner.
# Uses a temporary drive mapping so the user-selected download location does not become part of deep build paths.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$PhysicalRepoRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$RunTag = ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$SubstExe = Join-Path ([Environment]::GetFolderPath('System')) 'subst.exe'
$MappedDrive = $null
$RepoRoot = $PhysicalRepoRoot
$WorkRoot = $null
$OutRoot = $null
$SummaryPath = $null
$ExitCode = 1
$PathBefore = $null
$SelftestRoot = $null
$ControllerRoot = $null
$SeriesOut = $null
$BuildOut = $null

$Summary = [ordered]@{
  schema_version = 3
  run_tag = $RunTag
  status = 'STARTING'
  source_tree_fingerprint = $null
  purpose = 'Local Windows Candidate rebuild, selftest, Source regression and fresh A-B-A acceptance without GitHub Actions artifact transfer'
  physical_repository_root = $PhysicalRepoRoot
  logical_repository_root = $null
  workspace_drive = $null
  workspace_root = $null
  started_utc = [DateTime]::UtcNow.ToString('o')
  non_admin_session = $null
  network_snapshot = $null
  candidate = $null
  donor_join = 'NOT_RUN'
  candidate_build = 'NOT_RUN'
  candidate_integrity = 'NOT_RUN'
  source_regression = 'NOT_RUN'
  windows_selftest = 'NOT_RUN'
  aba_series = 'NOT_RUN'
  aba_result_zip_count = 0
  persistent_path_status = 'NOT_MEASURED'
  workspace_cleanup = 'NOT_RUN'
  offline_internet_status = 'USER_MUST_RUN_WITH_EXTERNAL_NETWORK_DISCONNECTED'
  human_test = 'NOT_RUN'
  product_acceptance = 'HOLD'
  stable = 'HOLD'
  evidence_root = $null
  chatgpt_evidence_file = 'CHATGPT_EVIDENCE.zip'
  error = $null
}

function Get-SHA256([string]$Path) {
  $stream = [IO.File]::OpenRead($Path)
  $hash = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
  finally { $hash.Dispose(); $stream.Dispose() }
}

function Write-Summary {
  if (-not $SummaryPath) { return }
  $Summary.updated_utc = [DateTime]::UtcNow.ToString('o')
  $Summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
}

function Get-PathSnapshot {
  $result = [ordered]@{}
  foreach ($row in @(
    @('user','HKCU:\Environment'),
    @('machine','HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
  )) {
    $label=$row[0]; $key=$row[1]
    try {
      $value=(Get-ItemProperty -LiteralPath $key -Name Path -ErrorAction Stop).Path
      $json=ConvertTo-Json $value -Compress
      $bytes=[Text.Encoding]::UTF8.GetBytes($json)
      $alg=[Security.Cryptography.SHA256]::Create()
      try { $digest=([BitConverter]::ToString($alg.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
      finally { $alg.Dispose() }
      $result[$label]=[ordered]@{status='MEASURED';sha256=$digest}
    } catch {
      $result[$label]=[ordered]@{status='NOT_MEASURED';reason=$_.Exception.Message}
    }
  }
  return $result
}

function Get-NetworkSnapshot {
  try {
    $rows = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | Select-Object Name,InterfaceDescription,Status,LinkSpeed)
    return [ordered]@{
      status='OBSERVED_ONLY_NOT_INTERNET_PROOF'
      up_adapter_count=$rows.Count
      up_adapters=$rows
    }
  } catch {
    return [ordered]@{status='NOT_MEASURED';reason=$_.Exception.Message}
  }
}

function New-RepoDrive([string]$Root) {
  if (-not (Test-Path -LiteralPath $SubstExe -PathType Leaf)) { throw 'SUBST_TOOL_MISSING' }
  foreach ($code in 90..68) {
    $letter=[char]$code
    $name=[string]$letter
    if (Get-PSDrive -Name $name -PSProvider FileSystem -ErrorAction SilentlyContinue) { continue }
    $drive=($name + ':')
    & $SubstExe $drive $Root | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath ($drive + '\') -PathType Container)) {
      return $drive
    }
    & $SubstExe $drive /D 2>$null | Out-Null
  }
  throw 'NO_TEMPORARY_WORK_DRIVE_AVAILABLE'
}

function Remove-RepoDrive([string]$Drive) {
  if (-not $Drive) { return $true }
  & $SubstExe $Drive /D 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Find-RepositoryFile([string]$Root,[string]$Name,[string[]]$RequiredSiblings=@()) {
  $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  $prefix=$rootFull+[IO.Path]::DirectorySeparatorChar
  $matches=New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
  foreach ($item in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Filter $Name -ErrorAction Stop)) {
    $relative=$item.FullName.Substring($prefix.Length)
    $top=$relative.Split([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)[0]
    if ($top -like 'LOCAL_FINAL_ACCEPTANCE_*' -or $top -like '.fqa_work_*' -or $top -eq '.git') { continue }
    $ok=$true
    foreach ($sibling in $RequiredSiblings) {
      if (-not (Test-Path -LiteralPath (Join-Path $item.Directory.FullName $sibling))) { $ok=$false; break }
    }
    if ($ok) { $matches.Add($item) }
  }
  if ($matches.Count -ne 1) { throw ('REPOSITORY_FILE_DISCOVERY_FAILED:'+ $Name +':'+ $matches.Count) }
  return $matches[0].FullName
}

function Get-TreeFingerprint([string]$Root) {
  $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  $prefix=$rootFull+[IO.Path]::DirectorySeparatorChar
  $rows=New-Object 'System.Collections.Generic.List[string]'
  foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File | Sort-Object FullName)) {
    $relative=$file.FullName.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,'/')
    $rows.Add(($relative + [char]9 + $file.Length + [char]9 + (Get-SHA256 $file.FullName)))
  }
  $bytes=[Text.Encoding]::UTF8.GetBytes(($rows -join [Environment]::NewLine))
  $alg=[Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($alg.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
  finally { $alg.Dispose() }
}

function Copy-TopLevelFiles([string]$Source,[string]$Destination,[switch]$SkipArchives) {
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  Get-ChildItem -LiteralPath $Source -File -Force | ForEach-Object {
    if ($SkipArchives -and $_.Extension -ieq '.zip') { return }
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Destination $_.Name) -Force
  }
}

function Zip-DirectoryIfPresent([string]$Source,[string]$ZipPath) {
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
  if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
  [IO.Compression.ZipFile]::CreateFromDirectory($Source,$ZipPath,[IO.Compression.CompressionLevel]::Optimal,$false)
}

function Export-TransientEvidence {
  if (-not $OutRoot) { return }

  if ($BuildOut -and (Test-Path -LiteralPath $BuildOut -PathType Container)) {
    Copy-TopLevelFiles $BuildOut (Join-Path $OutRoot 'candidate_build') -SkipArchives
  }

  if ($SelftestRoot) {
    $selfResults=Join-Path $SelftestRoot 'RESULTS'
    if (Test-Path -LiteralPath $selfResults -PathType Container) {
      Zip-DirectoryIfPresent $selfResults (Join-Path $OutRoot 'SELFTEST_RESULTS.zip')
    }
  }

  if ($SeriesOut -and (Test-Path -LiteralPath $SeriesOut -PathType Container)) {
    Zip-DirectoryIfPresent $SeriesOut (Join-Path $OutRoot 'ABA_EVIDENCE.zip')
    $resultZips=@(Get-ChildItem -LiteralPath $SeriesOut -Recurse -Filter 'RESULT_FOR_CHATGPT.zip' -File | Sort-Object FullName)
    $i=0
    foreach ($item in $resultZips) {
      $i++
      Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $OutRoot ('Run'+$i+'_RESULT_FOR_CHATGPT.zip')) -Force
    }
  }
}

function Export-ChatEvidence {
  if (-not $OutRoot -or -not (Test-Path -LiteralPath $OutRoot -PathType Container)) { return }

  $stage=Join-Path $OutRoot '.chat_evidence_stage'
  $zip=Join-Path $OutRoot 'CHATGPT_EVIDENCE.zip'
  $identity=Join-Path $OutRoot 'CHATGPT_EVIDENCE_IDENTITY.json'
  if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
  New-Item -ItemType Directory -Path $stage -Force | Out-Null

  foreach ($name in @(
    'LOCAL_COMPLETION_SUMMARY.json',
    'DONOR_JOIN.log',
    'CANDIDATE_BUILD.log',
    'BUNDLED_SOURCE_TESTS.log',
    'START_QA_SELFTEST.log',
    'ABA_SERIES.log'
  )) {
    $source=Join-Path $OutRoot $name
    if (Test-Path -LiteralPath $source -PathType Leaf) {
      Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name) -Force
    }
  }

  $candidateMetadata=Join-Path $OutRoot 'candidate_build'
  if (Test-Path -LiteralPath $candidateMetadata -PathType Container) {
    $candidateStage=Join-Path $stage 'candidate_build'
    New-Item -ItemType Directory -Path $candidateStage -Force | Out-Null
    Get-ChildItem -LiteralPath $candidateMetadata -File -Force | Where-Object { $_.Extension -ine '.zip' } | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $candidateStage $_.Name) -Force
    }
  }

  if ($SeriesOut -and (Test-Path -LiteralPath $SeriesOut -PathType Container)) {
    $seriesStage=Join-Path $stage 'series'
    New-Item -ItemType Directory -Path $seriesStage -Force | Out-Null
    foreach ($name in @('SERIES_COMPARISON.json','PERSISTENT_ENVIRONMENT_READBACK.json','OPERATION_LOG.json')) {
      $source=Join-Path $SeriesOut $name
      if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $seriesStage $name) -Force
      }
    }
  }

  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
  Remove-Item -LiteralPath $stage -Recurse -Force

  $chatIdentity=[ordered]@{
    file=[IO.Path]::GetFileName($zip)
    size=(Get-Item -LiteralPath $zip).Length
    sha256=Get-SHA256 $zip
    candidate_file=if ($Summary.candidate) {$Summary.candidate.file} else {$null}
    candidate_size=if ($Summary.candidate) {$Summary.candidate.size} else {$null}
    candidate_sha256=if ($Summary.candidate) {$Summary.candidate.sha256} else {$null}
  }
  $chatIdentity | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $identity -Encoding UTF8
}

try {
  if ($env:OS -ne 'Windows_NT') { throw 'LOCAL_COMPLETION_REQUIRES_WINDOWS' }

  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $Summary.non_admin_session = -not $isAdmin
  if ($isAdmin) { throw 'RUN_FROM_A_STANDARD_NON_ADMIN_WINDOWS_SESSION' }

  $MappedDrive = New-RepoDrive $PhysicalRepoRoot
  $RepoRoot = ($MappedDrive + '\')
  $WorkRoot = Join-Path $RepoRoot ('.fqa_work_' + $RunTag)
  $OutRoot = Join-Path $RepoRoot ('LOCAL_FINAL_ACCEPTANCE_' + $RunTag)
  New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null
  $SummaryPath = Join-Path $OutRoot 'LOCAL_COMPLETION_SUMMARY.json'
  $Summary.logical_repository_root = $RepoRoot
  $Summary.workspace_drive = $MappedDrive
  $Summary.workspace_root = $WorkRoot
  $Summary.evidence_root = $OutRoot
  $Summary.status = 'RUNNING'

  $Summary.network_snapshot = Get-NetworkSnapshot
  $PathBefore = Get-PathSnapshot
  Write-Summary

  Write-Host '=== 1/6 Reconstruct preserved v0.3.3 donor ==='
  $join = Find-RepositoryFile -Root $RepoRoot -Name 'JOIN_COMPLETE.ps1' -RequiredSiblings @('manifest.json','blocks')
  $complete = Split-Path -Parent $join
  & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File $join 2>&1 |
    Tee-Object -FilePath (Join-Path $OutRoot 'DONOR_JOIN.log')
  if ($LASTEXITCODE -ne 0) { throw ('DONOR_JOIN_FAILED:' + $LASTEXITCODE) }
  $manifest = Get-Content -LiteralPath (Join-Path $complete 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $donor = Join-Path $complete ([string]$manifest.file)
  if (-not (Test-Path -LiteralPath $donor -PathType Leaf)) { throw 'DONOR_ARCHIVE_MISSING_AFTER_JOIN' }
  if ((Get-Item -LiteralPath $donor).Length -ne [long]$manifest.size -or (Get-SHA256 $donor) -ne ([string]$manifest.sha256).ToLowerInvariant()) {
    throw 'DONOR_IDENTITY_MISMATCH_AFTER_JOIN'
  }
  $Summary.donor_join='PASS'
  Write-Summary

  Write-Host '=== 2/6 Reconstruct current Source and build Candidate ==='
  $sourceDestination = Join-Path $WorkRoot 'prepared'
  $prepare = Find-RepositoryFile -Root $RepoRoot -Name 'PREPARE_SOURCE.ps1' -RequiredSiblings @('PHASE3_OVERLAY_REBUILD.ps1')
  $checkedOutSourceRoot = Split-Path -Parent (Split-Path -Parent $prepare)
  if (-not (Test-Path -LiteralPath (Join-Path $checkedOutSourceRoot 'CORE') -PathType Container)) { throw 'CHECKED_OUT_SOURCE_ROOT_INVALID' }
  $Summary.source_tree_fingerprint = Get-TreeFingerprint $checkedOutSourceRoot
  Write-Summary
  $sourceRoot = & $prepare -RepositoryRoot $RepoRoot -Destination $sourceDestination
  if (-not $sourceRoot -or -not (Test-Path -LiteralPath (Join-Path $sourceRoot 'CORE') -PathType Container)) {
    throw 'PREPARED_SOURCE_ROOT_INVALID'
  }

  $plan = Find-RepositoryFile -Root $RepoRoot -Name 'FINAL_SERIES_PLAN.json' -RequiredSiblings @('run_series.py','RUN_FINAL_ACCEPTANCE.cmd')
  $acceptanceSource = Split-Path -Parent $plan
  $acceptanceDest = Join-Path $sourceRoot 'ACCEPTANCE'
  if (Test-Path -LiteralPath $acceptanceDest) { Remove-Item -LiteralPath $acceptanceDest -Recurse -Force }
  Copy-Item -LiteralPath $acceptanceSource -Destination $acceptanceDest -Recurse -Force

  $BuildOut = Join-Path $WorkRoot 'build'
  New-Item -ItemType Directory -Path $BuildOut -Force | Out-Null
  $rebuild = Join-Path $sourceRoot 'scripts\PHASE3_OVERLAY_REBUILD.ps1'
  $buildArgs = @(
    '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$rebuild,
    '-DonorArchive',$donor,'-SourceRoot',$sourceRoot,'-OutputDir',$BuildOut,
    '-SourceBaseline',$Summary.source_tree_fingerprint
  )
  & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @buildArgs 2>&1 |
    Tee-Object -FilePath (Join-Path $OutRoot 'CANDIDATE_BUILD.log')
  if ($LASTEXITCODE -ne 0) { throw ('CANDIDATE_BUILD_FAILED:' + $LASTEXITCODE) }
  $Summary.candidate_build='PASS'

  $identityPath = Join-Path $BuildOut 'PHASE3_CANDIDATE_IDENTITY.json'
  $identity = Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $candidate = Join-Path $BuildOut ([string]$identity.candidate_file)
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'CANDIDATE_FILE_MISSING' }
  $candidateSize=(Get-Item -LiteralPath $candidate).Length
  $candidateSha=Get-SHA256 $candidate
  if ($candidateSize -ne [long]$identity.candidate_size -or $candidateSha -ne ([string]$identity.candidate_sha256).ToLowerInvariant()) {
    throw 'CANDIDATE_IDENTITY_MISMATCH'
  }
  $Summary.candidate=[ordered]@{
    file=[IO.Path]::GetFileName($candidate)
    size=$candidateSize
    sha256=$candidateSha
  }
  $Summary.candidate_integrity='PASS'
  $candidateEvidenceDir=Join-Path $OutRoot 'candidate_build'
  New-Item -ItemType Directory -Path $candidateEvidenceDir -Force | Out-Null
  Copy-TopLevelFiles $BuildOut $candidateEvidenceDir -SkipArchives
  $persistedCandidate=Join-Path $candidateEvidenceDir ([IO.Path]::GetFileName($candidate))
  Move-Item -LiteralPath $candidate -Destination $persistedCandidate -Force
  $candidate=$persistedCandidate
  Write-Summary

  Write-Host '=== 3/6 Fresh Candidate Source regression ==='
  $SelftestRoot = Join-Path $WorkRoot 'selftest'
  [IO.Compression.ZipFile]::ExtractToDirectory($candidate,$SelftestRoot)
  $bundledPython = Join-Path $SelftestRoot 'RUNTIME\python\python.exe'
  if (-not (Test-Path -LiteralPath $bundledPython -PathType Leaf)) { throw 'BUNDLED_PYTHON_NOT_FOUND' }
  & $bundledPython -B -E -s -m unittest discover -s (Join-Path $SelftestRoot 'TESTS') -v 2>&1 |
    Tee-Object -FilePath (Join-Path $OutRoot 'BUNDLED_SOURCE_TESTS.log')
  $sourceTestCode=$LASTEXITCODE
  if ($sourceTestCode -ne 0) { throw ('BUNDLED_SOURCE_REGRESSION_FAILED:' + $sourceTestCode) }
  $Summary.source_regression='PASS'
  Write-Summary

  Write-Host '=== 4/6 Fresh Candidate START_QA selftest ==='
  Push-Location $SelftestRoot
  try {
    & cmd.exe /d /c 'START_QA.cmd -SelfTest' 2>&1 | Tee-Object -FilePath (Join-Path $OutRoot 'START_QA_SELFTEST.log')
    $selfCode=$LASTEXITCODE
  } finally { Pop-Location }
  Export-TransientEvidence
  if ($selfCode -ne 0) { throw ('WINDOWS_SELFTEST_FAILED:' + $selfCode) }
  $Summary.windows_selftest='PASS'
  Write-Summary

  Remove-Item -LiteralPath $SelftestRoot -Recurse -Force
  $SelftestRoot=$null

  Write-Host '=== 5/6 Fresh PoliticsTrasport -> codegeas -> PoliticsTrasport ==='
  $ControllerRoot = Join-Path $WorkRoot 'controller'
  [IO.Compression.ZipFile]::ExtractToDirectory($candidate,$ControllerRoot)
  $controllerPython = Join-Path $ControllerRoot 'RUNTIME\python\python.exe'
  $seriesScript = Join-Path $ControllerRoot 'ACCEPTANCE\run_series.py'
  $SeriesOut = Join-Path $WorkRoot 'series'
  & $controllerPython -B -E -s $seriesScript --candidate $candidate --expected-sha $candidateSha --output $SeriesOut 2>&1 |
    Tee-Object -FilePath (Join-Path $OutRoot 'ABA_SERIES.log')
  $seriesCode=$LASTEXITCODE
  Export-TransientEvidence
  if ($seriesCode -ne 0) { throw ('ABA_SERIES_FAILED:' + $seriesCode) }

  $comparisonPath=Join-Path $SeriesOut 'SERIES_COMPARISON.json'
  $comparison=Get-Content -LiteralPath $comparisonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($comparison.technical_series_status -ne 'PASS' -or [int]$comparison.final_runs_completed -ne 3) {
    throw 'ABA_SERIES_COMPARISON_NONPASS'
  }
  $resultZips=@(Get-ChildItem -LiteralPath $SeriesOut -Recurse -Filter 'RESULT_FOR_CHATGPT.zip' -File)
  if ($resultZips.Count -ne 3) { throw ('ABA_RESULT_ZIP_COUNT:' + $resultZips.Count) }
  $Summary.aba_series='PASS'
  $Summary.aba_result_zip_count=$resultZips.Count
  Write-Summary

  Write-Host '=== 6/6 Local environment readback ==='
  $PathAfter=Get-PathSnapshot
  $Summary.persistent_path_status = if ((ConvertTo-Json $PathBefore -Depth 8 -Compress) -eq (ConvertTo-Json $PathAfter -Depth 8 -Compress)) {'UNCHANGED'} else {'CHANGED_REQUIRES_REVIEW'}
  $Summary.status='TECHNICAL_LOCAL_ACCEPTANCE_PASS'
  $Summary.completed_utc=[DateTime]::UtcNow.ToString('o')
  Export-TransientEvidence
  Write-Summary
  $ExitCode=0

  Write-Host ''
  Write-Host 'LOCAL TECHNICAL ACCEPTANCE PASS'
  Write-Host ('Candidate SHA256: ' + $candidateSha)
  Write-Host ('Evidence root: ' + $OutRoot)
  Write-Host 'Offline internet use and Human/Product acceptance remain separate claims; do not mark them PASS unless actually performed.'
}
catch {
  $Summary.status='FAIL'
  $Summary.error=$_.Exception.Message
  $Summary.failed_utc=[DateTime]::UtcNow.ToString('o')
  try {
    Export-TransientEvidence
    if ($PathBefore) {
      $PathAfter=Get-PathSnapshot
      $Summary.persistent_path_status = if ((ConvertTo-Json $PathBefore -Depth 8 -Compress) -eq (ConvertTo-Json $PathAfter -Depth 8 -Compress)) {'UNCHANGED'} else {'CHANGED_REQUIRES_REVIEW'}
    }
  } catch {
    $Summary.evidence_export_error=$_.Exception.Message
  }
  Write-Summary
  [Console]::Error.WriteLine('LOCAL_COMPLETION_FAILED: ' + $_.Exception.Message)
  if ($OutRoot) { [Console]::Error.WriteLine('Preserve evidence at: ' + $OutRoot) }
  $ExitCode=1
}
finally {
  try {
    if ($ControllerRoot -and (Test-Path -LiteralPath $ControllerRoot)) {
      Remove-Item -LiteralPath $ControllerRoot -Recurse -Force -ErrorAction Stop
    }
    if ($SelftestRoot -and (Test-Path -LiteralPath $SelftestRoot)) {
      Remove-Item -LiteralPath $SelftestRoot -Recurse -Force -ErrorAction Stop
    }
    if ($WorkRoot -and (Test-Path -LiteralPath $WorkRoot)) {
      Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction Stop
    }
    $Summary.workspace_cleanup='WORKSPACE_REMOVED'
  } catch {
    $Summary.workspace_cleanup=('WORKSPACE_RETAINED:' + $_.Exception.Message)
  }

  if ($SummaryPath) {
    try {
      Write-Summary
      Export-ChatEvidence
    } catch {
      [Console]::Error.WriteLine('WARNING: compact evidence export failed: ' + $_.Exception.Message)
    }
  }

  if ($MappedDrive) {
    $removed=Remove-RepoDrive $MappedDrive
    if (-not $removed) {
      [Console]::Error.WriteLine('WARNING: temporary drive mapping cleanup failed for ' + $MappedDrive)
    }
  }
}

exit $ExitCode
