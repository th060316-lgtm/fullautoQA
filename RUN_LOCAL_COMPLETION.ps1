# FullAutoQA local final-completion runner.
# Repository input, transient workspace, and preserved evidence are separate roots.
# Temporary drive mappings keep operational paths short without requiring fixed drive letters.
#
# ASCII-only invariant: this file must never contain a byte above 0x7F.
# Windows PowerShell 5.1 decodes a BOM-less script with the system ANSI code
# page, so a non-ASCII literal here is mojibake on a real machine while a
# hosted PowerShell 7 run still passes.  Every declared input is therefore
# resolved through the shared entry contract in
# <source root>/source/scripts/REPOSITORY_ENTRY.ps1, which discovers the
# source root structurally instead of by a hard-coded directory name.
[CmdletBinding()]
param(
  [switch]$NativeProcessContractTest,
  [switch]$EvidenceExportContractTest,
  [switch]$RepositoryDiscoveryContractTest,
  [switch]$RepositoryEntryContractTest,
  [switch]$PreparedBaselineContractTest,
  [switch]$RequireOffline,
  # Optional cold-start review evidence (human or validated proxy) that the
  # Sales headquarters consumes.  A model proxy is never promoted to a human
  # and the absence of the file is never read as a pass.
  [string]$SalesReviewEvidence=''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Captured before the shared contract is dot-sourced: dot-sourcing assigns the
# dot-sourced script's own $PSScriptRoot into the caller's scope.
$RunnerDirectory = $PSScriptRoot
$PhysicalRepoRoot = [IO.Path]::GetFullPath($RunnerDirectory)
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
  schema_version = 6
  run_tag = $RunTag
  status = 'STARTING'
  source_tree_fingerprint = $null
  source_tree_fingerprint_algorithm = 'relative-path-tab-size-tab-sha256; rows ordinal; LF; UTF-8; excludes __pycache__ and .pyc/.pyo'
  prepared_source_fingerprint = $null
  handoff_preflight = 'NOT_RUN'
  purpose = 'Local Windows Candidate rebuild, selftest, Source regression and fresh A-B-A acceptance without GitHub Actions artifact transfer'
  physical_repository_root = $PhysicalRepoRoot
  logical_repository_root = $null
  repository_drive = $null
  physical_workspace_root = $null
  workspace_drive = $null
  workspace_root = $null
  started_utc = [DateTime]::UtcNow.ToString('o')
  updated_utc = $null
  completed_utc = $null
  failed_utc = $null
  evidence_export_error = $null
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
  registry_write_audit = 'NOT_RUN'
  program_files_write_audit = 'NOT_RUN'
  management_gate = 'NOT_RUN'
  sales_gate = 'NOT_RUN'
  sales_review_evidence = $null
  independent_hq_final_verdict = 'NOT_RUN'
  human_test = 'NOT_RUN'
  product_acceptance = 'HOLD'
  stable = 'HOLD'
  evidence_root = $null
  logical_evidence_root = $null
  chatgpt_evidence_file = 'CHATGPT_EVIDENCE.zip'
  error = $null
}

function Find-RepositoryEntryModule([string]$Root) {
  # Bounded, one-level structural discovery of the shared entry contract.
  # The source root is never named literally, so this works with a non-ASCII
  # source-root directory name on Windows PowerShell 5.1.
  $found=New-Object 'System.Collections.Generic.List[string]'
  foreach($dir in @(Get-ChildItem -LiteralPath $Root -Directory -Force)) {
    if ($dir.Name -eq '.git') { continue }
    $candidate=Join-Path $dir.FullName ('source/scripts/REPOSITORY_ENTRY.ps1')
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found.Add($candidate) }
  }
  if ($found.Count -ne 1) { throw ('REPOSITORY_ENTRY_MODULE_DISCOVERY_FAILED:'+$found.Count) }
  return $found[0]
}

