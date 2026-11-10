param(
    [ValidateSet("all","shared","production","management","sales","myai")]
    [string]$Scope = "all",
    [ValidateSet("P0","P1","P2","all")]
    [string]$Priority = "all"
)

$ErrorActionPreference = "Stop"
$catalogPath = Join-Path $PSScriptRoot "TOOL_CATALOG.json"
if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "TOOL_CATALOG.json not found: $catalogPath"
}

$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$selected = @($catalog.tools | Where-Object {
    ($Scope -eq "all" -or $_.scopes -contains $Scope) -and
    ($Priority -eq "all" -or $_.priority -eq $Priority)
})

Write-Host ("Opening {0} official download/documentation pages..." -f $selected.Count)

foreach ($tool in $selected) {
    Write-Host ("[{0}] {1} -> {2}" -f $tool.priority, $tool.name, $tool.official_url)
    Start-Process $tool.official_url
    Start-Sleep -Milliseconds 250
}

Write-Host "No installer, PATH, Registry, or machine setting was changed."
