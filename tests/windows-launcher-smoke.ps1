[CmdletBinding()]
param(
    [string]$LauncherPath = '',
    [string]$OutputDirectory = '',
    [ValidateRange(1,60)][int]$TimeoutSeconds = 30
)
# Runs only a harmless staged script. No product configuration, network, or
# driver is loaded. The runner must already be elevated to avoid UAC prompts.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Normalize-WindowsPath([string]$Path) {
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $Path = '\\' + $Path.Substring(8) }
    elseif ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) { $Path = $Path.Substring(4) }
    return [IO.Path]::GetFullPath($Path).TrimEnd([char]92)
}
function Assert-SamePath([string]$Actual, [string]$Expected, [string]$Message) {
    Assert ([string]::Equals((Normalize-WindowsPath $Actual), (Normalize-WindowsPath $Expected), [StringComparison]::OrdinalIgnoreCase)) $Message
}
function Stop-FixtureLauncher([Diagnostics.Process]$Process, [string]$ScriptPath) {
    if ($null -eq $Process) { return }
    # The unique staged script path limits cleanup to this launcher's own child.
    try {
        if (!$Process.HasExited) {
            foreach ($child in @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $Process.Id) -ErrorAction SilentlyContinue)) {
                if ($child.Name -ieq 'powershell.exe' -and $child.CommandLine -and
                    $child.CommandLine.IndexOf($ScriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
                }
            }
            if (!$Process.HasExited) { $Process.Kill(); $null = $Process.WaitForExit(2000) }
        }
    } catch { }
    finally { $Process.Dispose() }
}

Assert ($env:OS -eq 'Windows_NT') 'Run this smoke test on Windows; the built EXE cannot execute on this platform.'
Assert ([Environment]::Is64BitProcess) 'Run this smoke test in 64-bit Windows PowerShell or PowerShell.'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    Assert ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Run this smoke test from an elevated administrator session; unattended UAC prompts are not supported.'
} finally { $identity.Dispose() }

$repoRoot = Split-Path $PSScriptRoot -Parent
if (!$LauncherPath) { $LauncherPath = Join-Path $repoRoot 'client/windows/Civ6Relay.exe' }
$LauncherPath = [IO.Path]::GetFullPath($LauncherPath)
Assert ([IO.File]::Exists($LauncherPath)) 'Build client/windows/Civ6Relay.exe before running the launcher smoke test.'
$versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($LauncherPath)
Assert ($versionInfo.ProductName -ceq '核平联机助手') 'The EXE product name is missing or incorrectly encoded.'
Assert ($versionInfo.FileDescription -ceq '核平联机助手') 'The EXE description is missing or incorrectly encoded.'
Assert ($versionInfo.ProductVersion -ceq '1.0.0') 'The EXE product version is incorrect.'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $repoRoot '.build/windows-smoke' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$runnerTemp = $env:RUNNER_TEMP
if (!$runnerTemp) { $runnerTemp = [IO.Path]::GetTempPath() }
$fixtureRoot = Join-Path $runnerTemp ("文明6 启动器 & O'Brien " + [Guid]::NewGuid().ToString('N'))
$clientDirectory = Join-Path $fixtureRoot "客户端 空格 & O'Brien"
$otherDirectory = Join-Path $fixtureRoot 'different working directory'
$stubPath = Join-Path $clientDirectory 'Civ6Relay.ps1'
$markerPath = Join-Path $clientDirectory 'launcher-marker.json'
$process = $null
$samples = New-Object 'Collections.Generic.List[object]'
$reportPath = Join-Path $OutputDirectory 'launcher-smoke.json'
$utf8Bom = New-Object Text.UTF8Encoding($true)

