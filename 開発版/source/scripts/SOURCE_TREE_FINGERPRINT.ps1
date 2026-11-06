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
$ordered=@($records | Sort-Object -Property @{Expression={$_.path};Ascending=$true} -Culture '' -CaseSensitive)
# Sort-Object still uses host comparison rules in some legacy versions. Re-sort
# the canonical row strings with the CLR ordinal comparer before hashing.
$rows=New-Object 'System.Collections.Generic.List[string]'
foreach($record in $ordered) {
  $rows.Add(([string]$record.path + [char]9 + [string]$record.size + [char]9 + [string]$record.sha256))
}
$array=$rows.ToArray()
[Array]::Sort($array,[StringComparer]::Ordinal)
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
    files=@($records | Sort-Object path | ForEach-Object {
      [ordered]@{path=$_.path;size=$_.size;sha256=$_.sha256}
    })
  }
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestOut -Encoding UTF8
}
[Console]::Out.WriteLine($fingerprint)
