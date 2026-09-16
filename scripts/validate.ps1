param([switch]$AsJson)
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$toolDirectories = @(Get-ChildItem -LiteralPath (Join-Path $repository 'tools') -Directory)
if ($toolDirectories.Count -eq 0) { throw '没有发现工具' }
$tools = @($toolDirectories | ForEach-Object { & (Join-Path $PSScriptRoot 'Get-Tool.ps1') -Tool $_.Name })
if ($AsJson) {
    @{ include = @($tools | ForEach-Object { @{ tool = $_.Id } }) } | ConvertTo-Json -Depth 3 -Compress
} else {
    $tools | Select-Object Id, Name, Version
    Write-Host "Validated $($tools.Count) tool(s)."
}