function Resolve-RepositoryEntryModule {
  # The shared entry contract is loaded ON DEMAND, not at startup.
  #
  # Two of the contract-test modes are self-contained: they build their own
  # tree in the temporary directory and never touch the repository inputs.
  # Loading the contract at startup made those modes fail on a checkout that
  # contains only the runner, which is exactly the checkout the hosted
  # syntax job uses.
  #
  # The contract is dot-sourced at the SCRIPT scope on purpose: dot-sourcing
  # it inside a function would define its functions in that function's scope
  # only, and the runner's own functions could not see them.
  $module = Find-RepositoryEntryModule -Root $PhysicalRepoRoot
  if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {
    throw ('REPOSITORY_ENTRY_MODULE_MISSING:' + $module)
  }
  return $module
}

function Get-SHA256([string]$Path) {
  # The hashing itself lives in the shared entry contract; this keeps the
  # historical call sites without a second implementation.
  return (Get-Sha256File -Path $Path)
}

function Get-SourceTreeFingerprint([string]$Root,[string]$ManifestOut='') {
  # ONE canonical Source-tree fingerprint implementation
  # (<source root>/source/scripts/SOURCE_TREE_FINGERPRINT.ps1) is used by the
  # runner, by the Candidate builder and by CI, so the baseline the runner
  # binds can never disagree with the tree the builder hashes.
  $script=Get-SourceTreeFingerprintScript
  $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-Root',$Root)
  if (-not [string]::IsNullOrWhiteSpace($ManifestOut)) { $arguments += @('-ManifestOut',$ManifestOut) }
  $output=& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @arguments
  if ($LASTEXITCODE -ne 0) { throw ('SOURCE_TREE_FINGERPRINT_FAILED:'+$LASTEXITCODE) }
  $value=([string](@($output | Where-Object { $_.Trim() })[-1])).Trim().ToLowerInvariant()
  if ($value -notmatch '^[0-9a-f]{64}$') { throw ('SOURCE_TREE_FINGERPRINT_INVALID:'+$value) }
  return $value
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
  # Fail-closed offline observation.
  #
  # An address query that fails must never look like "no external address".
  # Silently continuing on Get-NetIPAddress produced an empty address list,
  # which was counted as zero up adapters and therefore reported the machine
  # as offline even though nothing had been observed.  A failed observation is
  # NOT_MEASURED; it is never a PASS and never an offline claim.
  try {
    $active=New-Object 'System.Collections.Generic.List[object]'
    $failures=New-Object 'System.Collections.Generic.List[string]'
    foreach ($adapter in @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
      $addresses=@()
      $queryFailed=$false
      try {
        # Windows PowerShell 5.1 refuses -InterfaceIndex with an Int32 value
        # ("Argument types do not match"), so the index is cast explicitly.
        $index=[uint32]$adapter.ifIndex
        $addresses=@(Get-NetIPAddress -InterfaceIndex $index -ErrorAction Stop | ForEach-Object { [string]$_.IPAddress })
      } catch {
        # Only a genuine "this interface has no address" is tolerated, and it
        # is recognised by the error CATEGORY, which is not localised.  Any
        # other failure means the observation did not happen and must not be
        # reported as an offline machine.
        if ($_.CategoryInfo -and $_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound) {
          $addresses=@()
        } else {
          $queryFailed=$true
          $failures.Add('ADDRESS_QUERY_FAILED:'+[string]$adapter.Name)
        }
      }
      if ($queryFailed) { continue }
      $usable=$false
      foreach ($raw in $addresses) {
        $candidate=([string]$raw).Split('%')[0]
        $ip=$null
        # [Net.IPAddress]::TryParse with a $null [ref] target raises
        # "Argument types do not match" under Windows PowerShell 5.1.
        try { $ip=[Net.IPAddress]::Parse($candidate) } catch { $ip=$null }
        if ($ip -and -not [Net.IPAddress]::IsLoopback($ip) -and
            -not $ip.Equals([Net.IPAddress]::Any) -and
            -not $ip.Equals([Net.IPAddress]::IPv6Any)) {
          $usable=$true
          break
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
    if ($failures.Count -gt 0) {
      return [ordered]@{
        status='NOT_MEASURED'
        reason='NETWORK_ADDRESS_QUERY_FAILED'
        failed_queries=@($failures)
        up_adapter_count=$null
        method='windows_powershell_up_adapters_with_nonloopback_ip'
      }
    }
    return [ordered]@{
      status='MEASURED'
      up_adapter_count=$active.Count
      up_adapters=@($active)
      method='windows_powershell_up_adapters_with_nonloopback_ip'
    }
  } catch {
    return [ordered]@{status='NOT_MEASURED';reason=$_.Exception.Message;up_adapter_count=$null}
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

    # Behavioural entry-contract check on a tree whose source-root directory
    # name is NOT ASCII.  A hard-coded non-ASCII literal is mojibake under
    # Windows PowerShell 5.1 (BOM-less scripts are read with the system ANSI
    # code page), so the source root must be resolved structurally.  The
    # characters are built from code points so that this test file itself
    # stays ASCII-only.
    $nonAsciiName=([string][char]0x958B)+([string][char]0x767A)+([string][char]0x7248)
    $nonAsciiRoot=Join-Path $testRoot $nonAsciiName
    New-Item -ItemType Directory -Path (Join-Path $nonAsciiRoot 'source/scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $nonAsciiRoot 'transfer') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nonAsciiRoot 'source/scripts/REPOSITORY_ENTRY.ps1') -Value '# contract' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $nonAsciiRoot 'transfer/TRANSFER_MANIFEST.json') -Value '{"schema_version":1}' -Encoding ASCII
    $module=Find-RepositoryEntryModule -Root $testRoot
    $expectedModule=[IO.Path]::GetFullPath((Join-Path $nonAsciiRoot 'source/scripts/REPOSITORY_ENTRY.ps1'))
    if ([IO.Path]::GetFullPath($module) -ne $expectedModule) {
      throw ('REPOSITORY_ENTRY_MODULE_DISCOVERY_SELECTED_WRONG_TREE:' + $module)
    }
    Write-Host 'REPOSITORY_DISCOVERY_CONTRACT_TEST_PASS'
  } finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Initialize-PreparedSource {
  <#
    .SYNOPSIS
      Reconstruct the prepared Source, overlay the acceptance bundle and bind
      the canonical baseline fingerprint.
    .DESCRIPTION
      The baseline MUST be the fingerprint of the real prepared tree AFTER
      every overlay, because that is the tree the Candidate builder hashes.
      Hashing before the acceptance bundle is copied in made the runner bind a
      tree the builder never sees, which fails the SOURCE_BASELINE_MISMATCH
      check for a reason unrelated to the Source itself.

      The function is shared by the live route and by the behavioural
      contract, so the contract really exercises the live ordering.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$RepositoryRoot,
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [Parameter(Mandatory=$true)][string]$PrepareScript,
    [Parameter(Mandatory=$true)][string]$AcceptancePlan,
    [Parameter(Mandatory=$true)][string]$RecoveryArchive,
    [Parameter(Mandatory=$true)][string]$RecoverySha256
  )
  $sourceDestination = Join-Path $WorkRoot 'prepared'
  $sourceRoot = & $PrepareScript -RepositoryRoot $RepositoryRoot -Destination $sourceDestination -RecoveryArchive $RecoveryArchive -ExpectedRecoverySha256 $RecoverySha256
  if (-not $sourceRoot -or -not (Test-Path -LiteralPath (Join-Path $sourceRoot 'CORE') -PathType Container)) {
    throw 'PREPARED_SOURCE_ROOT_INVALID'
  }
  $acceptanceSource = Split-Path -Parent $AcceptancePlan
  $acceptanceDest = Join-Path $sourceRoot 'ACCEPTANCE'
  if (Test-Path -LiteralPath $acceptanceDest) { Remove-Item -LiteralPath $acceptanceDest -Recurse -Force }
  Copy-Item -LiteralPath $acceptanceSource -Destination $acceptanceDest -Recurse -Force
  $baseline = Get-SourceTreeFingerprint $sourceRoot
  return [ordered]@{
    source_root = $sourceRoot
    source_destination = $sourceDestination
    baseline = $baseline
  }
}

function Invoke-RepositoryEntryContractTest {
  <#
    .SYNOPSIS
      Resolve every declared completion-route input against the REAL
      repository tree, under the interpreter that will run it.
    .DESCRIPTION
      This is the behavioural counterpart of the hosted Windows PowerShell 5.1
      contract job: it proves that the entry contract resolves on the actual
      checkout - including a source-root directory name that is not ASCII -
      instead of asserting on the runner's own text.
  #>
  if ($env:OS -ne 'Windows_NT') { throw 'REPOSITORY_ENTRY_CONTRACT_TEST_REQUIRES_WINDOWS' }
  $sourceRootDirectory=Get-RepositorySourceRoot
  $entries=Get-DeclaredRepositoryEntries -RepositoryRoot $PhysicalRepoRoot -SourceRoot $sourceRootDirectory
  $problems=Test-DeclaredRepositoryEntries -Entries $entries
  if ($problems.Count -gt 0) { throw ('REPOSITORY_ENTRY_CONTRACT_FAILED:'+($problems -join ',')) }
  $actual=Get-Sha256File -Path $entries.recovery_source
  if ($actual -ne ([string]$entries.recovery_source_sha256).ToLowerInvariant()) {
    throw ('REPOSITORY_ENTRY_CONTRACT_RECOVERY_SHA_MISMATCH:'+$actual)
  }
  $declaredBlocks=$entries.transfer_manifest.latest_complete_candidate.blocks_required
  if ($declaredBlocks) {
    $count=@(Get-ChildItem -LiteralPath $entries.donor_blocks -File -ErrorAction Stop).Count
    if ($count -ne [int]$declaredBlocks) { throw ('REPOSITORY_ENTRY_CONTRACT_DONOR_BLOCK_COUNT:'+$count) }
  }
  Write-Host 'REPOSITORY_ENTRY_CONTRACT_TEST_PASS'
}

function Invoke-PreparedBaselineContractTest {
  <#
    .SYNOPSIS
      Prove that the baseline the runner binds is the fingerprint of the tree
      the Candidate builder will hash.
    .DESCRIPTION
      The contract re-derives the fingerprint of the prepared tree after the
      acceptance overlay and compares it with the baseline produced by the
      shared preparation function.  A regression that hashes the tree before
      the overlay fails this contract instead of failing on the real machine.
  #>
  if ($env:OS -ne 'Windows_NT') { throw 'PREPARED_BASELINE_CONTRACT_TEST_REQUIRES_WINDOWS' }
  $testRoot=Join-Path ([IO.Path]::GetTempPath()) ('fqa prepared baseline ' + [Guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $sourceRootDirectory=Get-RepositorySourceRoot
    $entries=Get-DeclaredRepositoryEntries -RepositoryRoot $PhysicalRepoRoot -SourceRoot $sourceRootDirectory
    $prepared=Initialize-PreparedSource -RepositoryRoot $PhysicalRepoRoot -WorkRoot $testRoot `
      -PrepareScript $entries.prepare_script -AcceptancePlan $entries.acceptance_plan `
      -RecoveryArchive $entries.recovery_source -RecoverySha256 $entries.recovery_source_sha256
    $recomputed=Get-SourceTreeFingerprint $prepared.source_root
    if ($recomputed -ne $prepared.baseline) {
      throw ('PREPARED_BASELINE_CONTRACT_MISMATCH:bound='+$prepared.baseline+':actual='+$recomputed)
    }
    $builderScript=Join-Path $prepared.source_root 'scripts/PHASE3_OVERLAY_REBUILD.ps1'
    if (-not (Test-Path -LiteralPath $builderScript -PathType Leaf)) { throw 'PREPARED_BASELINE_BUILDER_SCRIPT_MISSING' }
    Write-Host 'PREPARED_BASELINE_CONTRACT_TEST_PASS'
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
      'SERIES_HQ_READBACK.json',
      'ENVIRONMENT_AUDIT.json',
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
if ($RepositoryEntryContractTest) {
  . (Resolve-RepositoryEntryModule)
  Invoke-RepositoryEntryContractTest
  exit 0
}
if ($PreparedBaselineContractTest) {
  . (Resolve-RepositoryEntryModule)
  Invoke-PreparedBaselineContractTest
  exit 0
}

try {
  if ($env:OS -ne 'Windows_NT') { throw 'LOCAL_COMPLETION_REQUIRES_WINDOWS' }
  . (Resolve-RepositoryEntryModule)

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

  # --- 0/8 Real-machine handoff preflight -----------------------------------
  # Every declared input is resolved through the shared entry contract.  The
  # contract is derived from the repository structure and the transfer
  # manifest, never from a hard-coded directory name, so it resolves the same
  # way under Windows PowerShell 5.1 and PowerShell 7.
  Write-Host '=== 0/8 Real-machine handoff preflight ==='
  $sourceRootDirectory = Get-RepositorySourceRoot
  $declaredEntries = Get-DeclaredRepositoryEntries -RepositoryRoot $RepoRoot -SourceRoot $sourceRootDirectory
  $entryProblems = Test-DeclaredRepositoryEntries -Entries $declaredEntries
  if ($entryProblems.Count -gt 0) {
    throw ('REAL_MACHINE_HANDOFF_PREFLIGHT_FAILED:' + ($entryProblems -join ','))
  }
  $transfer = $declaredEntries.transfer_manifest
  $Summary.handoff_preflight = 'PASS'
  Write-Summary

  $Summary.network_snapshot = Get-NetworkSnapshot
  $PathBefore = Get-PathSnapshot
  Write-Summary

  Write-Host '=== 1/8 Reconstruct preserved v0.3.3 donor ==='
  $complete = $declaredEntries.donor_root
  $join = $declaredEntries.donor_join
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

  Write-Host '=== 2/8 Reconstruct current Source and build Candidate ==='
  $prepare = $declaredEntries.prepare_script
  $rebuildDeclared = $declaredEntries.rebuild_script
  $plan = $declaredEntries.acceptance_plan
  $checkedOutSourceRoot = Split-Path -Parent (Split-Path -Parent $prepare)
  if (-not (Test-Path -LiteralPath (Join-Path $checkedOutSourceRoot 'CORE') -PathType Container)) { throw 'CHECKED_OUT_SOURCE_ROOT_INVALID' }
  $Summary.source_tree_fingerprint = Get-SourceTreeFingerprint $checkedOutSourceRoot
  Write-Summary

  $recoverySource = $declaredEntries.recovery_source
  $prepared = Initialize-PreparedSource -RepositoryRoot $RepoRoot -WorkRoot $WorkRoot `
    -PrepareScript $prepare -AcceptancePlan $plan `
    -RecoveryArchive $recoverySource -RecoverySha256 $declaredEntries.recovery_source_sha256
  $sourceRoot = $prepared.source_root
  $Summary.prepared_source_fingerprint = $prepared.baseline
  Write-Summary

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

  Write-Host '=== 3/8 Fresh Candidate Source regression ==='
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

  Write-Host '=== 4/8 Fresh Candidate START_QA selftest ==='
  $selfRun=Invoke-NativeLogged -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments @('/d','/c','START_QA.cmd','-SelfTest') -WorkingDirectory $SelftestRoot -LogPath (Join-Path $OutRoot 'START_QA_SELFTEST.log')
  $selfCode=$selfRun.ExitCode
  Export-TransientEvidence
  if ($selfCode -ne 0) { throw ('WINDOWS_SELFTEST_FAILED:' + $selfCode) }
  $Summary.windows_selftest='PASS'
  Write-Summary

  Remove-Item -LiteralPath $SelftestRoot -Recurse -Force
  $SelftestRoot=$null

  Write-Host '=== 5/8 Fresh PoliticsTrasport -> codegeas -> PoliticsTrasport ==='
  $ControllerRoot = Join-Path $WorkRoot 'controller'
  [IO.Compression.ZipFile]::ExtractToDirectory($candidate,$ControllerRoot)
  $controllerPython = Join-Path $ControllerRoot 'RUNTIME\python\python.exe'
  $seriesScript = Join-Path $ControllerRoot 'ACCEPTANCE\run_series.py'
  $SeriesOut = Join-Path $WorkRoot 'series'
  $seriesArgs=@('-B','-E','-s',$seriesScript,'--candidate',$candidate,'--expected-sha',$candidateSha,'--output',$SeriesOut)
  if (-not [string]::IsNullOrWhiteSpace($SalesReviewEvidence)) {
    $reviewPath=[IO.Path]::GetFullPath($SalesReviewEvidence)
    if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
      throw ('SALES_REVIEW_EVIDENCE_MISSING:'+$reviewPath)
    }
    $seriesArgs += @('--review-evidence',$reviewPath)
    $Summary.sales_review_evidence=$reviewPath
  }
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

  # The series-level headquarters readback.  The per-run domains cannot see
  # that the same target ran twice, so the Management gate is decided over
  # the whole A-B-A series and the Sales gate over the ingested review
  # evidence.  Both verdicts are REPORTED here; they never promote the
  # technical gate, and Product Acceptance / Stable stay HOLD.
  $hqReadbackPath=Join-Path $SeriesOut 'SERIES_HQ_READBACK.json'
  if (Test-Path -LiteralPath $hqReadbackPath -PathType Leaf) {
    $hqReadback=Get-Content -LiteralPath $hqReadbackPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($hqReadback.PSObject.Properties.Name -contains 'management' -and $hqReadback.management) {
      $Summary.management_gate=[string]$hqReadback.management.status
    }
    if ($hqReadback.PSObject.Properties.Name -contains 'sales' -and $hqReadback.sales) {
      $Summary.sales_gate=[string]$hqReadback.sales.status
    }
    if ($hqReadback.PSObject.Properties.Name -contains 'human_test' -and $hqReadback.human_test) {
      $Summary.human_test=[string]$hqReadback.human_test
    }
    if ($hqReadback.PSObject.Properties.Name -contains 'status') {
      $Summary.independent_hq_final_verdict=[string]$hqReadback.status
    }
  }

  # Persistent-environment audit: Registry environment values and the top
  # level of every Program Files root, before and after the series.  A
  # measurement that did not happen is reported as NOT_MEASURED and is never
  # reported as unchanged.
  $environmentAuditPath=Join-Path $SeriesOut 'ENVIRONMENT_AUDIT.json'
  if (Test-Path -LiteralPath $environmentAuditPath -PathType Leaf) {
    $environmentAudit=Get-Content -LiteralPath $environmentAuditPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($environmentAudit.PSObject.Properties.Name -contains 'comparison' -and $environmentAudit.comparison) {
      $Summary.registry_write_audit=[string]$environmentAudit.comparison.registry_environment_status
      $Summary.program_files_write_audit=[string]$environmentAudit.comparison.program_files_status
    }
  }
  Write-Summary

  Write-Host '=== 6/8 Fresh preserved predecessor rollback qualification ==='
  $rollbackScript = $declaredEntries.rollback_script
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

  Write-Host '=== 7/8 Local environment readback ==='
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
