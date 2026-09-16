param([string]$Dotnet = 'dotnet')
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path $toolRoot ('artifacts/update-integration-' + [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $testRoot 'fixture'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
# Headless stand-in: no clipboard, cursor, registry, tray or production EXE changes.
@'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0-windows</TargetFramework><ImplicitUsings>enable</ImplicitUsings></PropertyGroup></Project>
'@ | Set-Content (Join-Path $fixture 'Fixture.csproj')
@'
if (args.Length > 0 && args[0] == "--wait") { Thread.Sleep(int.Parse(args[1])); return; }
if (args.Length > 0 && args[0] == "--updated") {
    if (File.Exists(Path.Combine(AppContext.BaseDirectory, "fail-start"))) return;
    File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "started"), "ok");
    using var ready = EventWaitHandle.OpenExisting(args[1]); ready.Set(); return;
}
File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "restarted"), "ok");
'@ | Set-Content (Join-Path $fixture 'Program.cs')
$fixtureBin = Join-Path $testRoot 'fixture-bin'
& $Dotnet publish (Join-Path $fixture 'Fixture.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $fixtureBin
if ($LASTEXITCODE -ne 0) { throw 'Fixture build failed' }
$helperBin = Join-Path $testRoot 'helper-bin'
& $Dotnet publish (Join-Path $toolRoot 'src/ImagePaste.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -o $helperBin
if ($LASTEXITCODE -ne 0) { throw 'Helper build failed' }
function Start-Hidden([string]$Path, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($Path)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
    return [Diagnostics.Process]::Start($info)
}
$results = @()
foreach ($failure in @($false, $true)) {
    $scenario = Join-Path $testRoot $(if ($failure) { 'startup-failure' } else { 'success' })
    $stage = Join-Path $scenario ('.tiancai-update-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $target = Join-Path $scenario 'TianCai图片直粘.exe'
    $stub = Join-Path $fixtureBin 'Fixture.exe'
    Copy-Item -LiteralPath $stub -Destination $target
    $oldHash = (Get-FileHash -LiteralPath $target).Hash
    Copy-Item -LiteralPath $stub -Destination (Join-Path $stage 'new.exe')
    # Distinguish new payload from old file while keeping it executable.
    $append = [IO.File]::Open((Join-Path $stage 'new.exe'), [IO.FileMode]::Append)
    $append.WriteByte(0); $append.Dispose()
    Copy-Item -LiteralPath (Join-Path $helperBin 'TianCai图片直粘.exe') -Destination (Join-Path $stage 'helper.exe')
    if ($failure) { Set-Content (Join-Path $scenario 'fail-start') '1' }
    $parent = Start-Hidden $stub @('--wait', '4000')
    $guard = Start-Hidden $stub @('--wait', '7000')
    $token = 'Local\TianCai.Update.Test.' + [Guid]::NewGuid().ToString('N')
    $ready = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $token)
    $plan = @{
        Target = $target; ParentId = $parent.Id; ParentStart = $parent.StartTime.ToUniversalTime().Ticks
        GuardId = $guard.Id; GuardStart = $guard.StartTime.ToUniversalTime().Ticks
        Hash = (Get-FileHash (Join-Path $stage 'new.exe')).Hash; Token = $token
    }
    $plan | ConvertTo-Json | Set-Content (Join-Path $stage 'plan.json')
    $report = Join-Path $scenario 'failure.txt'
    $helper = Start-Hidden (Join-Path $stage 'helper.exe') @('--update-helper-test', $stage, $report)
    try {
        if (-not $ready.WaitOne(15000)) { throw 'Helper did not become ready' }
        if ((Get-FileHash $target).Hash -ne $oldHash) { throw 'Replaced before old processes exited' }
        if (-not $helper.WaitForExit(55000)) { throw 'Helper timed out' }
        if (-not $parent.HasExited -or -not $guard.HasExited) { throw 'Did not wait for both processes' }
        if ($failure) {
            if ($helper.ExitCode -ne 1 -or (Get-FileHash $target).Hash -ne $oldHash) { throw 'Rollback failed' }
            for ($i = 0; $i -lt 20 -and -not (Test-Path (Join-Path $scenario 'restarted')); $i++) { Start-Sleep -Milliseconds 100 }
            if (-not (Test-Path (Join-Path $scenario 'restarted'))) { throw 'Old version was not restarted' }
        } else {
            if ($helper.ExitCode -ne 0 -or -not (Test-Path (Join-Path $scenario 'started'))) { throw 'New version not started' }
            if ((Get-FileHash "$target.previous").Hash -ne $oldHash -or (Get-FileHash $target).Hash -ne $plan.Hash) { throw 'Replace/backup mismatch' }
        }
        $results += @{ scenario = $(if ($failure) { 'startup-failure-rollback' } else { 'wait-replace-restart' }); passed = $true }
    } finally { $ready.Dispose(); $helper.Dispose(); $parent.Dispose(); $guard.Dispose() }
}
$results | ConvertTo-Json | Set-Content (Join-Path $testRoot 'results.json')
Write-Host "Update integration passed. Report: $testRoot/results.json"
