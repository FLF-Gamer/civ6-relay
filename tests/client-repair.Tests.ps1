$env:ProgramData='/tmp/civ6-component-tests'
. /workspace/client/windows/Civ6Relay.ps1 -LibraryOnly
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Throws([scriptblock]$Body) { try { & $Body } catch { return }; throw 'Expected failure' }
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('civ6-repair-'+[Guid]::NewGuid())
$script:PackageRoot=Join-Path $testRoot 'package'
$script:ManagedRoot=Join-Path $testRoot 'managed'
$script:SimulatedRunning=$false
$script:Copies=New-Object 'Collections.Generic.List[string]'
function Get-OwnRelayProcess { if ($script:SimulatedRunning) { return [Diagnostics.Process]::GetCurrentProcess() }; return $null }
function Protect-ManagedDirectory { New-Item -ItemType Directory $script:ManagedRoot -Force | Out-Null }
function Copy-Item {
 param([string]$LiteralPath,[string]$Destination,[switch]$Force)
 $name=[IO.Path]::GetFileName($Destination)
 if ($name -eq 'WinDivert64.sys') { throw [IO.IOException]::new('Simulated loaded kernel driver: file is in use') }
 $script:Copies.Add($name)
 [IO.File]::Copy($LiteralPath,$Destination,$true)
}
try {
 $source=Join-Path $script:PackageRoot 'bin';$target=Join-Path $script:ManagedRoot 'bin'
 New-Item -ItemType Directory $source,$target -Force | Out-Null
 $hashes=[ordered]@{}
 foreach ($name in $script:ComponentFiles) {
  [IO.File]::WriteAllText((Join-Path $source $name),('test-component-'+$name))
  [IO.File]::WriteAllText((Join-Path $target $name),('test-component-'+$name))
  $hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $source $name)).Hash
 }
 $json=$hashes|ConvertTo-Json
 [IO.File]::WriteAllText((Join-Path $source 'checksums.json'),$json)
 [IO.File]::WriteAllText((Join-Path $target 'checksums.json'),$json)
 Install-Component | Out-Null
 Assert ($script:Copies.Count -eq 0) 'Healthy loaded components were overwritten'
 $script:SimulatedRunning=$true
 Install-Component | Out-Null
 Assert ($script:Copies.Count -eq 0) 'Read-only check while connected wrote components'
 $script:SimulatedRunning=$false
 Remove-Item -LiteralPath (Join-Path $target 'easytier-cli.exe')
 Install-Component | Out-Null
 Assert ([IO.File]::Exists((Join-Path $target 'easytier-cli.exe'))) 'Missing status CLI was not repaired'
 Assert ($script:Copies.Count -eq 1 -and $script:Copies[0] -eq 'easytier-cli.exe') 'Repair overwrote unchanged kernel driver'
 [IO.File]::WriteAllText((Join-Path $target 'wintun.dll'),'damaged-test-file')
 $script:SimulatedRunning=$true
 Throws { Install-Component | Out-Null }
 Assert ([IO.File]::ReadAllText((Join-Path $target 'wintun.dll')) -eq 'damaged-test-file') 'Repair modified a running component'
 $script:SimulatedRunning=$false
 # A changed locked driver must fail before touching other components.
 [IO.File]::WriteAllText((Join-Path $target 'WinDivert64.sys'),'old-test-driver')
 $copyCount=$script:Copies.Count
 Throws { Install-Component | Out-Null }
 Assert ($script:Copies.Count -eq $copyCount) 'Repair changed components before failing on the locked driver'
 Assert ([IO.File]::ReadAllText((Join-Path $target 'wintun.dll')) -eq 'damaged-test-file') 'Locked driver failure partially repaired executable components'
 'PASS loaded-driver check, read-only connected check, selective CLI repair, running component protection, locked changed-driver failure ordering'
} finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }
