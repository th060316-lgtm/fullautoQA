param([string[]]$Profile = @(), [int]$Seed = 12345, [string]$Backend = '', [ValidateSet('logic','playable')][string]$Prototype = '', [double]$SoakSeconds = -1, [string]$Baseline = '', [switch]$NoFaults, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if ($SelfTest) {
  $Profile = @('PROFILES/fixture_grid.json','PROFILES/fixture_management.json','PROFILES/fixture_narrative.json','PROFILES/fixture_procedural.json','PROFILES/fixture_realtime.json')
}
$qaRoot = $PSScriptRoot
$resultsDir = Join-Path $qaRoot 'RESULTS'
# Hash before Python starts without relying on PowerShell module auto-discovery.
function Get-QASHA256([string]$path) {
  $stream = [IO.File]::OpenRead($path)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
  finally { $sha.Dispose(); $stream.Dispose() }
}
function Read-Json([string]$path) {
  Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
}
function Resolve-Results {
  $settings = Read-Json (Join-Path $qaRoot 'acceptance_manifest.json')
  $relative = if ($settings.paths.results) { [string]$settings.paths.results } else { 'RESULTS' }
  $path = [IO.Path]::GetFullPath((Join-Path $qaRoot $relative))
  if (-not $path.StartsWith($qaRoot+[IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Results path must be inside QA root' }
  return $path
}
function Read-ZipJson($entry) {
  if ($null -eq $entry) { throw 'Required ZIP JSON entry missing' }
  $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8, $true)
  try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
}
function Test-ResultZip([string]$path, [string]$expectedRun, [bool]$requireManifest = $true) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($path)
  try {
    $entries = @{}; $hashes = @{}
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName
      if ($entries.ContainsKey($name)) { throw ('Duplicate ZIP entry: '+$name) }
      $entries[$name] = $entry
      if ($name.EndsWith('/')) { continue }
      $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
      try { $hashes[$name] = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
      finally { $sha.Dispose(); $stream.Dispose() }
    }
    $result = Read-ZipJson $entries['result.json']
    if ($result.run_id -ne $expectedRun -or -not $result.overall) { throw 'ZIP run identity/result missing' }
    if ($requireManifest) {
      $manifest = @(Read-ZipJson $entries['evidence_manifest.json'])
      $seen = @{}
      foreach ($item in $manifest) {
        # Exclusions must be recorded outside this included-evidence manifest.
        if ($seen.ContainsKey([string]$item.file)) { throw ('Duplicate evidence: '+$item.file) }
        $seen[[string]$item.file] = $true
        if (-not $entries.ContainsKey([string]$item.file)) { throw ('Evidence not in ZIP: '+$item.file) }
        if ($hashes[[string]$item.file] -ne $item.sha256 -or $entries[[string]$item.file].Length -ne $item.size) { throw ('Evidence hash/size mismatch: '+$item.file) }
      }
      foreach ($name in $hashes.Keys) {
        if ($name -ne 'evidence_manifest.json' -and -not $seen.ContainsKey([string]$name)) { throw ('Unmanifested ZIP entry: '+$name) }
      }
      foreach ($case in $result.results) {
        foreach ($ref in $case.evidence) {
          if (-not $entries.ContainsKey([string]$ref) -or -not $seen.ContainsKey([string]$ref)) { throw ('Result evidence missing: '+$ref) }
        }
      }
      if ($entries.ContainsKey('events.jsonl')) {
        $reader = New-Object IO.StreamReader($entries['events.jsonl'].Open(), [Text.Encoding]::UTF8, $true)
        try {
          while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            $event = $line | ConvertFrom-Json
            $refs = @($event.evidence)
            if ($event.file) { $refs += [string]$event.file }
            foreach ($ref in $refs) {
              if ($null -ne $ref -and (-not $entries.ContainsKey([string]$ref) -or -not $seen.ContainsKey([string]$ref))) { throw ('Event evidence missing: '+$ref) }
            }
          }
        } finally { $reader.Dispose() }
      }
    }
    return $result
  } finally { $zip.Dispose() }
}
function Write-BootstrapFailure([string]$message) {
  $run = 'bootstrap_' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmss') + '_' + [Guid]::NewGuid().ToString('N').Substring(0,8)
  $out = Join-Path $resultsDir $run; $temporary = Join-Path $resultsDir ($run+'.tmp.zip')
  try { [void][IO.Directory]::CreateDirectory($out) }
  catch { Write-Host ('RESULT SAVE FAILED: '+$_.Exception.Message+'; bootstrap error: '+$message); return }
  $result = @{run_id=$run;overall='HARNESS_ERROR';completion_certified=$false;results=@(@{test_case='bootstrap';status='HARNESS_ERROR';reason_code='BOOTSTRAP_FAILURE';detail=$message;evidence=@('bootstrap_error.txt')});windows_e2e_executed=$false}
  try { $result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $out 'result.json') } catch { Write-Host ('RESULT JSON SAVE FAILED: '+$_.Exception.Message) }
  try { $message | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $out 'bootstrap_error.txt') } catch { Write-Host ('DIAGNOSTIC SAVE FAILED: '+$_.Exception.Message) }
  try { '<!doctype html><meta charset="utf-8"><h1>HARNESS_ERROR</h1><p>See result.json and bootstrap_error.txt.</p>' | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $out 'report.html') } catch { Write-Host ('REPORT SAVE FAILED: '+$_.Exception.Message) }
  try { 'BOOTSTRAP FAILED: HARNESS_ERROR' | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $out 'SUMMARY.txt') } catch { Write-Host ('SUMMARY SAVE FAILED: '+$_.Exception.Message) }
  try {
    $diagnosticManifest = @(Get-ChildItem -LiteralPath $out -File | Where-Object { $_.Name -ne 'evidence_manifest.json' -and $_.Name -ne 'RESULT_FOR_CHATGPT.zip' } | ForEach-Object {
      @{file=$_.Name;size=$_.Length;sha256=(Get-QASHA256 $_.FullName);run_id=$run}
    })
    ConvertTo-Json -InputObject $diagnosticManifest -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $out 'evidence_manifest.json')
  } catch { Write-Host ('EVIDENCE MANIFEST SAVE FAILED: '+$_.Exception.Message) }
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($out,$temporary)
    $null = Test-ResultZip $temporary $run $true
    $final = Join-Path $out 'RESULT_FOR_CHATGPT.zip'
    Move-Item -LiteralPath $temporary -Destination $final
    Write-Host ("BOOTSTRAP FAILED`nOverall Result: HARNESS_ERROR`nResult ZIP Path: "+$final)
  } catch { Write-Host ('RESULT ZIP SAVE/VALIDATION FAILED: '+$_.Exception.Message+'; diagnostic directory: '+$out) }
  finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue } }
}
try {
  # Resolve configured storage before integrity checks, so failures use the same destination.
  $resultsDir = Resolve-Results
  if (-not [Environment]::Is64BitProcess) { throw 'Windows x64 PowerShell required' }
  $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qaRoot 'core_manifest.json') | ConvertFrom-Json
  foreach ($f in $manifest.files) {
    $path = [IO.Path]::GetFullPath((Join-Path $qaRoot $f.path))
    if (-not $path.StartsWith($qaRoot+[IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'CORE path escape' }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('CORE missing: '+$f.path) }
    if ((Get-Item -LiteralPath $path).Length -ne $f.size) { throw ('CORE size: '+$f.path) }
    if ((Get-QASHA256 $path) -ne $f.sha256) { throw ('CORE hash: '+$f.path) }
  }
  # Validate the bundled interpreter and its DLL/stdlib files BEFORE Python executes.
  $runtime = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qaRoot 'python_manifest.json') | ConvertFrom-Json
  foreach ($f in $runtime.files) {
    $path = [IO.Path]::GetFullPath((Join-Path $qaRoot $f.path))
    if (-not $path.StartsWith($qaRoot+[IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Python path escape' }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Python missing: '+$f.path) }
    if ((Get-Item -LiteralPath $path).Length -ne $f.size) { throw ('Python size: '+$f.path) }
    if ((Get-QASHA256 $path) -ne $f.sha256) { throw ('Python hash: '+$f.path) }
  }
  $python = Join-Path $qaRoot 'RUNTIME\python\python.exe'
  $env:PYTHONNOUSERSITE = '1'
  Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
  $qaArgs = @('-B','-E','-s',(Join-Path $qaRoot 'CORE\runner.py'),'--root',$qaRoot,'--seed',$Seed)
  foreach ($qaProfile in $Profile) { $qaArgs += @('--profile',$qaProfile) }
  if ($Prototype) { $qaArgs += @('--prototype',$Prototype) }
  if ($Backend) { $qaArgs += @('--backend',$Backend) }
  if ($SoakSeconds -ge 0) { $qaArgs += @('--soak-seconds',$SoakSeconds) }
  if ($Baseline) { $qaArgs += @('--baseline',$Baseline) }
  if ($NoFaults) { $qaArgs += '--no-faults' }
  $existingRuns = @{}
  if (Test-Path -LiteralPath $resultsDir) {
    Get-ChildItem -LiteralPath $resultsDir -Directory | ForEach-Object { $existingRuns[$_.Name] = $true }
  }
  & $python @qaArgs
  $code = $LASTEXITCODE
  $candidates = @()
  $latestPath = Join-Path $resultsDir 'latest.json'
  try {
    $latest = Read-Json $latestPath
    if ($latest.run_id -and -not $existingRuns.ContainsKey([string]$latest.run_id)) {
      $expected = Join-Path (Join-Path $resultsDir ([string]$latest.run_id)) 'RESULT_FOR_CHATGPT.zip'
      if ([IO.Path]::GetFullPath([string]$latest.result_zip) -eq [IO.Path]::GetFullPath($expected)) { $candidates += $expected }
    }
  } catch { Write-Host ('Latest index unavailable; checking this run directories: '+$_.Exception.Message) }
  if (Test-Path -LiteralPath $resultsDir) {
    $candidates += @(Get-ChildItem -LiteralPath $resultsDir -Directory | Where-Object { -not $existingRuns.ContainsKey($_.Name) -and -not $_.Name.StartsWith('bootstrap_') } | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object { Join-Path $_.FullName 'RESULT_FOR_CHATGPT.zip' })
  }
  $validPath = $null; $validResult = $null
  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    try {
      $runName = Split-Path (Split-Path $candidate -Parent) -Leaf
      # Only immediate children of configured storage qualify as fresh runs.
      if ([IO.Path]::GetFullPath((Split-Path (Split-Path $candidate -Parent) -Parent)) -ne [IO.Path]::GetFullPath($resultsDir)) { continue }
      $validResult = Test-ResultZip $candidate $runName
      $validPath = $candidate; break
    } catch { Write-Host ('Result ZIP rejected: '+$candidate+'; '+$_.Exception.Message) }
  }
  if (-not $validPath) { throw 'No fresh validated QA Result ZIP found; old results were not reused.' }
  Write-Host ("QA COMPLETE`nOverall Result: "+$validResult.overall+"`nResult ZIP Path: "+$validPath)
  # Presentation failure must never replace the completed QA result.
  try { Start-Process -FilePath (Join-Path (Split-Path $validPath -Parent) 'report.html') }
  catch {
    Write-Host ('REPORT DISPLAY FAILED; QA result retained: '+$_.Exception.Message)
    try { $_.Exception.Message | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $resultsDir ($validResult.run_id+'_display_notice.txt')) }
    catch { Write-Host ('DISPLAY DIAGNOSTIC SAVE FAILED: '+$_.Exception.Message) }
  }
  if ($null -eq $code) { exit 2 }
  exit $code
} catch {
  Write-BootstrapFailure $_.Exception.Message
  exit 2
}

