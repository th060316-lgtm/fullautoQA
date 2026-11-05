# FullAutoQA local final-completion runner.
# Removes GitHub Actions artifact storage from the completion path.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$RunTag = ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$OutRoot = Join-Path $RepoRoot ('LOCAL_FINAL_ACCEPTANCE_' + $RunTag)
New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null
$SummaryPath = Join-Path $OutRoot 'LOCAL_COMPLETION_SUMMARY.json'
$Summary = [ordered]@{
  schema_version = 1
  run_tag = $RunTag
  status = 'RUNNING'
  frozen_source_commit = '2c8d4eed3a45736e1f59fdf29b2804a8b05fdf77'
  purpose = 'Local Windows Candidate rebuild, selftest, Source regression and fresh A-B-A acceptance without GitHub Actions artifact transfer'
  repository_root = $RepoRoot
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
  offline_internet_status = 'USER_MUST_RUN_WITH_EXTERNAL_NETWORK_DISCONNECTED'
  human_test = 'NOT_RUN'
  product_acceptance = 'HOLD'
  stable = 'HOLD'
  evidence_root = $OutRoot
  error = $null
}

function Write-Summary {
  $Summary.updated_utc = [DateTime]::UtcNow.ToString('o')
  $Summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
}

function Get-SHA256([string]$Path) {
  $stream = [IO.File]::OpenRead($Path)
  $hash = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
  finally { $hash.Dispose(); $stream.Dispose() }
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

$PathBefore = $null
$SelftestRoot = $null
$ControllerRoot = $null

try {
  if ($env:OS -ne 'Windows_NT') { throw 'LOCAL_COMPLETION_REQUIRES_WINDOWS' }

  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $Summary.non_admin_session = -not $isAdmin
  if ($isAdmin) { throw 'RUN_FROM_A_STANDARD_NON_ADMIN_WINDOWS_SESSION' }

  $Summary.network_snapshot = Get-NetworkSnapshot
  $PathBefore = Get-PathSnapshot
  Write-Summary

  Write-Host '=== 1/6 Reconstruct preserved v0.3.3 donor ==='
  $complete = Join-Path $RepoRoot '開発版\complete_v033'
  $join = Join-Path $complete 'JOIN_COMPLETE.ps1'
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
  $sourceDestination = Join-Path $OutRoot '_prepared_source'
  $prepare = Join-Path $RepoRoot '開発版\source\scripts\PREPARE_SOURCE.ps1'
  $sourceRoot = & $prepare -RepositoryRoot $RepoRoot -Destination $sourceDestination
  if (-not $sourceRoot -or -not (Test-Path -LiteralPath (Join-Path $sourceRoot 'CORE') -PathType Container)) {
    throw 'PREPARED_SOURCE_ROOT_INVALID'
  }

  $acceptanceSource = Join-Path $RepoRoot '開発版\acceptance_targets'
  $acceptanceDest = Join-Path $sourceRoot 'ACCEPTANCE'
  if (Test-Path -LiteralPath $acceptanceDest) { Remove-Item -LiteralPath $acceptanceDest -Recurse -Force }
  Copy-Item -LiteralPath $acceptanceSource -Destination $acceptanceDest -Recurse -Force

  $buildOut = Join-Path $OutRoot 'candidate_build'
  New-Item -ItemType Directory -Path $buildOut -Force | Out-Null
  $rebuild = Join-Path $sourceRoot 'scripts\PHASE3_OVERLAY_REBUILD.ps1'
  $buildArgs = @(
    '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$rebuild,
    '-DonorArchive',$donor,'-SourceRoot',$sourceRoot,'-OutputDir',$buildOut,
    '-SourceBaseline',$Summary.frozen_source_commit
  )
  & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @buildArgs 2>&1 |
    Tee-Object -FilePath (Join-Path $OutRoot 'CANDIDATE_BUILD.log')
  if ($LASTEXITCODE -ne 0) { throw ('CANDIDATE_BUILD_FAILED:' + $LASTEXITCODE) }
  $Summary.candidate_build='PASS'

  $identityPath = Join-Path $buildOut 'PHASE3_CANDIDATE_IDENTITY.json'
  $identity = Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $candidate = Join-Path $buildOut ([string]$identity.candidate_file)
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'CANDIDATE_FILE_MISSING' }
  $candidateSize=(Get-Item -LiteralPath $candidate).Length
  $candidateSha=Get-SHA256 $candidate
  if ($candidateSize -ne [long]$identity.candidate_size -or $candidateSha -ne ([string]$identity.candidate_sha256).ToLowerInvariant()) {
    throw 'CANDIDATE_IDENTITY_MISMATCH'
  }
  $Summary.candidate=[ordered]@{file=$candidate;size=$candidateSize;sha256=$candidateSha;identity_file=$identityPath}
  $Summary.candidate_integrity='PASS'
  Write-Summary

  Write-Host '=== 3/6 Fresh Candidate Source regression ==='
  $SelftestRoot = Join-Path $OutRoot '_fresh_selftest'
  [IO.Compression.ZipFile]::ExtractToDirectory($candidate,$SelftestRoot)
  $bundledPython = Join-Path $SelftestRoot 'RUNTIME\python\python.exe'
  & $bundledPython -B -E -s -m unittest discover -s (Join-Path $SelftestRoot 'TESTS') -v 2>&1 |
    Tee-Object -FilePath (Join-Path $OutRoot 'BUNDLED_SOURCE_TESTS.log')
  if ($LASTEXITCODE -ne 0) { throw ('BUNDLED_SOURCE_REGRESSION_FAILED:' + $LASTEXITCODE) }
  $Summary.source_regression='PASS'
  Write-Summary

  Write-Host '=== 4/6 Fresh Candidate START_QA selftest ==='
  Push-Location $SelftestRoot
  try {
    & cmd.exe /d /c 'START_QA.cmd -SelfTest' 2>&1 | Tee-Object -FilePath (Join-Path $OutRoot 'START_QA_SELFTEST.log')
    $selfCode=$LASTEXITCODE
  } finally { Pop-Location }
  if ($selfCode -ne 0) { throw ('WINDOWS_SELFTEST_FAILED:' + $selfCode) }
  $Summary.windows_selftest='PASS'
  Write-Summary

  $selfResults = Join-Path $SelftestRoot 'RESULTS'
  if (Test-Path -LiteralPath $selfResults) {
    Copy-Item -LiteralPath $selfResults -Destination (Join-Path $OutRoot 'SELFTEST_RESULTS') -Recurse -Force
  }
  Remove-Item -LiteralPath $SelftestRoot -Recurse -Force
  $SelftestRoot=$null

  Write-Host '=== 5/6 Fresh PoliticsTrasport -> codegeas -> PoliticsTrasport ==='
  $ControllerRoot = Join-Path $OutRoot '_controller'
  [IO.Compression.ZipFile]::ExtractToDirectory($candidate,$ControllerRoot)
  $controllerPython = Join-Path $ControllerRoot 'RUNTIME\python\python.exe'
  $seriesScript = Join-Path $ControllerRoot 'ACCEPTANCE\run_series.py'
  $seriesOut = Join-Path $OutRoot 'ABA_EVIDENCE'
  & $controllerPython -B -E -s $seriesScript --candidate $candidate --expected-sha $candidateSha --output $seriesOut 2>&1 |
    Tee-Object -FilePath (Join-Path $OutRoot 'ABA_SERIES.log')
  $seriesCode=$LASTEXITCODE
  if ($seriesCode -ne 0) { throw ('ABA_SERIES_FAILED:' + $seriesCode) }

  $comparisonPath=Join-Path $seriesOut 'SERIES_COMPARISON.json'
  $comparison=Get-Content -LiteralPath $comparisonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($comparison.technical_series_status -ne 'PASS' -or [int]$comparison.final_runs_completed -ne 3) {
    throw 'ABA_SERIES_COMPARISON_NONPASS'
  }
  $resultZips=@(Get-ChildItem -LiteralPath $seriesOut -Recurse -Filter 'RESULT_FOR_CHATGPT.zip' -File)
  if ($resultZips.Count -ne 3) { throw ('ABA_RESULT_ZIP_COUNT:' + $resultZips.Count) }
  $Summary.aba_series='PASS'
  $Summary.aba_result_zip_count=$resultZips.Count
  Write-Summary

  Write-Host '=== 6/6 Local environment readback ==='
  $PathAfter=Get-PathSnapshot
  $Summary.persistent_path_status = if ((ConvertTo-Json $PathBefore -Depth 8 -Compress) -eq (ConvertTo-Json $PathAfter -Depth 8 -Compress)) {'UNCHANGED'} else {'CHANGED_REQUIRES_REVIEW'}
  $Summary.status='TECHNICAL_LOCAL_ACCEPTANCE_PASS'
  $Summary.completed_utc=[DateTime]::UtcNow.ToString('o')
  Write-Summary

  if ($ControllerRoot -and (Test-Path -LiteralPath $ControllerRoot)) {
    Remove-Item -LiteralPath $ControllerRoot -Recurse -Force
    $ControllerRoot=$null
  }

  Write-Host ''
  Write-Host 'LOCAL TECHNICAL ACCEPTANCE PASS'
  Write-Host ('Candidate SHA256: ' + $candidateSha)
  Write-Host ('Evidence root: ' + $OutRoot)
  Write-Host 'Keep LOCAL_COMPLETION_SUMMARY.json, ABA_EVIDENCE, SELFTEST_RESULTS and the Candidate identity/archive.'
  Write-Host 'Offline internet use and Human/Product acceptance remain separate claims; do not mark them PASS unless actually performed.'
  exit 0
}
catch {
  $Summary.status='FAIL'
  $Summary.error=$_.Exception.Message
  $Summary.failed_utc=[DateTime]::UtcNow.ToString('o')
  try {
    if ($PathBefore) {
      $PathAfter=Get-PathSnapshot
      $Summary.persistent_path_status = if ((ConvertTo-Json $PathBefore -Depth 8 -Compress) -eq (ConvertTo-Json $PathAfter -Depth 8 -Compress)) {'UNCHANGED'} else {'CHANGED_REQUIRES_REVIEW'}
    }
  } catch {}
  Write-Summary
  [Console]::Error.WriteLine('LOCAL_COMPLETION_FAILED: ' + $_.Exception.Message)
  [Console]::Error.WriteLine('Preserve evidence at: ' + $OutRoot)
  exit 1
}
