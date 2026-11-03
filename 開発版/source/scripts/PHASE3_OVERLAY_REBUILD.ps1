# FullAutoQA Phase 3 complete-Candidate rebuild.
# The v0.3.3 donor is read-only. Runtime/Payload are preserved in a private staging copy.
[CmdletBinding(DefaultParameterSetName='Archive')]
param(
  [Parameter(Mandatory=$true,ParameterSetName='Archive')][string]$DonorArchive,
  [Parameter(Mandatory=$true,ParameterSetName='Tree')][string]$DonorExtracted,
  [Parameter(Mandatory=$true)][string]$SourceRoot,
  [Parameter(Mandatory=$true)][string]$OutputDir,
  [string]$CandidateName='FullAutoQA_PHASE3_CANDIDATE.zip',
  [string]$SourceBaseline=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-SHA256([string]$Path) {
  $s=[IO.File]::OpenRead($Path); $h=[Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($h.ComputeHash($s))).Replace('-','').ToLowerInvariant() }
  finally { $h.Dispose(); $s.Dispose() }
}
function Copy-Tree([string]$Src,[string]$Dst) {
  if (-not (Test-Path -LiteralPath $Src -PathType Container)) { throw ('SOURCE_TREE_MISSING:'+ $Src) }
  New-Item -ItemType Directory -Path $Dst -Force | Out-Null
  $robocopy=Join-Path $env:SystemRoot 'System32\robocopy.exe'
  if (Test-Path -LiteralPath $robocopy) {
    & $robocopy $Src $Dst /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ('ROBOCOPY_FAILED:'+ $LASTEXITCODE) }
  } else {
    Get-ChildItem -LiteralPath $Src -Force | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $Dst -Recurse -Force
    }
  }
}
function Find-CandidateRoot([string]$Extracted) {
  $p=[IO.Path]::GetFullPath($Extracted)
  if ((Test-Path (Join-Path $p 'CORE')) -and (Test-Path (Join-Path $p 'PAYLOAD')) -and (Test-Path (Join-Path $p 'RUNTIME'))) { return $p }
  $matches=@(Get-ChildItem -LiteralPath $p -Directory | Where-Object {
    (Test-Path (Join-Path $_.FullName 'CORE')) -and
    (Test-Path (Join-Path $_.FullName 'PAYLOAD')) -and
    (Test-Path (Join-Path $_.FullName 'RUNTIME'))
  })
  if ($matches.Count -ne 1) { throw ('CANDIDATE_ROOT_AMBIGUOUS:'+ $matches.Count) }
  return $matches[0].FullName
}