try {
    $null = [IO.Directory]::CreateDirectory($clientDirectory)
    $null = [IO.Directory]::CreateDirectory($otherDirectory)
    $stagedLauncher = Join-Path $clientDirectory 'Civ6Relay.exe'
    Copy-Item -LiteralPath $LauncherPath -Destination $stagedLauncher
    $stub = @'
[CmdletBinding()]
param([string]$Action)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Civ6RelayLauncherSmoke {
    public static class NativeMethods {
        [DllImport("kernel32.dll", ExactSpelling = true)]
        public static extern IntPtr GetConsoleWindow();
    }
}
"@
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} finally { $identity.Dispose() }
$self = [Diagnostics.Process]::GetCurrentProcess()
try {
    $marker = [ordered]@{
        Action=$Action
        Is64BitProcess=[Environment]::Is64BitProcess
        IsAdministrator=$isAdmin
        ConsoleWindow=[Civ6RelayLauncherSmoke.NativeMethods]::GetConsoleWindow().ToInt64()
        ApartmentState=[Threading.Thread]::CurrentThread.ApartmentState.ToString()
        BaseDir=$PSScriptRoot
        CurrentDirectory=[Environment]::CurrentDirectory
        PowerShellLocation=(Get-Location).Path
        Executable=$self.MainModule.FileName
        ProcessId=$PID
        ProcessStartTicks=$self.StartTime.ToUniversalTime().Ticks.ToString()
        Time=[DateTimeOffset]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'launcher-marker.json'), ($marker | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
} finally { $self.Dispose() }
exit 0
'@
    # A BOM preserves the Chinese path/content when parsed by Windows PS 5.1.
    [IO.File]::WriteAllText($stubPath, $stub, $utf8Bom)
    [IO.File]::WriteAllText((Join-Path $clientDirectory 'LiveMonitor.cs'), '// Harmless smoke fixture; no runtime is loaded.', $utf8Bom)
    $expectedPowerShell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
    for ($run=1; $run -le 2; $run++) {
        if ([IO.File]::Exists($markerPath)) { [IO.File]::Delete($markerPath) }
        try {
            $process = Start-Process -FilePath $stagedLauncher -WorkingDirectory $otherDirectory -PassThru
            Assert ($process.WaitForExit($TimeoutSeconds * 1000)) ('Launcher did not exit within ' + $TimeoutSeconds + ' seconds; inspect the staged-script or native startup error.')
            Assert ($process.ExitCode -eq 0) ('Launcher returned exit code ' + $process.ExitCode + ' for the harmless script.')
            Assert ([IO.File]::Exists($markerPath)) 'The sibling smoke script did not write its marker.'
            $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert ($marker.Action -ceq 'Gui') 'Launcher did not pass -Action Gui.'
            Assert ($marker.Is64BitProcess -eq $true) 'Launcher started a 32-bit PowerShell child.'
            Assert ($marker.IsAdministrator -eq $true) 'Launcher child was not elevated.'
            Assert ([long]$marker.ConsoleWindow -eq 0) 'Launcher child acquired a console window.'
            Assert ($marker.ApartmentState -ceq 'STA') 'Launcher did not start PowerShell in STA mode.'
            Assert-SamePath $marker.Executable $expectedPowerShell 'Launcher did not use the built-in System32 Windows PowerShell executable.'
            Assert-SamePath $marker.BaseDir $clientDirectory 'The script resolved a different sibling directory.'
            Assert-SamePath $marker.CurrentDirectory $clientDirectory 'The child inherited the caller working directory.'
            Assert-SamePath $marker.PowerShellLocation $clientDirectory 'PowerShell location was not the client directory.'
            $child = Get-Process -Id ([int]$marker.ProcessId) -ErrorAction SilentlyContinue
            if ($null -ne $child) {
                try { Assert ($child.StartTime.ToUniversalTime().Ticks -ne [long]$marker.ProcessStartTicks) 'Launcher exited while its own PowerShell child was still running.' }
                finally { $child.Dispose() }
            }
            $samples.Add($marker)
            [IO.File]::WriteAllText((Join-Path $OutputDirectory ('launcher-run-' + $run + '.json')), ($marker | ConvertTo-Json), $utf8Bom)
        } finally {
            Stop-FixtureLauncher $process $stubPath
            $process = $null
        }
    }
    $report = [ordered]@{Success=$true;LauncherSha256=(Get-FileHash -LiteralPath $LauncherPath -Algorithm SHA256).Hash;Samples=$samples.ToArray()}
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 5), $utf8Bom)
    'PASS Windows launcher: Unicode/special-character path, arbitrary caller cwd, Gui/STA, System32 x64/admin child, no console, clean exit and repeated launch'
} catch {
    $report = [ordered]@{Success=$false;Error=$_.Exception.Message;Samples=$samples.ToArray()}
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 5), $utf8Bom)
    throw
} finally {
    Stop-FixtureLauncher $process $stubPath
    if ([IO.Directory]::Exists($fixtureRoot)) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
