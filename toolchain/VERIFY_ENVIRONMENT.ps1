param(
    [string]$Config = (Join-Path $PSScriptRoot "MACHINE_PATHS.json")
)

$ErrorActionPreference = "Stop"

$probes = [ordered]@{
    git          = @("git.exe")
    vscodium     = @("codium.cmd","codium.exe")
    winpython    = @("python.exe")
    uv           = @("uv.exe")
    node         = @("node.exe")
    temurin21    = @("java.exe")
    w64devkit    = @("gcc.exe","g++.exe")
    godot        = @("godot.exe","Godot_v4.7.2-stable_win64.exe")
    krita        = @("krita.exe")
    inkscape     = @("inkscape.exe")
    audacity     = @("audacity.exe")
    ffmpeg       = @("ffmpeg.exe")
    imagemagick  = @("magick.exe")
    obs          = @("obs64.exe")
    autohotkey   = @("AutoHotkey64.exe","AutoHotkey.exe")
    sqlite       = @("sqlite3.exe")
    ripgrep      = @("rg.exe")
    "7zip"       = @("7z.exe","7za.exe")
    github_cli   = @("gh.exe")
    pandoc       = @("pandoc.exe")
    ollama       = @("ollama.exe")
}

$configData = $null
if (Test-Path -LiteralPath $Config) {
    $configData = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
}

$rows = foreach ($id in $probes.Keys) {
    $configured = $null
    if ($configData -and $configData.tools -and $configData.tools.PSObject.Properties.Name -contains $id) {
        $configured = $configData.tools.$id
    }

    $found = $null
    $source = $null

    if ($configured) {
        $expanded = [Environment]::ExpandEnvironmentVariables([string]$configured)
        if (Test-Path -LiteralPath $expanded) {
            $found = (Resolve-Path -LiteralPath $expanded).Path
            $source = "config"
        }
    }

    if (-not $found) {
        foreach ($probe in $probes[$id]) {
            $cmd = Get-Command $probe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cmd) {
                $found = $cmd.Source
                $source = "PATH"
                break
            }
        }
    }

    [pscustomobject]@{
        Tool = $id
        Status = if ($found) { "FOUND" } else { "NOT_FOUND" }
        Source = if ($source) { $source } else { "" }
        Path = if ($found) { $found } else { "" }
    }
}

$rows | Format-Table -AutoSize
Write-Host ""
Write-Host "Read-only verification complete. No PATH, Registry, installer, or machine setting was changed."
