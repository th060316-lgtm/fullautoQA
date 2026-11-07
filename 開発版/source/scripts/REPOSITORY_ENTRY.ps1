# Canonical repository entry resolution for the FullAutoQA completion route.
#
# Why this file exists
# --------------------
# Windows PowerShell 5.1 reads a BOM-less .ps1 file with the system ANSI code
# page.  A non-ASCII literal inside such a file is therefore mojibake on a
# real standard-user Windows machine, while the very same file is read as
# UTF-8 by PowerShell 7 - which is what hosted CI uses.  That difference made
# a whole class of defects invisible to CI and fatal on the real machine.
#
# The rule this module enforces by construction:
#
#   * this file, and every .ps1 the real machine executes, stays ASCII-only;
#   * the repository source root is discovered by *structure* (a bounded,
#     one-level search for the directory that holds "source/scripts"), never
#     by a hard-coded non-ASCII directory name;
#   * every concrete input is then taken from TRANSFER_MANIFEST.json, which is
#     read explicitly as UTF-8 and therefore carries correct Unicode values.
#
# ASCII-only invariant: this file must never contain a byte above 0x7F.
# The source test suite (TESTS/test_windows_script_encoding.py) enforces it.
#
# The module is dot-sourced by:
#   * source/scripts/PREPARE_SOURCE.ps1      (sibling)
#   * rollback/RESTORE_PREDECESSOR.ps1       (../source/scripts/...)
#   * RUN_LOCAL_COMPLETION.ps1                      (located by the runner)
#
# All three therefore share ONE implementation of the entry contract instead
# of three drifting copies.

Set-StrictMode -Version Latest

#: Relative name of the manifest inside the repository source root.
$script:TransferManifestRelative = 'transfer/TRANSFER_MANIFEST.json'

#: Relative name of the source script directory inside the repository source root.
$script:SourceScriptsRelative = 'source/scripts'

#: Directory of this module, captured while it is being loaded.  Reading
#: $PSScriptRoot later would be unreliable because dot-sourcing assigns the
#: dot-sourced script's own $PSScriptRoot into the caller's scope.
$script:ModuleDirectory = $PSScriptRoot

function Resolve-RepositoryRelativePath {
    <#
      .SYNOPSIS
        Resolve a declared repository-relative path and refuse to leave the root.
      .DESCRIPTION
        The declared path must be relative, must not contain a parent segment
        and must resolve inside the root.  Root may be a drive root ("X:\").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Relative
    )
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw 'DECLARED_REPOSITORY_PATH_EMPTY' }
    $normalized = $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::IsPathRooted($normalized) -or $normalized -match '(^|[\\/])\.\.([\\/]|$)') {
        throw ('DECLARED_REPOSITORY_PATH_INVALID:' + $Relative)
    }
    $rootFull = [IO.Path]::GetFullPath($Root)
    $rootTrimmed = $rootFull.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrEmpty($rootTrimmed)) { $rootTrimmed = $rootFull }
    $prefix = $rootFull
    if (-not $prefix.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $prefix = $prefix + [IO.Path]::DirectorySeparatorChar
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootTrimmed $normalized))
    $inside = $candidate.Equals($rootTrimmed, [StringComparison]::OrdinalIgnoreCase) -or
              $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) { throw ('DECLARED_REPOSITORY_PATH_ESCAPE:' + $Relative) }
    return $candidate
}

function Get-RepositorySourceRoot {
    <#
      .SYNOPSIS
        The repository source root that contains this module.
      .DESCRIPTION
        This module lives in <source root>/source/scripts, so the source root
        is two levels up.  No name is hard-coded, so the layout may keep
        using a non-ASCII directory name without any literal in the code.
    #>
    [CmdletBinding()]
    param()
    $scriptsDir = [IO.Path]::GetFullPath($script:ModuleDirectory)
    $sourceDir = Split-Path -Parent $scriptsDir
    if ([string]::IsNullOrWhiteSpace($sourceDir)) { throw 'REPOSITORY_SOURCE_ROOT_UNRESOLVED' }
    $sourceRoot = Split-Path -Parent $sourceDir
    if ([string]::IsNullOrWhiteSpace($sourceRoot)) { throw 'REPOSITORY_SOURCE_ROOT_UNRESOLVED' }
    return $sourceRoot
}

function Get-SourceTreeFingerprintScript {
    <#
      .SYNOPSIS
        The ONE canonical Source-tree fingerprint implementation.
      .DESCRIPTION
        The runner (producer) and the Candidate builder (verifier) must hash
        the tree with exactly the same algorithm, so both call this script.
    #>
    [CmdletBinding()]
    param()
    return (Join-Path (Get-RepositorySourceRoot) 'source/scripts/SOURCE_TREE_FINGERPRINT.ps1')
}

function Get-TransferManifestPath {
    <#
      .SYNOPSIS
        The declared transfer manifest path inside a repository source root.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceRoot)
    return (Join-Path $SourceRoot $script:TransferManifestRelative.Replace('/', [IO.Path]::DirectorySeparatorChar))
}

function Read-TransferManifest {
    <#
      .SYNOPSIS
        Read the transfer manifest as UTF-8 and fail closed when it is absent.
      .DESCRIPTION
        The manifest is the single declaration of the donor and of the
        recovery source.  It is read with an explicit UTF-8 encoding so that
        its non-ASCII values are correct Unicode on every interpreter.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw ('TRANSFER_MANIFEST_MISSING:' + $ManifestPath)
    }
    try {
        $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
        return ($raw | ConvertFrom-Json)
    } catch {
        throw ('TRANSFER_MANIFEST_INVALID_JSON:' + $_.Exception.Message)
    }
}

