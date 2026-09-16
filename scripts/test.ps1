param([Parameter(Mandatory)][string]$Tool, [string]$Dotnet = 'dotnet')
$ErrorActionPreference = 'Stop'
$info = & (Join-Path $PSScriptRoot 'Get-Tool.ps1') -Tool $Tool
$output = Join-Path $info.Root 'artifacts/test-bin'
$report = Join-Path $info.Root 'artifacts/self-test.json'
& $Dotnet build $info.Project -c Release -o $output
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
[IO.File]::Delete($report) # Do not mistake a previous report for this run's result.
$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $output $info.Executable))
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$start.ArgumentList.Add('--self-test')
$start.ArgumentList.Add($report)
$process = [Diagnostics.Process]::Start($start)
try {
    if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Self-test timed out' }
    if ($process.ExitCode -ne 0) { throw "Self-test failed, exit $($process.ExitCode)" }
} finally { $process.Dispose() }
$result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
if ($null -eq $result.failed -or $result.failed -ne 0 -or $result.passed -lt 1) { throw 'Invalid or failed self-test report' }
Write-Host "Tests passed: $($result.passed). Report: $report"
