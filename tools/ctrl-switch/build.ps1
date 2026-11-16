param([switch]$VersionedOutput)
& (Join-Path $PSScriptRoot '../../scripts/build.ps1') -Tool 'ctrl-switch' -VersionedOutput:$VersionedOutput
