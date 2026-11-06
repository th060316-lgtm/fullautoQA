# Canonical FullAutoQA Source-tree fingerprint.
# The result is independent of PowerShell culture/version and host newline.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Root,
  [string]$ManifestOut=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-SHA256([string]$Path) {
  $stream=[IO.File]::OpenRead($Path)
  $hash=[Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
  finally { $hash.Dispose(); $stream.Dispose() }
}

$rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { throw 'SOURCE_FINGERPRINT_ROOT_MISSING' }
$prefix=$rootFull+[IO.Path]::DirectorySeparatorChar
$records=New-Object 'System.Collections.Generic.List[object]'
foreach($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File)) {
  $relative=$file.FullName.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,'/')
  $records.Add([pscustomobject]@{
    path=$relative
    size=[long]$file.Length
    sha256=Get-SHA256 $file.FullName
  })
}
$byPath=@{}
$paths=New-Object 'System.Collections.Generic.List[string]'
foreach($record in $records) {
  $byPath[[string]$record.path]=$record
  $paths.Add([string]$record.path)
}
$pathArray=$paths.ToArray()
[Array]::Sort($pathArray,[StringComparer]::Ordinal)
$rows=New-Object 'System.Collections.Generic.List[string]'
foreach($path in $pathArray) {
  $record=$byPath[$path]
  $rows.Add(($path + [char]9 + [string]$record.size + [char]9 + [string]$record.sha256))
}
$array=$rows.ToArray()
$payload=[string]::Join([char]10,$array)
$bytes=[Text.Encoding]::UTF8.GetBytes($payload)
$alg=[Security.Cryptography.SHA256]::Create()
try { $fingerprint=([BitConverter]::ToString($alg.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
finally { $alg.Dispose() }

if (-not [string]::IsNullOrWhiteSpace($ManifestOut)) {
  $manifest=[ordered]@{
    schema_version=1
    algorithm='relative-path-tab-size-tab-sha256; rows ordinal; LF; UTF-8'
    root=$rootFull
    fingerprint=$fingerprint
    file_count=$array.Length
    files=@($pathArray | ForEach-Object {
      $record=$byPath[$_]
      [ordered]@{path=$record.path;size=$record.size;sha256=$record.sha256}
    })
  }
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestOut -Encoding UTF8
}
[Console]::Out.WriteLine($fingerprint)
