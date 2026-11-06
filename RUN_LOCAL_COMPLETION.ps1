# FullAutoQA local final-completion runner.
# Repository input, transient workspace, and preserved evidence are separate roots.
# Temporary drive mappings keep operational paths short without requiring fixed drive letters.
[CmdletBinding()]
param([switch]$NativeProcessContractTest,[switch]$EvidenceExportContractTest,[switch]$RepositoryDiscoveryContractTest,[switch]$RequireOffline)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$PhysicalRepoRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$RunTag = ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$SubstExe = Join-Path ([Environment]::GetFolderPath('System')) 'subst.exe'
$MappedDrive = $null
$WorkDrive = $null
$RepoRoot = $PhysicalRepoRoot
$PhysicalWorkRoot = $null
$WorkRoot = $null
$OutRoot = $null
$PhysicalOutRoot = $null
$SummaryPath = $null
$ExitCode = 1
$PathBefore = $null
$SelftestRoot = $null
$ControllerRoot = $null
$SeriesOut = $null
$BuildOut = $null

$Summary = [ordered]@{
  schema_version = 5
  run_tag = $RunTag
  status = 'STARTING'
  source_tree_fingerprint = $null
  prepared_source_fingerprint = $null
  purpose = 'Local Windows Candidate rebuild, selftest, Source regression and fresh A-B-A acceptance without GitHub Actions artifact transfer'
  physical_repository_root = $PhysicalRepoRoot
  logical_repository_root = $null
  repository_drive = $null
  physical_workspace_root = $null
  workspace_drive = $null
  workspace_root = $null
  started_utc = [DateTime]::UtcNow.ToString('o')
  non_admin_session = $null
  network_snapshot = $null
  network_snapshot_end = $null
  candidate = $null
  donor_join = 'NOT_RUN'
  candidate_build = 'NOT_RUN'
  candidate_integrity = 'NOT_RUN'
  source_regression = 'NOT_RUN'
  windows_selftest = 'NOT_RUN'
  aba_series = 'NOT_RUN'
  aba_result_zip_count = 0
  rollback_predecessor = 'NOT_RUN'
  rollback_result_zip_count = 0
  persistent_path_status = 'NOT_MEASURED'
  workspace_cleanup = 'NOT_RUN'
  offline_internet_status = $(if ($RequireOffline) {'REQUIRED_NOT_YET_VERIFIED'} else {'USER_MUST_RUN_WITH_EXTERNAL_NETWORK_DISCONNECTED'})
  human_test = 'NOT_RUN'
  product_acceptance = 'HOLD'
  stable = 'HOLD'
  evidence_root = $null
  logical_evidence_root = $null
  chatgpt_evidence_file = 'CHATGPT_EVIDENCE.zip'
  error = $null
}

