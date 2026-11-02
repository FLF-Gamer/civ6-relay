param([int]$EngineId,[long]$EngineStartTicks)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Civ6Relay.ps1') -LibraryOnly
$path = Join-Path $script:ManagedRoot 'server-session.json'
$session = [IO.File]::ReadAllText($path) | ConvertFrom-Json
Watch-KeySession $session $EngineId $EngineStartTicks