$SourceRoot=[IO.Path]::GetFullPath($SourceRoot)
$OutputDir=[IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$stage=Join-Path $OutputDir ('.phase3-stage-'+[Guid]::NewGuid().ToString('N'))
$fresh=Join-Path $OutputDir ('.phase3-fresh-'+[Guid]::NewGuid().ToString('N'))
$tmpZip=Join-Path $OutputDir ('.phase3-'+[Guid]::NewGuid().ToString('N')+'.tmp.zip')
$output=Join-Path $OutputDir $CandidateName
$report=Join-Path $OutputDir 'PHASE3_CANDIDATE_BUILD_REPORT.json'
$identity=Join-Path $OutputDir 'PHASE3_CANDIDATE_IDENTITY.json'
try {
  if (Test-Path -LiteralPath $output) { throw ('OUTPUT_ALREADY_EXISTS:'+ $output) }
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  if ($PSCmdlet.ParameterSetName -eq 'Archive') {
    $DonorArchive=[IO.Path]::GetFullPath($DonorArchive)
    if (-not (Test-Path -LiteralPath $DonorArchive -PathType Leaf)) { throw 'DONOR_ARCHIVE_MISSING' }
    [IO.Compression.ZipFile]::ExtractToDirectory($DonorArchive,$stage)
    $donorSha=Get-SHA256 $DonorArchive
  } else {
    $DonorExtracted=Find-CandidateRoot $DonorExtracted
    Copy-Tree $DonorExtracted $stage
    $donorSha=$null
  }
  $work=Find-CandidateRoot $stage

  $sourceCandidates=@($SourceRoot,(Join-Path $SourceRoot '開発版\source'),(Join-Path $SourceRoot 'source'))
  $src=$sourceCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'CORE') -PathType Container } | Select-Object -First 1
  if (-not $src) { throw 'CURRENT_SOURCE_ROOT_NOT_FOUND' }

  $dstCore=Join-Path $work 'CORE'
  if (Test-Path -LiteralPath $dstCore) { Remove-Item -LiteralPath $dstCore -Recurse -Force }
  Copy-Tree (Join-Path $src 'CORE') $dstCore

  $rootFiles=@(
    'START_QA.cmd','BOOTSTRAP.ps1','START_VALIDATION.sh','START_FUNCTIONAL.cmd','START_LOGIC.cmd',
    'START_PLAYABLE.cmd','START_LONG_SOAK.cmd','START_SOAK_24H.cmd','START_SELFTEST.cmd',
    'tool_manifest.json','python_manifest.json','capability_contract.json','git_runtime_manifest.json',
    'acceptance_manifest.json'
  )
  $overlaid=@()
  foreach ($name in $rootFiles) {
    $p=Join-Path $src $name
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      Copy-Item -LiteralPath $p -Destination (Join-Path $work $name) -Force
      $overlaid += $name
    }
  }

  $regen=Join-Path $PSScriptRoot 'PHASE3_REGEN_MANIFEST.ps1'
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $regen -Tree $work
  if ($LASTEXITCODE -ne 0) { throw ('MANIFEST_REGEN_FAILED:'+ $LASTEXITCODE) }

  $markerId=[Guid]::NewGuid().ToString('N')
  Set-Content -LiteralPath (Join-Path $work 'PHASE3_FRESH_EXTRACTION.marker') -Value $markerId -Encoding ASCII

  $python=Join-Path $work 'RUNTIME\python\python.exe'
  $integrity=Join-Path $PSScriptRoot 'package_integrity.py'
  & $python '-B' '-E' '-s' $integrity --root $work --full-payload --require-fresh-marker
  if ($LASTEXITCODE -ne 0) { throw ('PACKAGE_INTEGRITY_FAILED:'+ $LASTEXITCODE) }

  [IO.Compression.ZipFile]::CreateFromDirectory($work,$tmpZip,[IO.Compression.CompressionLevel]::Optimal,$false)
  $size=(Get-Item -LiteralPath $tmpZip).Length
  $sha=Get-SHA256 $tmpZip

  New-Item -ItemType Directory -Path $fresh -Force | Out-Null
  [IO.Compression.ZipFile]::ExtractToDirectory($tmpZip,$fresh)
  $freshRoot=Find-CandidateRoot $fresh
  $freshPython=Join-Path $freshRoot 'RUNTIME\python\python.exe'
  & $freshPython '-B' '-E' '-s' $integrity --root $freshRoot --full-payload --require-fresh-marker
  if ($LASTEXITCODE -ne 0) { throw ('FRESH_EXTRACTION_INTEGRITY_FAILED:'+ $LASTEXITCODE) }

  [IO.File]::Move($tmpZip,$output)
  $id=[ordered]@{
    phase=3; candidate_file=[IO.Path]::GetFileName($output); candidate_size=$size; candidate_sha256=$sha;
    source_baseline=$(if ($SourceBaseline) {$SourceBaseline} else {$null});
    donor_sha256=$donorSha; donor_mutated=$false; runtime_payload_preserved=$true;
    fresh_extraction_marker_id=$markerId; created_utc=[DateTime]::UtcNow.ToString('o')
  }
  $id | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $identity -Encoding UTF8
  [ordered]@{
    status='PASS'; candidate=$id; source_root=$src; overlaid_root_files=$overlaid;
    package_integrity='PASS'; fresh_extraction_integrity='PASS';
    windows_start_qa_real_game='NOT_RUN'; product_acceptance='HOLD'; stable='HOLD'
  } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $report -Encoding UTF8
  Write-Host ('PHASE3 CANDIDATE BUILT: '+$output)
  Write-Host ('SIZE: '+$size)
  Write-Host ('SHA256: '+$sha)
  exit 0
} catch {
  [ordered]@{status='FAIL';error=$_.Exception.Message;created_utc=[DateTime]::UtcNow.ToString('o')} |
    ConvertTo-Json | Set-Content -LiteralPath $report -Encoding UTF8
  [Console]::Error.WriteLine('PHASE3_OVERLAY_FAILED: '+$_.Exception.Message)
  exit 1
} finally {
  foreach ($p in @($tmpZip,$stage,$fresh)) {
    if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
