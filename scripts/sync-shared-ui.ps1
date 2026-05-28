$ErrorActionPreference = 'Stop'
$sharedRepo = Resolve-Path (Join-Path $PSScriptRoot '..\..\mikrotik-ui-shared')
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
& (Join-Path $sharedRepo 'scripts/sync-to-project.ps1') -ProjectPath $projectRoot -ProjectType traffic-monitor
