# FullAutoQA byte-preserving offline transfer reconstruction.
# This verifies transport completeness; it does not certify game QA acceptance.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$temporary = $null

function Get-SHA256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Get-SafePath([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) {
        throw 'MANIFEST_PATH_INVALID'
    }
    $parts = $Relative -split '[\\/]'
    if ($parts -contains '..' -or $parts -contains '.' -or $parts -contains '') { throw 'MANIFEST_PATH_INVALID' }
    $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $Relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
    $prefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'MANIFEST_PATH_ESCAPE' }
    # A relative path through a junction/symlink must not leave this transfer set.
    $inspect = $full
    while ($inspect -and -not $inspect.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $inspect) {
            $item = Get-Item -LiteralPath $inspect -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'MANIFEST_REPARSE_POINT' }
        }
        $inspect = [System.IO.Path]::GetDirectoryName($inspect)
    }
    return $full
}

try {
    $root = [System.IO.Path]::GetFullPath($PSScriptRoot)
    $manifestPath = Join-Path $root 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$manifest.size -le 0) { throw 'MANIFEST_ARCHIVE_INVALID' }
    if ([string]$manifest.file -ne [System.IO.Path]::GetFileName([string]$manifest.file) -or [System.IO.Path]::GetExtension([string]$manifest.file) -ne '.zip') { throw 'MANIFEST_OUTPUT_INVALID' }
    $blocks = @($manifest.blocks)
    if ($blocks.Count -le 0 -or $blocks.Count -ne [int]$manifest.block_count) { throw 'MANIFEST_BLOCK_COUNT_INVALID' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $paths = New-Object 'System.Collections.Generic.List[string]'
    [long]$sum = 0
    [int]$index = 0
    foreach ($block in $blocks) {
        $index++
        $path = Get-SafePath $root ([string]$block.path)
        if (-not $seen.Add($path)) { throw 'MANIFEST_DUPLICATE_BLOCK' }
        if ($block.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$block.size -le 0) { throw 'MANIFEST_BLOCK_INVALID' }
        if (-not [System.IO.File]::Exists($path)) { throw ('BLOCK_MISSING: ' + $block.path) }
        if ((Get-Item -LiteralPath $path).Length -ne [long]$block.size) { throw ('BLOCK_SIZE_MISMATCH: ' + $block.path) }
        if ((Get-SHA256 $path) -ne ([string]$block.sha256).ToLowerInvariant()) { throw ('BLOCK_HASH_MISMATCH: ' + $block.path) }
        $sum += [long]$block.size
        $paths.Add($path)
        Write-Host ('Verified block {0}/{1}' -f $index, $blocks.Count)
    }
    if ($sum -ne [long]$manifest.size) { throw 'MANIFEST_TOTAL_SIZE_MISMATCH' }
    $output = Get-SafePath $root ([string]$manifest.file)
    if ([System.IO.File]::Exists($output)) {
        if ((Get-Item -LiteralPath $output).Length -eq [long]$manifest.size -and (Get-SHA256 $output) -eq ([string]$manifest.sha256).ToLowerInvariant()) {
            Write-Host 'JOIN COMPLETE: existing archive is identical.'
            Write-Host ('Archive: ' + $output)
            exit 0
        }
        throw 'OUTPUT_ALREADY_EXISTS_DIFFERENT: existing file was preserved.'
    }
    if (Test-Path -LiteralPath $output) { throw 'OUTPUT_PATH_ALREADY_EXISTS' }
    $temporary = Join-Path $root ('.join-' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
    $destination = [System.IO.File]::Open($temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        foreach ($path in $paths) {
            $source = [System.IO.File]::OpenRead($path)
            try { $source.CopyTo($destination, 1048576) } finally { $source.Dispose() }
        }
    } finally { $destination.Dispose() }
    if ((Get-Item -LiteralPath $temporary).Length -ne [long]$manifest.size) { throw 'JOINED_SIZE_MISMATCH' }
    if ((Get-SHA256 $temporary) -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw 'JOINED_HASH_MISMATCH' }
    [System.IO.File]::Move($temporary, $output)
    $temporary = $null
    Write-Host 'JOIN COMPLETE: all block hashes and the complete archive hash match.'
    Write-Host ('Archive: ' + $output)
    Write-Host 'Extract the archive before running START_QA.cmd.'
    exit 0
} catch {
    [Console]::Error.WriteLine('JOIN FAILED: ' + $_.Exception.Message)
    exit 1
} finally {
    if ($temporary -and [System.IO.File]::Exists($temporary)) {
        try { [System.IO.File]::Delete($temporary) } catch { [Console]::Error.WriteLine('Temporary file cleanup failed: ' + $temporary) }
    }
}
