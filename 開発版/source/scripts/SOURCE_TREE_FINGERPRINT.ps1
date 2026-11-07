# Canonical FullAutoQA Source-tree fingerprint.
#
# This is the ONE implementation of the Source-tree identity used by the
# completion route.  The runner (producer) and the Candidate builder
# (verifier) must agree on the exact bytes they are talking about, so the
# algorithm lives here and nowhere else.
#
# Canonical row format (also implemented by scripts/source_tree_immutability.py):
#
#   * every regular file under -Root is collected;
#   * files inside a "__pycache__" directory and files ending in ".pyc" or
#     ".pyo" are excluded - they are transient bytecode caches, not Source;
#   * the relative path is POSIX style and relative to -Root;
#   * one row per file:  <relative path> TAB <size> TAB <sha256 lowercase hex>
#   * rows are sorted ORDINALLY by the relative path (not by culture, not by
#     file-system enumeration order);
#   * rows are joined with a single LF and the payload is hashed as UTF-8.
#
# The result is independent of PowerShell version, host newline, culture and
# enumeration order.
#
# Three copies of this algorithm used to exist - one in the runner, one in the
# Candidate builder and one in the CI workflow.  They agreed with each other
# but were not reproducible: the rows were joined with the host newline (CRLF
# on Windows, LF on Linux), sorted with the current culture's comparer, and
# bytecode caches were counted as Source.
#
# ASCII-only invariant: this file must never contain a byte above 0x7F.
# The source test suite (TESTS/test_windows_script_encoding.py) enforces it.
#
# Usage:
#   powershell.exe -File SOURCE_TREE_FINGERPRINT.ps1 -Root <dir> [-ManifestOut <file>]
#
# The fingerprint is written to standard output.  With -ManifestOut the full
# row manifest is written as JSON so that the same rows can be compared by the
# immutability contract without re-hashing the tree.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$ManifestOut = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SHA256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose(); $stream.Dispose() }
}

function Test-ExcludedSourcePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $segments = $RelativePath.Split(@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
                                     [StringSplitOptions]::RemoveEmptyEntries)
    foreach ($segment in $segments) {
        if ($segment -eq '__pycache__') { return $true }
    }
    $extension = [IO.Path]::GetExtension($RelativePath)
    if ($extension -ieq '.pyc' -or $extension -ieq '.pyo') { return $true }
    return $false
}

$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    throw ('SOURCE_FINGERPRINT_ROOT_MISSING:' + $rootFull)
}
$prefix = $rootFull + [IO.Path]::DirectorySeparatorChar

$byPath = @{}
$paths = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -Attributes !ReparsePoint)) {
    $relative = $file.FullName.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar, '/')
    if (Test-ExcludedSourcePath -RelativePath $relative) { continue }
    $byPath[[string]$relative] = $file
    $paths.Add([string]$relative)
}
$pathArray = $paths.ToArray()
[Array]::Sort($pathArray, [StringComparer]::Ordinal)

$rows = New-Object 'System.Collections.Generic.List[string]'
foreach ($path in $pathArray) {
    $file = $byPath[$path]
    $rows.Add(($path + [char]9 + [string]$file.Length + [char]9 + (Get-SHA256 $file.FullName)))
}
$payload = [string]::Join([char]10, $rows.ToArray())
$bytes = [Text.Encoding]::UTF8.GetBytes($payload)
$algorithm = [Security.Cryptography.SHA256]::Create()
try { $fingerprint = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
finally { $algorithm.Dispose() }

if (-not [string]::IsNullOrWhiteSpace($ManifestOut)) {
    $manifest = [ordered]@{
        schema_version = 1
        algorithm = 'relative-path-tab-size-tab-sha256; rows ordinal; LF; UTF-8; excludes __pycache__ and .pyc/.pyo'
        root = $rootFull
        fingerprint = $fingerprint
        file_count = $pathArray.Length
        files = @($pathArray | ForEach-Object {
            $file = $byPath[$_]
            [ordered]@{ path = $_; size = [long]$file.Length; sha256 = (Get-SHA256 $file.FullName) }
        })
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestOut -Encoding UTF8
}

[Console]::Out.WriteLine($fingerprint)
