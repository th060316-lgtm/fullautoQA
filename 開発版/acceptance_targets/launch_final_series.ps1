$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$identity=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'FINAL_CANDIDATE_IDENTITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([IO.Path]::GetFileName($identity.candidate_file) -ne $identity.candidate_file) { throw 'UNSAFE_CANDIDATE_FILE_NAME' }
$zip=Join-Path $PSScriptRoot $identity.candidate_file
function SHA256([string]$Path) {
  $stream=[IO.File]::OpenRead($Path);$hash=[Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
  finally { $stream.Dispose();$hash.Dispose() }
}
if ((Get-Item -LiteralPath $zip).Length -ne $identity.candidate_size -or (SHA256 $zip) -ne $identity.candidate_sha256) { throw 'CANDIDATE_SIZE_OR_SHA_MISMATCH' }
$controller=Join-Path $PSScriptRoot ('FullAutoQA_controller_'+[Guid]::NewGuid().ToString('N'))
$output=Join-Path $PSScriptRoot ('FullAutoQA_acceptance_'+[Guid]::NewGuid().ToString('N'))
$archive=[IO.Compression.ZipFile]::OpenRead($zip)
try {
  foreach ($entry in $archive.Entries) {
    $name=$entry.FullName.Replace('\','/')
    if ($name.StartsWith('/') -or $name.Contains(':') -or @($name.Split('/')) -contains '..') { throw 'UNSAFE_CANDIDATE_ARCHIVE' }
  }
} finally { $archive.Dispose() }
[IO.Compression.ZipFile]::ExtractToDirectory($zip,$controller)
$python=Join-Path $controller 'RUNTIME/python/python.exe'
& $python -B -E -s (Join-Path $controller 'ACCEPTANCE/run_series.py') --candidate $zip --expected-sha $identity.candidate_sha256 --output $output
$code=$LASTEXITCODE
Write-Host ('Acceptance evidence: '+$output)
Write-Host 'Technical results, independent HQ judgments, Human test and Product/Stable acceptance remain separate.'
exit $code