function Get-SHA256([string]$Path) {
  $stream = [IO.File]::OpenRead($Path)
  $hash = [Security.Cryptography.SHA256]::Create()
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
    $active=New-Object 'System.Collections.Generic.List[object]'
    foreach ($adapter in @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
      $addresses=@(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.IPAddress })
      $usable=$false
      foreach ($raw in $addresses) {
        $candidate=([string]$raw).Split('%')[0]
        $ip=$null
        if ([Net.IPAddress]::TryParse($candidate,[ref]$ip)) {
          if (-not [Net.IPAddress]::IsLoopback($ip) -and
              -not $ip.Equals([Net.IPAddress]::Any) -and
              -not $ip.Equals([Net.IPAddress]::IPv6Any)) {
            $usable=$true
            break
          }
        }
      }
      if ($usable) {
        $active.Add([ordered]@{
          name=[string]$adapter.Name
          interface_description=[string]$adapter.InterfaceDescription
          addresses=$addresses
        })
      }
    }
    return [ordered]@{
      status='MEASURED'
      up_adapter_count=$active.Count
      up_adapters=@($active)
      method='windows_powershell_up_adapters_with_nonloopback_ip'
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

function Test-RepositoryDiscoveryExcludedDirectory([System.IO.DirectoryInfo]$Directory) {
  if ($Directory.Name -eq '.git' -or
      $Directory.Name -like '.fqa_work_*' -or
      $Directory.Name -like 'LOCAL_FINAL_ACCEPTANCE_*') {
    return $true
  }
  return (($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Find-RepositoryFile([string]$Root,[string]$Name,[string[]]$RequiredSiblings=@()) {
  $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  $matches=New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
  $pending=New-Object 'System.Collections.Generic.Stack[string]'
  $pending.Push($rootFull)

  while ($pending.Count -gt 0) {
    $current=$pending.Pop()
    foreach ($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
      if ($item.PSIsContainer) {
        # Never enter previous/current local work/evidence trees. They are
        # preserved evidence, not repository inputs. Also do not follow
        # reparse directories outside the repository discovery boundary.
        if (Test-RepositoryDiscoveryExcludedDirectory $item) { continue }
        $pending.Push($item.FullName)
        continue
      }
      if ($item.Name -ne $Name) { continue }
      $ok=$true
      foreach ($sibling in $RequiredSiblings) {
        if (-not (Test-Path -LiteralPath (Join-Path $item.Directory.FullName $sibling))) { $ok=$false; break }
      }
      if ($ok) { $matches.Add($item) }
    }
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

function Copy-StableEvidenceTree([string]$Source,[string]$Destination) {
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
    if ($item.Name -ieq 'WORK' -or $item.Name -ieq 'video_frames') { continue }
    if (-not $item.PSIsContainer -and $item.Name -ieq 'RESULT_FOR_CHATGPT.zip') { continue }
    $dest=Join-Path $Destination $item.Name
    if ($item.PSIsContainer) {
      Copy-StableEvidenceTree $item.FullName $dest
    } else {
      Copy-Item -LiteralPath $item.FullName -Destination $dest -Force -ErrorAction Stop
    }
  }
}

function Zip-DirectoryIfPresent([string]$Source,[string]$ZipPath) {
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
  $stage=Join-Path ([IO.Path]::GetDirectoryName($ZipPath)) ('.stable_zip_stage_' + [Guid]::NewGuid().ToString('N'))
  try {
    Copy-StableEvidenceTree $Source $stage
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$ZipPath,[IO.Compression.CompressionLevel]::Optimal,$false)
  } finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function ConvertTo-NativeArgument {
  param([AllowEmptyString()][string]$Value)
  if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }

  $builder=New-Object Text.StringBuilder
  [void]$builder.Append('"')
  $backslashes=0
  foreach ($ch in $Value.ToCharArray()) {
    if ($ch -eq '\') {
      $backslashes++
      continue
    }
    if ($ch -eq '"') {
      if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
      [void]$builder.Append('\"')
      $backslashes=0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$builder.Append(('\' * $backslashes))
      $backslashes=0
    }
    [void]$builder.Append($ch)
  }
  if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Join-NativeArguments {
  param([string[]]$Values)
  return (($Values | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' ')
}

function Invoke-NativeLogged {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$WorkingDirectory,
    [string]$LogPath
  )
  if (-not $WorkRoot) { throw 'WORKSPACE_NOT_INITIALIZED' }
  $token=[Guid]::NewGuid().ToString('N')
  $stdout=Join-Path $WorkRoot ('.native_'+$token+'.stdout.log')
  $stderr=Join-Path $WorkRoot ('.native_'+$token+'.stderr.log')
  $params=@{
    FilePath=$FilePath
    ArgumentList=(Join-NativeArguments $Arguments)
    NoNewWindow=$true
    PassThru=$true
    RedirectStandardOutput=$stdout
    RedirectStandardError=$stderr
  }
  if ($WorkingDirectory) { $params.WorkingDirectory=$WorkingDirectory }
  $process=Start-Process @params
  # Windows PowerShell 5.1 can otherwise expose a null ExitCode when
  # -NoNewWindow and/or redirected standard streams are used.
  # Cache the process handle before waiting; PowerShell/PowerShell #5421 documents this workaround.
  $cachedHandle=$process.Handle
  $process.WaitForExit()
  $code=$process.ExitCode
  if ($null -eq $code) {
    throw ('NATIVE_EXIT_CODE_UNAVAILABLE:pid=' + $process.Id)
  }
  $lines=New-Object 'System.Collections.Generic.List[string]'
  if (Test-Path -LiteralPath $stdout -PathType Leaf) {
    foreach ($line in @(Get-Content -LiteralPath $stdout)) { $lines.Add($line) }
  }
  if (Test-Path -LiteralPath $stderr -PathType Leaf) {
    foreach ($line in @(Get-Content -LiteralPath $stderr)) { $lines.Add($line) }
  }
  $lines | Set-Content -LiteralPath $LogPath -Encoding UTF8
  foreach ($line in $lines) { Write-Host $line }
  Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
  return [pscustomobject]@{ExitCode=$code}
}

function Invoke-NativeProcessContractTest {
  if ($env:OS -ne 'Windows_NT') { throw 'NATIVE_PROCESS_CONTRACT_TEST_REQUIRES_WINDOWS' }

  $oldWorkRoot=$WorkRoot
  $unicode=([string][char]0x65E5)+([string][char]0x672C)+([string][char]0x8A9E)
  $testRoot=Join-Path ([IO.Path]::GetTempPath()) ('fqa native '+$unicode+' space '+[Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  $child=Join-Path $testRoot 'child contract.ps1'
  @(
    'param([int]$Code)',
    '[Console]::Out.WriteLine(("STDOUT:{0}" -f $Code))',
    '[Console]::Error.WriteLine(("STDERR:{0}" -f $Code))',
    'exit $Code'
  ) | Set-Content -LiteralPath $child -Encoding ASCII

  $WorkRoot=$testRoot
  try {
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($expected in @(0,7)) {
      $log=Join-Path $testRoot ('native_'+$expected+'.log')
      $run=Invoke-NativeLogged -FilePath $powershell -Arguments @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$child,'-Code',[string]$expected
      ) -WorkingDirectory $testRoot -LogPath $log
      if ([int]$run.ExitCode -ne $expected) {
        throw ('NATIVE_PROCESS_CONTRACT_EXIT_MISMATCH:expected='+$expected+':actual='+$run.ExitCode)
      }
      $text=Get-Content -LiteralPath $log -Raw
      if ($text -notmatch ('STDOUT:'+[regex]::Escape([string]$expected)) -or
          $text -notmatch ('STDERR:'+[regex]::Escape([string]$expected))) {
        throw ('NATIVE_PROCESS_CONTRACT_LOG_MISSING:'+ $expected)
      }
    }
    Write-Host 'NATIVE_PROCESS_CONTRACT_TEST_PASS'
  } finally {
    $WorkRoot=$oldWorkRoot
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-RepositoryDiscoveryContractTest {
  $testRoot=Join-Path ([IO.Path]::GetTempPath()) ('fqa repository discovery ' + [Guid]::NewGuid().ToString('N'))
  try {
    $valid=Join-Path $testRoot 'authoritative\complete'
    $oldWork=Join-Path $testRoot '.fqa_work_old\selftest_fresh\RESULTS\old\WORK\fixture\shader_cache'
    $oldEvidence=Join-Path $testRoot 'LOCAL_FINAL_ACCEPTANCE_old\nested'
    New-Item -ItemType Directory -Path $valid -Force | Out-Null
    New-Item -ItemType Directory -Path $oldWork -Force | Out-Null
    New-Item -ItemType Directory -Path $oldEvidence -Force | Out-Null

    foreach ($dir in @($valid,$oldWork,$oldEvidence)) {
      Set-Content -LiteralPath (Join-Path $dir 'JOIN_COMPLETE.ps1') -Value '# contract' -Encoding ASCII
      Set-Content -LiteralPath (Join-Path $dir 'manifest.json') -Value '{}' -Encoding ASCII
      New-Item -ItemType Directory -Path (Join-Path $dir 'blocks') -Force | Out-Null
    }

    $found=Find-RepositoryFile -Root $testRoot -Name 'JOIN_COMPLETE.ps1' -RequiredSiblings @('manifest.json','blocks')
    if ([IO.Path]::GetFullPath($found) -ne [IO.Path]::GetFullPath((Join-Path $valid 'JOIN_COMPLETE.ps1'))) {
      throw ('REPOSITORY_DISCOVERY_SELECTED_TRANSIENT_TREE:' + $found)
    }

    $source=Get-Content -LiteralPath $PSCommandPath -Raw
    if ($source -match 'Get-ChildItem\s+-LiteralPath\s+\$rootFull\s+-Recurse\s+-File\s+-Filter') {
      throw 'REPOSITORY_DISCOVERY_RECURSIVE_PREFILTER_REGRESSION'
    }
    $normalizedSource=$source.Replace("`r`n","`n")
    $mainNeedle="try {`n  if (`$env:OS -ne 'Windows_NT')"
    $mainIndex=$normalizedSource.IndexOf($mainNeedle,[StringComparison]::Ordinal)
    if ($mainIndex -lt 0) { throw 'STRATEGIC_ROUTE_MAIN_BLOCK_NOT_FOUND' }
    $live=$normalizedSource.Substring($mainIndex)
    if ($live.Contains("Join-Path `$RepoRoot ('.fqa_work_'") -or
        $live.Contains("Join-Path `$RepoRoot ('LOCAL_FINAL_ACCEPTANCE_'")) {
      throw 'STRATEGIC_ROUTE_REPOSITORY_OUTPUT_REGRESSION'
    }
    if (-not $live.Contains("`$PhysicalWorkRoot = Join-Path ([IO.Path]::GetTempPath())") -or
        -not $live.Contains("`$WorkDrive = New-RepoDrive `$PhysicalWorkRoot") -or
        -not $live.Contains("`$WorkRoot = (`$WorkDrive + '\')")) {
      throw 'STRATEGIC_ROUTE_WORKSPACE_ISOLATION_MISSING'
    }
    if ($live.Contains('Find-RepositoryFile -Root $RepoRoot')) {
      throw 'STRATEGIC_ROUTE_LIVE_REPOSITORY_DISCOVERY_REGRESSION'
    }
    if (-not $live.Contains('開発版/transfer/TRANSFER_MANIFEST.json') -or
        -not $live.Contains('prepared_source_fingerprint') -or
        -not $live.Contains("'-SourceBaseline',`$Summary.prepared_source_fingerprint")) {
      throw 'STRATEGIC_ROUTE_DECLARED_INPUT_OR_PROVENANCE_MISSING'
    }
    Write-Host 'REPOSITORY_DISCOVERY_CONTRACT_TEST_PASS'
  } finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-EvidenceExportContractTest {
  if ($env:OS -ne 'Windows_NT') { throw 'EVIDENCE_EXPORT_CONTRACT_TEST_REQUIRES_WINDOWS' }
  $testRoot=Join-Path ([IO.Path]::GetTempPath()) ('fqa evidence export ' + [Guid]::NewGuid().ToString('N'))
  $source=Join-Path $testRoot 'RESULTS'
  $run=Join-Path $source 'Run1'
  $work=Join-Path $run 'WORK\case\shader_cache'
  $full=Join-Path $run 'FULL_EVIDENCE'
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  New-Item -ItemType Directory -Path $full -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $run 'result.json') -Value '{"run_id":"contract"}' -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $full 'stable.txt') -Value 'stable' -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $run 'RESULT_FOR_CHATGPT.zip') -Value 'nested archive sentinel' -Encoding ASCII
  $locked=Join-Path $work 'locked.bin'
  $lock=[IO.File]::Open($locked,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try {
    $zip=Join-Path $testRoot 'SELFTEST_RESULTS.zip'
    Zip-DirectoryIfPresent $source $zip
    $archive=[IO.Compression.ZipFile]::OpenRead($zip)
    try {
      $names=@($archive.Entries | ForEach-Object { $_.FullName.Replace('\','/') })
      if ($names -notcontains 'Run1/result.json' -or $names -notcontains 'Run1/FULL_EVIDENCE/stable.txt') {
        throw 'EVIDENCE_EXPORT_STABLE_CONTENT_MISSING'
      }
      $forbidden=@($names | Where-Object {
        $_ -match '(^|/)WORK(/|$)' -or
        $_ -match '(^|/)video_frames(/|$)' -or
        $_ -match 'RESULT_FOR_CHATGPT[.]zip$'
      })
      if ($forbidden.Count -ne 0) {
        throw 'EVIDENCE_EXPORT_INCLUDED_TRANSIENT_OR_NESTED_ARCHIVE'
      }
    } finally {
      $archive.Dispose()
    }
    Write-Host 'EVIDENCE_EXPORT_CONTRACT_TEST_PASS'
  } finally {
    $lock.Dispose()
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Export-ResultReadback {
  param([string]$ResultZip,[string]$Destination)
  if (-not (Test-Path -LiteralPath $ResultZip -PathType Leaf)) { return }
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  [ordered]@{
    file=[IO.Path]::GetFileName($ResultZip)
    size=(Get-Item -LiteralPath $ResultZip).Length
    sha256=Get-SHA256 $ResultZip
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Destination 'RESULT_ZIP_IDENTITY.json') -Encoding UTF8
  $wanted=@(
    'result.json',
    'SUMMARY.txt',
    'evidence_manifest.json',
    'phase3_environment.json',
    'phase3_preseal_integrity.json',
    'management_evidence.json',
    'sales_evidence.json',
    'player_review_packet.json',
    'full_evidence_index.json'
  )
  $archive=[IO.Compression.ZipFile]::OpenRead($ResultZip)
  try {
    foreach ($name in $wanted) {
      $entry=$archive.Entries | Where-Object { $_.FullName.Replace('\','/') -eq $name } | Select-Object -First 1
      if ($entry) {
        $dest=Join-Path $Destination $name
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$true)
      }
    }
    foreach ($entry in $archive.Entries) {
      $name=$entry.FullName.Replace('\','/')
      if ($name.Contains('/') -or -not $name.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)) { continue }
      if ($name -eq 'reproduction.json' -or
          $name -like '*_behavioral_regression.json' -or
          $name -like '*_performance_regression.json' -or
          $name -like '*_resources.json') {
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $Destination $name),$true)
      }
    }
  } finally { $archive.Dispose() }
}
function Persist-SeriesEvidence {
  param([string]$Source)
  if (-not $Source -or -not (Test-Path -LiteralPath $Source -PathType Container)) { return $Source }
  $destination=Join-Path $OutRoot 'series_full'
  if ([IO.Path]::GetFullPath($Source) -eq [IO.Path]::GetFullPath($destination)) { return $Source }
  if (Test-Path -LiteralPath $destination) { throw 'SERIES_EVIDENCE_DESTINATION_EXISTS' }
  Move-Item -LiteralPath $Source -Destination $destination
  return $destination
}
function Export-TransientEvidence {
  if (-not $OutRoot) { return }

  if ($BuildOut -and (Test-Path -LiteralPath $BuildOut -PathType Container)) {
    Copy-TopLevelFiles $BuildOut (Join-Path $OutRoot 'candidate_build') -SkipArchives
  }

  if ($SelftestRoot) {
    $selfResults=Join-Path $SelftestRoot 'RESULTS'
    if (Test-Path -LiteralPath $selfResults -PathType Container) {
      $readbackRoot=Join-Path $OutRoot 'selftest_readback'
      New-Item -ItemType Directory -Path $readbackRoot -Force | Out-Null
      foreach ($runDir in @(Get-ChildItem -LiteralPath $selfResults -Directory -ErrorAction Stop | Sort-Object Name)) {
        $certified=Join-Path $runDir.FullName 'RESULT_FOR_CHATGPT.zip'
        if (Test-Path -LiteralPath $certified -PathType Leaf) {
          $dest=Join-Path $OutRoot ('SELFTEST_' + $runDir.Name + '_RESULT_FOR_CHATGPT.zip')
          Copy-Item -LiteralPath $certified -Destination $dest -Force -ErrorAction Stop
          Export-ResultReadback -ResultZip $certified -Destination (Join-Path $readbackRoot $runDir.Name)
        }
      }
      # Diagnostic archive mirrors CORE evidence boundaries and never descends
      # into producer-owned WORK or video_frames.
      Zip-DirectoryIfPresent $selfResults (Join-Path $OutRoot 'SELFTEST_RESULTS.zip')
    }
  }

  # Full A-B-A evidence is moved once into OutRoot/series_full so it survives
  # workspace cleanup without duplicating the large Result ZIPs.
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
    'ABA_SERIES.log',
    'ROLLBACK_PREDECESSOR.log'
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
  $selftestReadback=Join-Path $OutRoot 'selftest_readback'
  if (Test-Path -LiteralPath $selftestReadback -PathType Container) {
    Copy-Item -LiteralPath $selftestReadback -Destination (Join-Path $stage 'selftest') -Recurse -Force
  }
  $rollbackEvidence=Join-Path $OutRoot 'rollback_predecessor'
  if (Test-Path -LiteralPath $rollbackEvidence -PathType Container) {
    Copy-Item -LiteralPath $rollbackEvidence -Destination (Join-Path $stage 'rollback_predecessor') -Recurse -Force
  }
  $rollbackReadback=Join-Path $OutRoot 'rollback_readback'
  if (Test-Path -LiteralPath $rollbackReadback -PathType Container) {
    Copy-Item -LiteralPath $rollbackReadback -Destination (Join-Path $stage 'rollback_readback') -Recurse -Force
  }
  if ($SeriesOut -and (Test-Path -LiteralPath $SeriesOut -PathType Container)) {
    $seriesStage=Join-Path $stage 'series'
    New-Item -ItemType Directory -Path $seriesStage -Force | Out-Null
    foreach ($name in @(
      'CANDIDATE_FREEZE.json',
      'TARGET_FREEZE.json',
      'EXECUTION_ENVIRONMENT.json',
      'SERIES_RECORDS.json',
      'SERIES_COMPARISON.json',
      'PERSISTENT_ENVIRONMENT_READBACK.json',
      'OPERATION_LOG.json'
    )) {
      $source=Join-Path $SeriesOut $name
      if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $seriesStage $name) -Force
      }
    }
    foreach ($runDir in @(Get-ChildItem -LiteralPath $SeriesOut -Directory -Filter 'Run*' | Sort-Object Name)) {
      $runStage=Join-Path $seriesStage $runDir.Name
      New-Item -ItemType Directory -Path $runStage -Force | Out-Null
      foreach ($name in @('RUN_IDENTITY.json','FRESH_PACKAGE_INTEGRITY.json','TARGET_PREPARATION.json')) {
        $source=Join-Path $runDir.FullName $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
          Copy-Item -LiteralPath $source -Destination (Join-Path $runStage $name) -Force
        }
      }
      Export-ResultReadback -ResultZip (Join-Path $runDir.FullName 'RESULT_FOR_CHATGPT.zip') -Destination (Join-Path $runStage 'result_readback')
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

if ($NativeProcessContractTest) {
  Invoke-NativeProcessContractTest
  exit 0
}
if ($EvidenceExportContractTest) {
  Invoke-EvidenceExportContractTest
  exit 0
}
if ($RepositoryDiscoveryContractTest) {
  Invoke-RepositoryDiscoveryContractTest
  exit 0
}

try {
  if ($env:OS -ne 'Windows_NT') { throw 'LOCAL_COMPLETION_REQUIRES_WINDOWS' }

  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $Summary.non_admin_session = -not $isAdmin
  if ($isAdmin) { throw 'RUN_FROM_A_STANDARD_NON_ADMIN_WINDOWS_SESSION' }

  $MappedDrive = New-RepoDrive $PhysicalRepoRoot
  $RepoRoot = ($MappedDrive + '\')

  # Never place transient work or preserved evidence inside the repository input tree.
  # Map the work directory itself to a drive root so deep runtime paths do not inherit
  # the repository path or a .fqa_work_<RunTag> segment.
  $PhysicalWorkRoot = Join-Path ([IO.Path]::GetTempPath()) ('FullAutoQA_Work_' + $RunTag)
  if (Test-Path -LiteralPath $PhysicalWorkRoot) { throw 'WORKSPACE_ROOT_ALREADY_EXISTS' }
  New-Item -ItemType Directory -Path $PhysicalWorkRoot -Force | Out-Null
  $WorkDrive = New-RepoDrive $PhysicalWorkRoot
  $WorkRoot = ($WorkDrive + '\')

  $repoParent = Split-Path -Parent $PhysicalRepoRoot
  $PhysicalOutRoot = Join-Path $repoParent ('LOCAL_FINAL_ACCEPTANCE_' + $RunTag)
  if (Test-Path -LiteralPath $PhysicalOutRoot) { throw 'EVIDENCE_ROOT_ALREADY_EXISTS' }
  New-Item -ItemType Directory -Path $PhysicalOutRoot -Force | Out-Null
  $OutRoot = $PhysicalOutRoot
  $SummaryPath = Join-Path $OutRoot 'LOCAL_COMPLETION_SUMMARY.json'
  $Summary.logical_repository_root = $RepoRoot
  $Summary.repository_drive = $MappedDrive
  $Summary.physical_workspace_root = $PhysicalWorkRoot
  $Summary.workspace_drive = $WorkDrive
  $Summary.workspace_root = $WorkRoot
  $Summary.evidence_root = $PhysicalOutRoot
  $Summary.logical_evidence_root = $OutRoot
  $Summary.status = 'RUNNING'

  $Summary.network_snapshot = Get-NetworkSnapshot
  $PathBefore = Get-PathSnapshot
  Write-Summary

  $transferManifestPath=Resolve-RepositoryRelativePath -Root $RepoRoot -Relative '開発版/transfer/TRANSFER_MANIFEST.json'
  if (-not (Test-Path -LiteralPath $transferManifestPath -PathType Leaf)) { throw 'TRANSFER_MANIFEST_MISSING' }
  $transfer=Get-Content -LiteralPath $transferManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

  Write-Host '=== 1/7 Reconstruct preserved v0.3.3 donor ==='
  if (-not $transfer.latest_complete_candidate -or [string]::IsNullOrWhiteSpace([string]$transfer.latest_complete_candidate.path)) {
    throw 'DONOR_DECLARATION_MISSING'
  }
  $complete = Resolve-RepositoryRelativePath -Root $RepoRoot -Relative ([string]$transfer.latest_complete_candidate.path)
  $join = Join-Path $complete 'JOIN_COMPLETE.ps1'
  if (-not (Test-Path -LiteralPath $join -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Join-Path $complete 'manifest.json') -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Join-Path $complete 'blocks') -PathType Container)) {
    throw 'DECLARED_DONOR_INPUT_INVALID'
  }
  $donorRun=Invoke-NativeLogged -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$join) -WorkingDirectory $complete -LogPath (Join-Path $OutRoot 'DONOR_JOIN.log')
  $donorCode=$donorRun.ExitCode
  if ($donorCode -ne 0) { throw ('DONOR_JOIN_FAILED:' + $donorCode) }
  $manifest = Get-Content -LiteralPath (Join-Path $complete 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $donor = Join-Path $complete ([string]$manifest.file)
  if (-not (Test-Path -LiteralPath $donor -PathType Leaf)) { throw 'DONOR_ARCHIVE_MISSING_AFTER_JOIN' }
  if ((Get-Item -LiteralPath $donor).Length -ne [long]$manifest.size -or (Get-SHA256 $donor) -ne ([string]$manifest.sha256).ToLowerInvariant()) {
    throw 'DONOR_IDENTITY_MISMATCH_AFTER_JOIN'
  }
  $Summary.donor_join='PASS'
  Write-Summary

  Write-Host '=== 2/7 Reconstruct current Source and build Candidate ==='
  $sourceDestination = Join-Path $WorkRoot 'prepared'
  $prepare = Resolve-RepositoryRelativePath -Root $RepoRoot -Relative '開発版/source/scripts/PREPARE_SOURCE.ps1'
  $rebuildDeclared = Resolve-RepositoryRelativePath -Root $RepoRoot -Relative '開発版/source/scripts/PHASE3_OVERLAY_REBUILD.ps1'
  if (-not (Test-Path -LiteralPath $prepare -PathType Leaf) -or -not (Test-Path -LiteralPath $rebuildDeclared -PathType Leaf)) {
    throw 'DECLARED_SOURCE_BUILD_INPUT_INVALID'
  }
  $checkedOutSourceRoot = Split-Path -Parent (Split-Path -Parent $prepare)
  if (-not (Test-Path -LiteralPath (Join-Path $checkedOutSourceRoot 'CORE') -PathType Container)) { throw 'CHECKED_OUT_SOURCE_ROOT_INVALID' }
  $Summary.source_tree_fingerprint = Get-TreeFingerprint $checkedOutSourceRoot
  Write-Summary

  if (-not $transfer.recovery_source -or [string]::IsNullOrWhiteSpace([string]$transfer.recovery_source.path) -or
      [string]::IsNullOrWhiteSpace([string]$transfer.recovery_source.sha256)) {
    throw 'RECOVERY_SOURCE_DECLARATION_MISSING'
  }
  $recoverySource = Resolve-RepositoryRelativePath -Root $RepoRoot -Relative ([string]$transfer.recovery_source.path)
  $sourceRoot = & $prepare -RepositoryRoot $RepoRoot -Destination $sourceDestination -RecoveryArchive $recoverySource -ExpectedRecoverySha256 ([string]$transfer.recovery_source.sha256)
  if (-not $sourceRoot -or -not (Test-Path -LiteralPath (Join-Path $sourceRoot 'CORE') -PathType Container)) {
    throw 'PREPARED_SOURCE_ROOT_INVALID'
  }
  $Summary.prepared_source_fingerprint = Get-TreeFingerprint $sourceRoot
  Write-Summary

  $plan = Resolve-RepositoryRelativePath -Root $RepoRoot -Relative '開発版/acceptance_targets/FINAL_SERIES_PLAN.json'
  if (-not (Test-Path -LiteralPath $plan -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $plan) 'run_series.py') -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $plan) 'RUN_FINAL_ACCEPTANCE.cmd') -PathType Leaf)) {
    throw 'DECLARED_FINAL_SERIES_INPUT_INVALID'
  }
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
    '-SourceBaseline',$Summary.prepared_source_fingerprint
  )
  $buildRun=Invoke-NativeLogged -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments $buildArgs -WorkingDirectory $sourceRoot -LogPath (Join-Path $OutRoot 'CANDIDATE_BUILD.log')
  $buildCode=$buildRun.ExitCode
  if ($buildCode -ne 0) { throw ('CANDIDATE_BUILD_FAILED:' + $buildCode) }
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

  Write-Host '=== 3/7 Fresh Candidate Source regression ==='
  $SelftestRoot = Join-Path $WorkRoot 'selftest'
  [IO.Compression.ZipFile]::ExtractToDirectory($candidate,$SelftestRoot)
  $bundledPython = Join-Path $SelftestRoot 'RUNTIME\python\python.exe'
  if (-not (Test-Path -LiteralPath $bundledPython -PathType Leaf)) { throw 'BUNDLED_PYTHON_NOT_FOUND' }
  $sourceArgs=@('-B','-E','-s','-m','unittest','discover','-s',(Join-Path $SelftestRoot 'TESTS'),'-v')
  $sourceRun=Invoke-NativeLogged -FilePath $bundledPython -Arguments $sourceArgs -WorkingDirectory $SelftestRoot -LogPath (Join-Path $OutRoot 'BUNDLED_SOURCE_TESTS.log')
  $sourceTestCode=$sourceRun.ExitCode
  if ($sourceTestCode -ne 0) { throw ('BUNDLED_SOURCE_REGRESSION_FAILED:' + $sourceTestCode) }
  $Summary.source_regression='PASS'
  Write-Summary

  Remove-Item -LiteralPath $SelftestRoot -Recurse -Force
  $SelftestRoot = Join-Path $WorkRoot 'selftest_fresh'
  [IO.Compression.ZipFile]::ExtractToDirectory($candidate,$SelftestRoot)
  Set-Content -LiteralPath (Join-Path $SelftestRoot 'PHASE3_FRESH_EXTRACTION.marker') -Value ([Guid]::NewGuid().ToString('N')) -Encoding ASCII

  Write-Host '=== 4/7 Fresh Candidate START_QA selftest ==='
  $selfRun=Invoke-NativeLogged -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments @('/d','/c','START_QA.cmd','-SelfTest') -WorkingDirectory $SelftestRoot -LogPath (Join-Path $OutRoot 'START_QA_SELFTEST.log')
  $selfCode=$selfRun.ExitCode
  Export-TransientEvidence
  if ($selfCode -ne 0) { throw ('WINDOWS_SELFTEST_FAILED:' + $selfCode) }
  $Summary.windows_selftest='PASS'
  Write-Summary

  Remove-Item -LiteralPath $SelftestRoot -Recurse -Force
  $SelftestRoot=$null

  Write-Host '=== 5/7 Fresh PoliticsTrasport -> codegeas -> PoliticsTrasport ==='
  $ControllerRoot = Join-Path $WorkRoot 'controller'
  [IO.Compression.ZipFile]::ExtractToDirectory($candidate,$ControllerRoot)
  $controllerPython = Join-Path $ControllerRoot 'RUNTIME\python\python.exe'
  $seriesScript = Join-Path $ControllerRoot 'ACCEPTANCE\run_series.py'
  $SeriesOut = Join-Path $WorkRoot 'series'
  $seriesArgs=@('-B','-E','-s',$seriesScript,'--candidate',$candidate,'--expected-sha',$candidateSha,'--output',$SeriesOut)
  $seriesRun=Invoke-NativeLogged -FilePath $controllerPython -Arguments $seriesArgs -WorkingDirectory $ControllerRoot -LogPath (Join-Path $OutRoot 'ABA_SERIES.log')
  $seriesCode=$seriesRun.ExitCode
  if (Test-Path -LiteralPath $SeriesOut -PathType Container) {
    $SeriesOut=Persist-SeriesEvidence -Source $SeriesOut
  }
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
  $seriesEnvironmentPath=Join-Path $SeriesOut 'EXECUTION_ENVIRONMENT.json'
  if (Test-Path -LiteralPath $seriesEnvironmentPath -PathType Leaf) {
    $seriesEnvironment=Get-Content -LiteralPath $seriesEnvironmentPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($seriesEnvironment.local_windows_offline -eq 'NO_UP_NON_LOOPBACK_INTERFACES_OBSERVED') {
      $Summary.offline_internet_status='NO_UP_NON_LOOPBACK_INTERFACES_OBSERVED_ALL_FINAL_RUNS'
    }
  }
  Write-Summary

  Write-Host '=== 6/7 Fresh preserved predecessor rollback qualification ==='
  $rollbackScript = Resolve-RepositoryRelativePath -Root $RepoRoot -Relative '開発版/rollback/RESTORE_PREDECESSOR.ps1'
  if (-not (Test-Path -LiteralPath $rollbackScript -PathType Leaf)) {
    throw 'ROLLBACK_ENTRYPOINT_MISSING'
  }
  $rollbackDestination = Join-Path $WorkRoot 'rollback_predecessor'
  $rollbackEvidence = Join-Path $OutRoot 'rollback_predecessor'
  $rollbackArgs=@(
    '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$rollbackScript,
    '-RepositoryRoot',$RepoRoot,
    '-Destination',$rollbackDestination,
    '-EvidenceDirectory',$rollbackEvidence,
    '-SelfTest'
  )
  $rollbackRun=Invoke-NativeLogged -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments $rollbackArgs -WorkingDirectory $RepoRoot -LogPath (Join-Path $OutRoot 'ROLLBACK_PREDECESSOR.log')
  $rollbackCode=$rollbackRun.ExitCode

  $rollbackResults=Join-Path $rollbackDestination 'RESULTS'
  if (Test-Path -LiteralPath $rollbackResults -PathType Container) {
    $rollbackReadback=Join-Path $OutRoot 'rollback_readback'
    New-Item -ItemType Directory -Path $rollbackReadback -Force | Out-Null
    foreach ($zip in @(Get-ChildItem -LiteralPath $rollbackResults -Recurse -File -Filter 'RESULT_FOR_CHATGPT.zip' -ErrorAction Stop | Sort-Object LastWriteTimeUtc)) {
      $dest=Join-Path $OutRoot ('ROLLBACK_' + $zip.Directory.Name + '_RESULT_FOR_CHATGPT.zip')
      Copy-Item -LiteralPath $zip.FullName -Destination $dest -Force
      Export-ResultReadback -ResultZip $zip.FullName -Destination (Join-Path $rollbackReadback $zip.Directory.Name)
      $Summary.rollback_result_zip_count++
    }
  }

  $rollbackProofPath=Join-Path $rollbackEvidence 'ROLLBACK_PREDECESSOR_QUALIFICATION.json'
  if (Test-Path -LiteralPath $rollbackProofPath -PathType Leaf) {
    $rollbackProof=Get-Content -LiteralPath $rollbackProofPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($rollbackCode -eq 0 -and
        $rollbackProof.byte_identity -eq 'PASS' -and
        $rollbackProof.runnable_rollback_status -eq 'PASS') {
      $Summary.rollback_predecessor='PASS'
    } else {
      $Summary.rollback_predecessor='FAIL'
    }
  } else {
    $Summary.rollback_predecessor='FAIL'
  }
  Write-Summary

  Write-Host '=== 7/7 Local environment readback ==='
  $Summary.network_snapshot_end=Get-NetworkSnapshot
  $PathAfter=Get-PathSnapshot
  $Summary.persistent_path_status = if ((ConvertTo-Json $PathBefore -Depth 8 -Compress) -eq (ConvertTo-Json $PathAfter -Depth 8 -Compress)) {'UNCHANGED'} else {'CHANGED_REQUIRES_REVIEW'}

  if ($RequireOffline) {
    $offlineStart=($Summary.network_snapshot.status -eq 'MEASURED' -and [int]$Summary.network_snapshot.up_adapter_count -eq 0)
    $offlineEnd=($Summary.network_snapshot_end.status -eq 'MEASURED' -and [int]$Summary.network_snapshot_end.up_adapter_count -eq 0)
    $offlineSeries=($Summary.offline_internet_status -eq 'NO_UP_NON_LOOPBACK_INTERFACES_OBSERVED_ALL_FINAL_RUNS')
    if ($offlineStart -and $offlineEnd -and $offlineSeries) {
      $Summary.offline_internet_status='PASS_NO_UP_NON_LOOPBACK_INTERFACES_OBSERVED_START_SERIES_END'
    } else {
      $Summary.offline_internet_status='FAIL_OR_NOT_MEASURED'
    }
  }

  $Summary.completed_utc=[DateTime]::UtcNow.ToString('o')
  Export-TransientEvidence
  Write-Summary

  $finalFailures=New-Object 'System.Collections.Generic.List[string]'
  if ($Summary.rollback_predecessor -ne 'PASS') { $finalFailures.Add('ROLLBACK_PREDECESSOR_NONPASS') }
  if ($Summary.persistent_path_status -ne 'UNCHANGED') { $finalFailures.Add('PERSISTENT_PATH_CHANGED_OR_NOT_MEASURED') }
  if ($RequireOffline -and $Summary.offline_internet_status -ne 'PASS_NO_UP_NON_LOOPBACK_INTERFACES_OBSERVED_START_SERIES_END') {
    $finalFailures.Add('OFFLINE_REQUIREMENT_NONPASS')
  }
  if ($finalFailures.Count -gt 0) {
    throw ('FINAL_LOCAL_GATE_NONPASS:' + ($finalFailures -join ','))
  }

  $Summary.status='TECHNICAL_LOCAL_ACCEPTANCE_PASS'
  Write-Summary
  $ExitCode=0

  Write-Host ''
  Write-Host 'LOCAL TECHNICAL ACCEPTANCE PASS'
  Write-Host ('Candidate SHA256: ' + $candidateSha)
  Write-Host ('Evidence root: ' + $PhysicalOutRoot)
  Write-Host 'Rollback, non-admin, Candidate selftest, A-B-A, persistent PATH and requested offline observation passed. Human/Product/Stable remain separate gates.'
}
catch {
  $Summary.status='FAIL'
  $Summary.error=$_.Exception.Message
  $Summary.failed_utc=[DateTime]::UtcNow.ToString('o')
  try {
    Export-TransientEvidence
    $Summary.network_snapshot_end=Get-NetworkSnapshot
    if ($PathBefore) {
      $PathAfter=Get-PathSnapshot
      $Summary.persistent_path_status = if ((ConvertTo-Json $PathBefore -Depth 8 -Compress) -eq (ConvertTo-Json $PathAfter -Depth 8 -Compress)) {'UNCHANGED'} else {'CHANGED_REQUIRES_REVIEW'}
    }
  } catch {
    $Summary.evidence_export_error=$_.Exception.Message
  }
  Write-Summary
  [Console]::Error.WriteLine('LOCAL_COMPLETION_FAILED: ' + $_.Exception.Message)
  if ($PhysicalOutRoot) { [Console]::Error.WriteLine('Preserve evidence at: ' + $PhysicalOutRoot) }
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
    $Summary.workspace_cleanup='WORKSPACE_PENDING_DRIVE_RELEASE'
  } catch {
    $Summary.workspace_cleanup=('WORKSPACE_CHILD_CLEANUP_FAILED:' + $_.Exception.Message)
  }

  if ($WorkDrive) {
    $workDriveRemoved=Remove-RepoDrive $WorkDrive
    if (-not $workDriveRemoved) {
      [Console]::Error.WriteLine('WARNING: temporary work drive mapping cleanup failed for ' + $WorkDrive)
    }
  }
  if ($PhysicalWorkRoot -and (Test-Path -LiteralPath $PhysicalWorkRoot)) {
    try {
      Remove-Item -LiteralPath $PhysicalWorkRoot -Recurse -Force -ErrorAction Stop
      $Summary.workspace_cleanup='WORKSPACE_REMOVED'
    } catch {
      $Summary.workspace_cleanup=('WORKSPACE_RETAINED:' + $_.Exception.Message)
    }
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
      [Console]::Error.WriteLine('WARNING: temporary repository drive mapping cleanup failed for ' + $MappedDrive)
    }
  }
}

exit $ExitCode
