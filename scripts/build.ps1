param([Parameter(Mandatory)][string]$Tool, [string]$Dotnet = 'dotnet', [switch]$VersionedOutput)
$ErrorActionPreference = 'Stop'
$info = & (Join-Path $PSScriptRoot 'Get-Tool.ps1') -Tool $Tool
$release = Join-Path $info.Root 'release'
$output = Join-Path $release $info.Name
if ($VersionedOutput) { $output = Join-Path $release "$($info.Name)-$($info.Version)" }
& $Dotnet publish $info.Project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -o $output
if ($LASTEXITCODE -ne 0) { throw 'Publish failed' }
Copy-Item -LiteralPath (Join-Path $info.Root 'README.md') -Destination (Join-Path $output '使用说明.md')
$asset = "$($info.Id)-$($info.Version)-win-x64.zip"
$package = Join-Path $release $asset
Compress-Archive -Path (Join-Path $output '*') -DestinationPath $package -Force
$hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
$tag = "$($info.Id)/v$($info.Version)"
$metadata = [ordered]@{
    schemaVersion = 1
    id = $info.Id
    name = $info.Name
    version = $info.Version
    platform = 'win-x64'
    selfContained = $true
    tag = $tag
    asset = $asset
    downloadUrl = "https://github.com/luck-caicai/TianCaiTools/releases/download/$([Uri]::EscapeDataString($tag))/$asset"
    size = (Get-Item -LiteralPath $package).Length
    sha256 = $hash
}
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $release "$($info.Id)-update.json") -Encoding utf8
"$hash  $asset" | Set-Content -LiteralPath (Join-Path $release "$asset.sha256") -Encoding utf8
Write-Host "Package: $package"
