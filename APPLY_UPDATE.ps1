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

if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
  $TargetRoot=Read-Host 'Enter the folder to update'
}

$TargetRoot=$TargetRoot.Trim().Trim('"')
if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
  throw 'UPDATE_TARGET_NOT_SUPPLIED'
}

$TargetRoot=[IO.Path]::GetFullPath($TargetRoot)
if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
  throw ('UPDATE_TARGET_DIRECTORY_NOT_FOUND:' + $TargetRoot)
}
if ($TargetRoot.Equals($PackageRoot,[StringComparison]::OrdinalIgnoreCase)) {
  throw 'UPDATE_TARGET_MUST_DIFFER_FROM_UPDATE_PACKAGE'
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

$runnerSource=Join-Path $PackageRoot 'RUN_LOCAL_COMPLETION.ps1'
$runnerDest=Join-Path $TargetRoot 'RUN_LOCAL_COMPLETION.ps1'
if (-not (Test-Path -LiteralPath $runnerDest -PathType Leaf)) {
  throw 'UPDATED_RUNNER_MISSING'
}
if ((Get-SHA256 $runnerSource) -ne (Get-SHA256 $runnerDest)) {
  throw 'UPDATED_RUNNER_VERIFY_FAILED'
}

Write-Host 'UPDATE PASS'
Write-Host ('Files copied and verified: ' + $copied)
Write-Host ('Updated folder: ' + $TargetRoot)
Write-Host 'Next: run RUN_LOCAL_COMPLETION.cmd in the updated folder.'
exit 0
