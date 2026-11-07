# Phase 3: regenerate core_manifest.json through the Candidate's authoritative code path.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Tree)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Tree=[IO.Path]::GetFullPath($Tree)
$python=Join-Path $Tree 'RUNTIME\python\python.exe'
$release=Join-Path $Tree 'CORE\release_manifest.py'
$manifest=Join-Path $Tree 'core_manifest.json'
if (-not (Test-Path -LiteralPath $Tree -PathType Container)) { throw 'TREE_MISSING' }
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'BUNDLED_PYTHON_MISSING' }
if (-not (Test-Path -LiteralPath $release -PathType Leaf)) { throw 'RELEASE_MANIFEST_MISSING' }
if (Test-Path -LiteralPath $manifest) { Remove-Item -LiteralPath $manifest -Force }
Push-Location $Tree
try {
    # Do not use -I here: release_manifest.py imports common.py from the same CORE directory.
    & $python '-B' '-E' '-s' $release
    if ($LASTEXITCODE -ne 0) { throw ('RELEASE_MANIFEST_FAILED:'+ $LASTEXITCODE) }
} finally { Pop-Location }
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'MANIFEST_NOT_CREATED' }
$m=Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $m.core_version) { throw 'MANIFEST_CORE_VERSION_MISSING' }
if (-not $m.schema_version) { throw 'MANIFEST_SCHEMA_VERSION_MISSING' }
if (-not $m.capabilities -or @($m.capabilities).Count -eq 0) { throw 'MANIFEST_CAPABILITIES_MISSING' }
if (-not $m.files -or @($m.files).Count -eq 0) { throw 'MANIFEST_FILES_MISSING' }
Write-Host ('core_manifest.json regenerated: version='+$m.core_version+' schema='+$m.schema_version+' capabilities='+@($m.capabilities).Count)
exit 0