function Get-DeclaredRepositoryEntries {
    <#
      .SYNOPSIS
        Resolve every declared completion-route input from one place.
      .DESCRIPTION
        Returns a hashtable with the resolved paths and the declared identity
        of the donor and of the recovery source.  Nothing here invents a
        path: the donor and the recovery archive come from the manifest, the
        build scripts / acceptance plan / rollback entrypoint come from the
        discovered source root.
      .PARAMETER RepositoryRoot
        The repository root (may be a subst drive root).
      .PARAMETER SourceRoot
        The discovered repository source root.
      .PARAMETER Manifest
        Optional pre-read manifest; read from disk when omitted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        $Manifest = $null
    )
    if ($null -eq $Manifest) {
        $Manifest = Read-TransferManifest -ManifestPath (Get-TransferManifestPath -SourceRoot $SourceRoot)
    }
    if (-not $Manifest.latest_complete_candidate -or
        [string]::IsNullOrWhiteSpace([string]$Manifest.latest_complete_candidate.path)) {
        throw 'DONOR_DECLARATION_MISSING'
    }
    if (-not $Manifest.recovery_source -or
        [string]::IsNullOrWhiteSpace([string]$Manifest.recovery_source.path) -or
        [string]::IsNullOrWhiteSpace([string]$Manifest.recovery_source.sha256)) {
        throw 'RECOVERY_SOURCE_DECLARATION_MISSING'
    }

    $donorRoot = Resolve-RepositoryRelativePath -Root $RepositoryRoot -Relative ([string]$Manifest.latest_complete_candidate.path)
    $recoverySource = Resolve-RepositoryRelativePath -Root $RepositoryRoot -Relative ([string]$Manifest.recovery_source.path)
    $prepareScript = Join-Path $SourceRoot ('source/scripts/PREPARE_SOURCE.ps1')
    $rebuildScript = Join-Path $SourceRoot ('source/scripts/PHASE3_OVERLAY_REBUILD.ps1')
    $fingerprintScript = Join-Path $SourceRoot ('source/scripts/SOURCE_TREE_FINGERPRINT.ps1')
    $acceptancePlan = Join-Path $SourceRoot ('acceptance_targets/FINAL_SERIES_PLAN.json')
    $acceptanceSeries = Join-Path $SourceRoot ('acceptance_targets/run_series.py')
    $acceptanceCommand = Join-Path $SourceRoot ('acceptance_targets/RUN_FINAL_ACCEPTANCE.cmd')
    $rollbackScript = Join-Path $SourceRoot ('rollback/RESTORE_PREDECESSOR.ps1')

    return [ordered]@{
        transfer_manifest_path = (Get-TransferManifestPath -SourceRoot $SourceRoot)
        transfer_manifest      = $Manifest
        donor_root             = $donorRoot
        donor_join             = (Join-Path $donorRoot 'JOIN_COMPLETE.ps1')
        donor_manifest         = (Join-Path $donorRoot 'manifest.json')
        donor_blocks           = (Join-Path $donorRoot 'blocks')
        recovery_source        = $recoverySource
        recovery_source_sha256 = ([string]$Manifest.recovery_source.sha256)
        prepare_script         = $prepareScript
        rebuild_script         = $rebuildScript
        fingerprint_script     = $fingerprintScript
        acceptance_plan        = $acceptancePlan
        acceptance_series      = $acceptanceSeries
        acceptance_command     = $acceptanceCommand
        rollback_script        = $rollbackScript
    }
}

function Test-DeclaredRepositoryEntries {
    <#
      .SYNOPSIS
        Verify that every declared entry exists and reports what is missing.
      .DESCRIPTION
        Used by the real-machine handoff preflight and by the Windows
        PowerShell 5.1 behavioural contract.  A missing entry is reported as a
        missing entry - never as a pass.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entries)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $files = @(
        @('donor_join', $Entries.donor_join),
        @('donor_manifest', $Entries.donor_manifest),
        @('recovery_source', $Entries.recovery_source),
        @('prepare_script', $Entries.prepare_script),
        @('rebuild_script', $Entries.rebuild_script),
        @('fingerprint_script', $Entries.fingerprint_script),
        @('acceptance_plan', $Entries.acceptance_plan),
        @('acceptance_series', $Entries.acceptance_series),
        @('acceptance_command', $Entries.acceptance_command),
        @('rollback_script', $Entries.rollback_script)
    )
    foreach ($row in $files) {
        if (-not (Test-Path -LiteralPath $row[1] -PathType Leaf)) {
            $problems.Add('DECLARED_ENTRY_MISSING:' + $row[0])
        }
    }
    if (-not (Test-Path -LiteralPath $Entries.donor_blocks -PathType Container)) {
        $problems.Add('DECLARED_ENTRY_MISSING:donor_blocks')
    }
    if ($problems.Count -eq 0) {
        $declared = $Entries.transfer_manifest.latest_complete_candidate
        if ($declared -and $declared.blocks_required) {
            $count = @(Get-ChildItem -LiteralPath $Entries.donor_blocks -File -ErrorAction Stop).Count
            if ($count -ne [int]$declared.blocks_required) {
                $problems.Add('DONOR_BLOCK_COUNT_MISMATCH:' + $count)
            }
        }
    }
    # The result is returned as a single object on purpose.  Returning the
    # empty list directly would unroll it to nothing, and the caller would
    # then evaluate .Count on $null, which throws under
    # Set-StrictMode -Version Latest.
    return ,$problems.ToArray()
}

function Get-Sha256File {
    <#
      .SYNOPSIS
        SHA-256 of a file, lower-case hex.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose(); $stream.Dispose() }
}
