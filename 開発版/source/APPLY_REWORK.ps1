$ErrorActionPreference='Stop'
try {
 $patch=$PSScriptRoot
 $m=Get-Content -Raw (Join-Path $patch 'BASE_Transport_Manifest.json') | ConvertFrom-Json
 $search=@($patch,(Split-Path $patch))
 $location=$null
 foreach($dir in $search) { if(Test-Path -LiteralPath (Join-Path $dir $m.parts[0].file)) {$location=$dir;break} }
 if(-not $location) {throw 'Original ten .001-.010 volumes must be beside the update folder or its parent. No original file was changed.'}
 $base=Join-Path $location $m.archive
 if(-not (Test-Path -LiteralPath $base)) {
  foreach($part in $m.parts) {
   $p=Join-Path $location $part.file
   if((Get-Item -LiteralPath $p).Length -ne $part.size -or (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() -ne $part.sha256) {throw ('Base volume mismatch: '+$part.file)}
  }
  $o=[IO.File]::Open($base,[IO.FileMode]::CreateNew)
  try { foreach($part in $m.parts) {$i=[IO.File]::OpenRead((Join-Path $location $part.file));try {$i.CopyTo($o)}finally{$i.Dispose()}} }finally{$o.Dispose()}
 }
 if((Get-FileHash -LiteralPath $base -Algorithm SHA256).Hash.ToLowerInvariant() -ne $m.archive_sha256) {throw 'Original archive hash mismatch; existing file was not overwritten'}
 $target=Join-Path $location ('FullAutoQA_v020_'+[Guid]::NewGuid().ToString('N').Substring(0,8))
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 [IO.Compression.ZipFile]::ExtractToDirectory($base,$target)
 $overlay=Get-Content -Raw (Join-Path $patch 'overlay_manifest_v020.json') | ConvertFrom-Json
 foreach($f in $overlay.files) {
  $src=[IO.Path]::GetFullPath((Join-Path $patch $f.path));$dst=[IO.Path]::GetFullPath((Join-Path $target $f.path))
  if(-not $src.StartsWith($patch+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not $dst.StartsWith($target+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'Overlay path escape'}
  if((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant() -ne $f.sha256) {throw ('Overlay hash mismatch: '+$f.path)}
  [IO.Directory]::CreateDirectory((Split-Path $dst))|Out-Null
  [IO.File]::Copy($src,$dst,$true)
 }
 # Only the new working copy is altered. Old source files and old Drive objects are retained.
 $python=Join-Path $target 'RUNTIME\python\python.exe'
 $archive=Join-Path $location ('FullAutoQA_v0.2_CANDIDATE_'+[IO.Path]::GetFileName($target)+'.zip')
 & $python -B (Join-Path $target 'DEVELOPER\build_versioned_zip.py') --root $target --output $archive
 if($LASTEXITCODE -ne 0) {throw 'Candidate reconstruction failed'}
 Write-Host ('New candidate archive: '+$archive)
 & (Join-Path $target 'START_QA.cmd')
 exit $LASTEXITCODE
} catch {Write-Error $_.Exception.Message;exit 2}
