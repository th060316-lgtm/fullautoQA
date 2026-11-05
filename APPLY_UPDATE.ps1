[CmdletBinding()]
param([string]$TargetRoot='')

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$PackageRoot=[IO.Path]::GetFullPath($PSScriptRoot)

function Get-SHA256([string]$Path) {
  $s=[IO.File]::OpenRead($Path)
  $h=[Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($h.ComputeHash($s))).Replace('-','').ToLowerInvariant() }
  finally { $h.Dispose(); $s.Dispose() }
}

function Test-FullDownload([string]$Root) {
  try {
    $r=[IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $r -PathType Container)) { return $false }
    $joins=@(Get-ChildItem -LiteralPath $r -Recurse -File -Filter 'JOIN_COMPLETE.ps1' -ErrorAction Stop | Where-Object {
      (Test-Path -LiteralPath (Join-Path $_.Directory.FullName 'manifest.json') -PathType Leaf) -and
      (Test-Path -LiteralPath (Join-Path $_.Directory.FullName 'blocks') -PathType Container)
    })
    return ($joins.Count -eq 1)
  } catch { return $false }
}

if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
  $parent=Split-Path -Parent $PackageRoot
  $candidates=@(Get-ChildItem -LiteralPath $parent -Directory | Where-Object {
    $_.FullName -ne $PackageRoot -and (Test-FullDownload $_.FullName)
  })
  if ($candidates.Count -eq 1) {
    $TargetRoot=$candidates[0].FullName
  } else {
    $TargetRoot=Read-Host 'Enter the path of the previous full fullautoQA download'
  }
}

$TargetRoot=[IO.Path]::GetFullPath($TargetRoot)
if (-not (Test-FullDownload $TargetRoot)) {
  throw 'TARGET_IS_NOT_A_COMPLETE_PREVIOUS_DOWNLOAD'
}
if ($TargetRoot.Equals($PackageRoot,[StringComparison]::OrdinalIgnoreCase)) {
  throw 'TARGET_MUST_DIFFER_FROM_UPDATE_PACKAGE'
}

$excluded=@('APPLY_UPDATE.cmd','APPLY_UPDATE.ps1','DOWNLOAD_BRANCH_INFO.md')
$files=@(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Where-Object {
  $relative=$_.FullName.Substring($PackageRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  -not ($excluded -contains $relative)
})
if ($files.Count -eq 0) { throw 'UPDATE_PACKAGE_HAS_NO_PAYLOAD_FILES' }

$copied=0
foreach ($file in $files) {
  $relative=$file.FullName.Substring($PackageRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  $dest=Join-Path $TargetRoot $relative
  $destDir=Split-Path -Parent $dest
  New-Item -ItemType Directory -Path $destDir -Force | Out-Null
  Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
  if ((Get-SHA256 $file.FullName) -ne (Get-SHA256 $dest)) {
    throw ('COPY_VERIFY_FAILED:' + $relative)
  }
  $copied++
}

$joins=@(Get-ChildItem -LiteralPath $TargetRoot -Recurse -File -Filter 'JOIN_COMPLETE.ps1' | Where-Object {
  (Test-Path -LiteralPath (Join-Path $_.Directory.FullName 'manifest.json') -PathType Leaf) -and
  (Test-Path -LiteralPath (Join-Path $_.Directory.FullName 'blocks') -PathType Container)
})
if ($joins.Count -ne 1) { throw ('POST_UPDATE_JOIN_DISCOVERY_FAILED:' + $joins.Count) }

$runner=Join-Path $TargetRoot 'RUN_LOCAL_COMPLETION.cmd'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'POST_UPDATE_RUNNER_MISSING' }

Write-Host 'UPDATE PASS'
Write-Host ('Files copied and verified: ' + $copied)
Write-Host ('Updated full download: ' + $TargetRoot)
Write-Host 'Next: disconnect external network if testing offline operation, then run RUN_LOCAL_COMPLETION.cmd in the updated full download.'
exit 0
