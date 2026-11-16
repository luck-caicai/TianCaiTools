param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$')][string]$Tool)
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$toolRoot = Join-Path $repository "tools/$Tool"
$metadata = Get-Content -LiteralPath (Join-Path $toolRoot 'tool.json') -Raw | ConvertFrom-Json
foreach ($field in @('id', 'name', 'description', 'project', 'executable')) {
    if ([string]::IsNullOrWhiteSpace($metadata.$field)) { throw "$Tool 缺少字段: $field" }
}
if ($metadata.id -ne $Tool) { throw '目录名与工具 ID 不一致' }
if (-not $metadata.name.StartsWith('TianCai')) { throw '工具展示名称必须使用 TianCai 品牌' }
if ($metadata.name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw '展示名称必须可用作文件夹名' }
$projectPath = [IO.Path]::GetFullPath((Join-Path $toolRoot $metadata.project))
if (-not $projectPath.StartsWith([IO.Path]::GetFullPath($toolRoot) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw '项目路径必须位于工具目录内' }
$type = if ($metadata.type) { [string]$metadata.type } else { 'dotnet-windows' }
if ($metadata.executable -ne [IO.Path]::GetFileName($metadata.executable)) { throw 'executable 必须是文件名' }
[xml]$project = Get-Content -LiteralPath $projectPath -Raw
switch ($type) {
    'dotnet-windows' {
        $version = $project.SelectSingleNode('/Project/PropertyGroup/Version').InnerText
        $framework = $project.SelectSingleNode('/Project/PropertyGroup/TargetFramework').InnerText
        $assembly = $project.SelectSingleNode('/Project/PropertyGroup/AssemblyName').InnerText
        if ($framework -notlike 'net8.0-windows*') { throw 'Windows 工具必须是 .NET 8 Windows 项目' }
        if ($metadata.executable -ne "$assembly.exe") { throw 'EXE 文件名与 AssemblyName 不一致' }
        $platform = 'win-x64'
        $runner = 'windows-latest'
    }
    'swift-macos' {
        $version = $project.SelectSingleNode('/plist/dict/key[text()="CFBundleShortVersionString"]/following-sibling::*[1]').InnerText
        $assembly = $project.SelectSingleNode('/plist/dict/key[text()="CFBundleExecutable"]/following-sibling::*[1]').InnerText
        $displayName = $project.SelectSingleNode('/plist/dict/key[text()="CFBundleDisplayName"]/following-sibling::*[1]').InnerText
        if ($displayName -ne $metadata.name) { throw 'macOS 展示名称与 tool.json 不一致' }
        if ($metadata.executable -ne "$assembly.app") { throw 'APP 文件名与 CFBundleExecutable 不一致' }
        foreach ($required in @('scripts/build.sh', 'scripts/test.sh', 'scripts/make-icon.swift', 'src/main.swift')) {
            if (-not (Test-Path -LiteralPath (Join-Path $toolRoot $required))) { throw "$Tool 缺少 $required" }
        }
        $framework = 'Swift/AppKit'
        $platform = 'macos-arm64'
        $runner = 'macos-latest'
    }
    default { throw "未知工具类型: $type" }
}
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw '项目版本必须为三段数字版本号' }
foreach ($required in @('README.md', 'CHANGELOG.md', 'build.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $toolRoot $required))) { throw "$Tool 缺少 $required" }
}
[pscustomobject]@{
    Id = $Tool; Name = $metadata.name; Description = $metadata.description
    Root = $toolRoot; Project = $projectPath; Executable = $metadata.executable
    Version = $version; Framework = $framework
    Type = $type; Platform = $platform; Runner = $runner
}
