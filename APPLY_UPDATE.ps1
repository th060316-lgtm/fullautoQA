[CmdletBinding()]
param([string]$TargetRoot='')

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$PackageRoot=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)

function Get-SHA256([string]$Path) {
  $s=[IO.File]::OpenRead($Path)
  $h=[Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($h.ComputeHash($s))).Replace('-','').ToLowerInvariant() }
  finally { $h.Dispose(); $s.Dispose() }
}

function Get-RelativePath([string]$Root,[string]$Path) {
  $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  $pathFull=[IO.Path]::GetFullPath($Path)
  $prefix=$rootFull+[IO.Path]::DirectorySeparatorChar
  if (-not $pathFull.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'PATH_OUTSIDE_PACKAGE_ROOT' }
  return $pathFull.Substring($prefix.Length)
}

function Find-PackageFile([string]$Name,[string[]]$RequiredSiblings=@()) {
  $matches=New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
  foreach ($item in @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Filter $Name -ErrorAction Stop)) {
    $relative=Get-RelativePath $PackageRoot $item.FullName
    $top=$relative.Split([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)[0]
    if ($top -eq '.git') { continue }
    $ok=$true
    foreach ($sibling in $RequiredSiblings) {
      if (-not (Test-Path -LiteralPath (Join-Path $item.Directory.FullName $sibling))) { $ok=$false; break }
    }
    if ($ok) { $matches.Add($item) }
  }
  if ($matches.Count -ne 1) { throw ('PACKAGE_MARKER_DISCOVERY_FAILED:'+$Name+':'+$matches.Count) }
  return $matches[0]
}

function Get-RelativeFileSet([string]$Root) {
  $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  $rows=New-Object 'System.Collections.Generic.List[string]'
  foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force | Sort-Object FullName)) {
    $rows.Add((Get-RelativePath $rootFull $file.FullName).Replace([IO.Path]::DirectorySeparatorChar,'/'))
  }
  return @($rows)
}

if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
  $TargetRoot=Read-Host 'Enter the folder to update'
}
$TargetRoot=$TargetRoot.Trim().Trim('"')
if ([string]::IsNullOrWhiteSpace($TargetRoot)) { throw 'UPDATE_TARGET_NOT_SUPPLIED' }
$TargetRoot=[IO.Path]::GetFullPath($TargetRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) { throw ('UPDATE_TARGET_DIRECTORY_NOT_FOUND:'+$TargetRoot) }
if ($TargetRoot.Equals($PackageRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'UPDATE_TARGET_MUST_DIFFER_FROM_UPDATE_PACKAGE' }

$prepare=Find-PackageFile -Name 'PREPARE_SOURCE.ps1' -RequiredSiblings @('PHASE3_OVERLAY_REBUILD.ps1')
$sourceRoot=Split-Path -Parent (Split-Path -Parent $prepare.FullName)
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'CORE') -PathType Container)) { throw 'PACKAGE_SOURCE_ROOT_INVALID' }
$plan=Find-PackageFile -Name 'FINAL_SERIES_PLAN.json' -RequiredSiblings @('run_series.py','RUN_FINAL_ACCEPTANCE.cmd')
$acceptanceRoot=$plan.Directory.FullName
$transferManifest=Find-PackageFile -Name 'TRANSFER_MANIFEST.json'
$transferRoot=$transferManifest.Directory.FullName

$managedRoots=@($sourceRoot,$acceptanceRoot,$transferRoot)
foreach ($packageManagedRoot in $managedRoots) {
  $relative=Get-RelativePath $PackageRoot $packageManagedRoot
  $targetManagedRoot=Join-Path $TargetRoot $relative
  if (Test-Path -LiteralPath $targetManagedRoot) {
    Remove-Item -LiteralPath $targetManagedRoot -Recurse -Force
  }
}

$excluded=@('APPLY_UPDATE.cmd','APPLY_UPDATE.ps1','DOWNLOAD_BRANCH_INFO.md')
$files=@(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Force | Where-Object {
  $relative=Get-RelativePath $PackageRoot $_.FullName
  $top=$relative.Split([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)[0]
  $top -ne '.git' -and -not ($excluded -contains $relative)
})
if ($files.Count -eq 0) { throw 'UPDATE_PACKAGE_HAS_NO_PAYLOAD_FILES' }

$copied=0
foreach ($file in $files) {
  $relative=Get-RelativePath $PackageRoot $file.FullName
  $dest=Join-Path $TargetRoot $relative
  $destDir=Split-Path -Parent $dest
  New-Item -ItemType Directory -Path $destDir -Force | Out-Null
  Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
  if ((Get-SHA256 $file.FullName) -ne (Get-SHA256 $dest)) { throw ('COPY_VERIFY_FAILED:'+$relative) }
  $copied++
}

foreach ($packageManagedRoot in $managedRoots) {
  $relative=Get-RelativePath $PackageRoot $packageManagedRoot
  $targetManagedRoot=Join-Path $TargetRoot $relative
  if (-not (Test-Path -LiteralPath $targetManagedRoot -PathType Container)) { throw ('MANAGED_ROOT_MISSING_AFTER_UPDATE:'+$relative) }
  $packageSet=@(Get-RelativeFileSet $packageManagedRoot)
  $targetSet=@(Get-RelativeFileSet $targetManagedRoot)
  if ((ConvertTo-Json $packageSet -Compress) -ne (ConvertTo-Json $targetSet -Compress)) {
    throw ('MANAGED_ROOT_FILESET_MISMATCH:'+$relative)
  }
}

$runnerSource=Join-Path $PackageRoot 'RUN_LOCAL_COMPLETION.ps1'
$runnerDest=Join-Path $TargetRoot 'RUN_LOCAL_COMPLETION.ps1'
if (-not (Test-Path -LiteralPath $runnerDest -PathType Leaf)) { throw 'UPDATED_RUNNER_MISSING' }
if ((Get-SHA256 $runnerSource) -ne (Get-SHA256 $runnerDest)) { throw 'UPDATED_RUNNER_VERIFY_FAILED' }

Write-Host 'UPDATE PASS'
Write-Host ('Files copied and verified: '+$copied)
Write-Host ('Updated folder: '+$TargetRoot)
Write-Host 'Managed Source, acceptance and transfer trees were replaced from the update package.'
Write-Host 'Preserved donor block payload outside those managed trees was not removed.'
Write-Host 'Next: run RUN_LOCAL_COMPLETION.cmd in the updated folder.'
exit 0
