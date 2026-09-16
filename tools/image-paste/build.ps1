param([string]$Dotnet = 'dotnet')
$ErrorActionPreference = 'Stop'
$repository = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
& (Join-Path $repository 'scripts/build.ps1') -Tool image-paste -Dotnet $Dotnet
