param([switch]$SkipIntegration)
# Run with the cached PowerShell 7 container and --network none. These checks
# execute C# 5 syntax and real Linux loopback/RPC behavior, not Windows sockets.
$oldProgramData = $env:ProgramData
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('civ6 live-' + [Guid]::NewGuid())
$env:ProgramData = $testRoot
$repoRoot = Split-Path $PSScriptRoot -Parent
$script:OwnedProcesses = New-Object 'Collections.Generic.List[Diagnostics.Process]'
$script:Monitors = New-Object 'Collections.Generic.List[IDisposable]'
$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)
$isWindowsHost = $env:OS -eq 'Windows_NT'

function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Wait-Until([scriptblock]$Condition, [int]$Milliseconds, [string]$Message) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 30
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $Message
}
function New-ExecutableFixture([string]$Name, [string]$Body) {
    $path = Join-Path $testRoot $Name
    [IO.File]::WriteAllText($path, ("#!/bin/sh`n" + $Body + "`n"), $script:Utf8NoBom)
    & chmod '+x' -- $path
    Assert ($LASTEXITCODE -eq 0) 'Could not make the isolated CLI fixture executable'
    return $path
}
function New-RoutePoller {
    $poller = New-Object Civ6Relay.Live.RoutePoller
    $script:Monitors.Add($poller)
    return $poller
}
function Get-RecordedProcess([string]$Path) {
    Wait-Until { Test-Path -LiteralPath $Path } 3000 'CLI fixture did not start'
    $processId = [int](Get-Content -LiteralPath $Path -Raw).Trim()
    $process = Microsoft.PowerShell.Management\Get-Process -Id $processId -ErrorAction Stop
    $script:OwnedProcesses.Add($process)
    return $process
}
function Get-FreeLoopbackPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $parseTokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'client/windows/Civ6Relay.ps1'), [ref]$parseTokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) 'Client PowerShell source did not parse'
    # This makes accidental C# 6+ syntax fail even though the executing CLR is
    # modern. Framework 4.5 API/runtime compatibility still needs Windows QA.
    Add-Type -Path (Join-Path $repoRoot 'client/windows/LiveMonitor.cs') -CompilerOptions '/langversion:5'
    . (Join-Path $repoRoot 'client/windows/Civ6Relay.ps1') -LibraryOnly
    Initialize-LiveMonitor
    $script:ManagedRoot = Join-Path $testRoot 'managed'
    New-Item -ItemType Directory -Path (Join-Path $script:ManagedRoot 'bin') -Force | Out-Null
    'PASS live runtime compiles with C# 5 language syntax'

    if (!$isWindowsHost) {
        $sentinel = Start-Process -FilePath '/bin/sleep' -ArgumentList '60' -PassThru
        $script:OwnedProcesses.Add($sentinel)
        $slowCli = New-ExecutableFixture 'slow-cli' @'
printf '%s' "$$" > "$(dirname "$0")/slow.pid"
exec sleep 30
'@
        $poller = New-RoutePoller
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $poller.Start($slowCli, [Guid]::NewGuid().ToString(), 1)
        $watch.Stop()
        Assert ($watch.ElapsedMilliseconds -lt 1000) 'Starting a route query blocked the caller'
        $slowChild = Get-RecordedProcess (Join-Path $testRoot 'slow.pid')
        $watch.Restart()
        for ($i=0; $i -lt 200; $i++) { $null = $poller.ReadLatest() }
        $watch.Stop()
        Assert ($watch.ElapsedMilliseconds -lt 500) 'Cached route reads waited for the slow CLI'
        $watch.Restart()
        $poller.Stop()
        $watch.Stop()
        $routeStopMilliseconds = $watch.ElapsedMilliseconds
        Assert ($routeStopMilliseconds -lt 500) ('Stopping a route query blocked its caller for ' + $routeStopMilliseconds + ' ms')
        Wait-Until { $slowChild.HasExited } 1500 'Stop left its owned CLI child running'
        Assert (!$sentinel.HasExited) 'Stopping the route monitor killed an unrelated process'

        Remove-Item -LiteralPath (Join-Path $testRoot 'slow.pid')
        $timeoutPoller = New-RoutePoller
        $timeoutPoller.Start($slowCli, [Guid]::NewGuid().ToString(), 1)
        $timeoutChild = Get-RecordedProcess (Join-Path $testRoot 'slow.pid')
        Wait-Until { $timeoutPoller.ReadLatest().SampleTime -gt [DateTimeOffset]::MinValue } 6000 'Slow CLI did not publish a bounded timeout sample'
        $timeoutSample = $timeoutPoller.ReadLatest()
        Assert (![string]::IsNullOrEmpty($timeoutSample.Error) -and [string]::IsNullOrEmpty($timeoutSample.Stdout)) 'CLI timeout was reported as a successful route snapshot'
        Wait-Until { $timeoutChild.HasExited } 1000 'CLI timeout did not terminate its owned child'
        $timeoutPoller.Stop()
        Assert (!$sentinel.HasExited) 'CLI timeout killed an unrelated process'

        $successCli = New-ExecutableFixture 'success-cli' @'
printf '[{"ipv4":"10.77.77.2/24","hostname":"new-identity","path_len":0}]'
'@
        $oldIdentity = [Guid]::NewGuid().ToString()
        $newIdentity = [Guid]::NewGuid().ToString()
        Remove-Item -LiteralPath (Join-Path $testRoot 'slow.pid') -ErrorAction SilentlyContinue
        $identityPoller = New-RoutePoller
        $identityPoller.Start($slowCli, $oldIdentity, 1)
        $oldChild = Get-RecordedProcess (Join-Path $testRoot 'slow.pid')
        $oldGeneration = $identityPoller.ReadLatest().Generation
        $identityPoller.Start($successCli, $newIdentity, 1)
        Wait-Until { $identityPoller.ReadLatest().Stdout.Contains('new-identity') } 4000 'Replacing route identity did not publish the new query result'
        $newSample = $identityPoller.ReadLatest()
        Assert ($newSample.Generation -gt $oldGeneration -and $newSample.ExitCode -eq 0 -and [string]::IsNullOrEmpty($newSample.Error)) 'New route identity retained an old generation or error'
        Wait-Until { $oldChild.HasExited } 1000 'Replacing route identity left the previous CLI running'
        Start-Sleep -Milliseconds 150
        Assert ($identityPoller.ReadLatest().Stdout.Contains('new-identity')) 'An obsolete in-flight route query overwrote the new identity'
        $identityPoller.Stop()
        Start-Sleep -Milliseconds 100
        Assert (!$identityPoller.ReadLatest().Running) 'A cancelled route worker published a running state after Stop'
        Assert (!$sentinel.HasExited) 'Replacing route identity killed an unrelated process'

        $privateMarker = 'dummy-live-private-stderr-marker'
        $failedCli = New-ExecutableFixture 'failed-cli' @'
printf 'dummy-live-private-stderr-marker' >&2
printf 'dummy-live-private-stderr-marker'
exit 17
'@
        $identityPoller.Start($failedCli, $newIdentity, 1)
        Wait-Until { $identityPoller.ReadLatest().SampleTime -gt [DateTimeOffset]::MinValue } 3000 'Failed CLI did not publish its exit status'
        $failedSample = $identityPoller.ReadLatest()
        Assert ($failedSample.ExitCode -eq 17 -and $failedSample.Error -eq 'cli_exit_17' -and [string]::IsNullOrEmpty($failedSample.Stdout)) 'Failed CLI exposed its raw output or lost the exit code'
        Assert (!(($failedSample | Out-String).Contains($privateMarker))) 'Route failure leaked raw CLI stderr'
        Assert ($newSample.Stdout.Contains('new-identity') -and $newSample.ExitCode -eq 0) 'A previously returned route snapshot was mutated by a later query'
        $identityPoller.Stop()
        $oversizedCli = New-ExecutableFixture 'oversized-cli' @'
exec awk 'BEGIN { for (i=0; i<550000; i++) printf "x"; }'
'@
        $identityPoller.Start($oversizedCli, $newIdentity, 1)
        Wait-Until { $identityPoller.ReadLatest().SampleTime -gt [DateTimeOffset]::MinValue } 4000 'Oversized CLI output did not complete within its bound'
        $oversizedSample = $identityPoller.ReadLatest()
        Assert ($oversizedSample.Error -eq 'output_too_large' -and [string]::IsNullOrEmpty($oversizedSample.Stdout)) 'Oversized CLI output was retained as a successful route snapshot'
        $identityPoller.Stop()
        'PASS nonblocking route start/read, timeout, owned-child stop, identity replacement, safe failures and bounded output (Stop caller ' + $routeStopMilliseconds + ' ms)'

        $liveCli = New-ExecutableFixture 'live-cli' @'
printf '[{"ipv4":"127.0.0.2/24","hostname":"自己","path_len":0},{"ipv4":"","hostname":"Civ6Coordinator","path_len":1},{"ipv4":"127.0.0.1/24","hostname":"玩家乙","path_len":2,"next_hop_lat":8.75},{"ipv4":"198.51.100.23/24","hostname":"外部地址","path_len":1}]'
'@
        Copy-Item -LiteralPath $liveCli -Destination (Join-Path $script:ManagedRoot 'bin/easytier-cli.exe')
        $record = @{
            marker='civ6-relay/v3'; backend='easytier'; instance_id=[Guid]::NewGuid().ToString(); client_ip=''
            process_id=$sentinel.Id; start_ticks=$sentinel.StartTime.ToUniversalTime().Ticks.ToString()
        }
        $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Encoding UTF8
        $realInvokeMeshCli = (Get-Command Invoke-MeshCli -CommandType Function).ScriptBlock
        try {
            function Invoke-MeshCli { throw 'Cached live view invoked the synchronous CLI helper' }
            Start-LiveMonitor
            $runtime = $script:LiveRuntime
            Start-LiveMonitor
            Assert ([object]::ReferenceEquals($runtime, $script:LiveRuntime)) 'Starting live monitoring twice replaced its workers'
            $watch.Restart()
            $null = Get-LiveView
            $watch.Stop()
            Assert ($watch.ElapsedMilliseconds -lt 1000) 'Opening the live view waited for its first route query'
            Wait-Until { @((Get-LiveView).Peers | Where-Object { $_.VirtualIP -eq '127.0.0.1' -and $_.RTT -match '^\d+ ms$' }).Count -eq 1 } 5000 'Cached view did not combine background routes with real loopback ICMP'
            $view = Get-LiveView
            $peer = @($view.Peers | Where-Object { $_.VirtualIP -eq '127.0.0.1' })[0]
            Assert ($view.Text -like '已接入服务器；虚拟 IP：127.0.0.2*' -and $peer.Player -ceq '玩家乙') 'Cached view lost own IP, coordinator state, or Chinese player name'
            Assert ($peer.Channel -eq '服务器中继' -and $peer.LinkRTT -like '到中继 * ms' -and $peer.RTT -match '^\d+ ms$' -and $peer.SampleTime -match '^\d{2}:\d{2}:\d{2}$') 'Link latency and measured end-to-end ICMP latency were conflated'
            Assert (@($runtime.PingWorker.ReadLatest() | Where-Object { $_.IP -eq '198.51.100.23' }).Count -eq 0) 'Live view probed an advertised address outside the game subnet'
            $watch.Restart()
            for ($i=0; $i -lt 10; $i++) { $null = Get-LiveView }
            $watch.Stop()
            Assert ($watch.ElapsedMilliseconds -lt 1500) 'Repeated cached live views blocked on route or ping work'
            $runtime.RouteWorker.Stop()
            $runtime.Generation = $runtime.RouteWorker.ReadLatest().Generation
            $runtime.LastGood = [DateTimeOffset]::Now.AddSeconds(-6)
            $stale = Get-LiveView
            Assert (@($stale.Peers | Where-Object { $_.Channel -ne '路径状态已过期' -or $_.LinkRTT -ne '已过期' }).Count -eq 0) 'Old route samples continued to advertise current paths or link latency'
            '{broken-live-record:dummy-live-private-marker}' | Set-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Encoding UTF8
            $damaged = Get-LiveView
            Assert ($damaged.Text -eq '实时监测无法读取本机连接记录，请断开后重新连接。' -and @($damaged.Peers).Count -eq 0) 'Corrupt saved metadata did not return a safe empty cached view'
            Assert (!$damaged.Text.Contains('dummy-live-private-marker') -and !$runtime.Session -and !$runtime.Connected -and @($runtime.RoutePeers).Count -eq 0 -and $runtime.Paths.Count -eq 0) 'Corrupt metadata exposed raw input or retained the previous session cache'
            Assert (!$runtime.RouteWorker.ReadLatest().Running -and @($runtime.PingWorker.ReadLatest() | Where-Object { $_.Status -ne 'stopped' -or $null -ne $_.RttMs }).Count -eq 0) 'Corrupt metadata left previous route or latency sampling active'
            $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Encoding UTF8
            Wait-Until { @((Get-LiveView).Peers | Where-Object { $_.VirtualIP -eq '127.0.0.1' }).Count -eq 1 } 4000 'A valid restored identity could not restart after corrupt metadata'
            $record.start_ticks='1'
            $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Encoding UTF8
            $disconnected = Get-LiveView
            Assert ($disconnected.Text -eq '未连接' -and @($disconnected.Peers).Count -eq 0 -and !$runtime.Session) 'Expired process identity retained another session player cache'
            Stop-LiveMonitor
            Assert ($null -eq $script:LiveRuntime -and !$sentinel.HasExited) 'Stopping live monitoring retained its state or killed the core process'
            Stop-LiveMonitor
        } finally {
            Stop-LiveMonitor
            Set-Item Function:Invoke-MeshCli -Value $realInvokeMeshCli
        }
        'PASS cached PowerShell view, idempotent start/stop, separate link/ICMP latency, stale paths, corrupt metadata and identity clearing'
    }

    $latency = New-Object Civ6Relay.Live.LatencyMonitor
    $script:Monitors.Add($latency)
    $latency.SetPeers([string[]]@('127.0.0.1','127.0.0.1'))
    $latency.Start()
    Wait-Until { @($latency.ReadLatest() | Where-Object { $_.IP -eq '127.0.0.1' -and $_.Status -eq 'Success' }).Count -eq 1 } 5000 'Real loopback ICMP did not produce one deduplicated success sample'
    $loopback = @($latency.ReadLatest() | Where-Object { $_.IP -eq '127.0.0.1' })
    Assert ($loopback.Count -eq 1 -and $null -ne $loopback[0].RttMs -and $loopback[0].RttMs -ge 0 -and $loopback[0].Sequence -gt 0) 'Loopback latency sample lacks a measured RTT or sequence'
    $latency.SetPeers([string[]]@('192.0.2.1'))
    Wait-Until { @($latency.ReadLatest() | Where-Object { $_.IP -eq '192.0.2.1' -and $_.Status -ne 'Pending' }).Count -eq 1 } 5000 'Unreachable peer did not produce a bounded ICMP failure'
    $unreachable = @($latency.ReadLatest())
    Assert ($unreachable.Count -eq 1 -and $unreachable[0].IP -eq '192.0.2.1' -and $unreachable[0].Status -ne 'Success' -and $null -eq $unreachable[0].RttMs) 'ICMP failure retained another peer or fabricated a zero RTT'
    $latency.SetPeers([string[]]@())
    Start-Sleep -Milliseconds 150
    Assert (@($latency.ReadLatest()).Count -eq 0) 'Removing peers retained stale ICMP samples'
    $boundedPeers = [string[]]@(1..80 | ForEach-Object { '192.0.2.' + $_ })
    $latency.SetPeers($boundedPeers)
    Assert (@($latency.ReadLatest()).Count -eq 64) 'Latency monitor retained an unbounded peer list'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $latency.Stop()
    $watch.Stop()
    Assert ($watch.ElapsedMilliseconds -lt 1500) 'Stopping ICMP monitoring blocked beyond its request timeout'
    Assert (@($latency.ReadLatest() | Where-Object { $_.Status -ne 'stopped' -or $null -ne $_.RttMs }).Count -eq 0) 'Stopped ICMP monitoring retained measured or active sample states'
    $latency.SetPeers([string[]]@('127.0.0.1'))
    $latency.Start()
    Wait-Until { @($latency.ReadLatest() | Where-Object { $_.IP -eq '127.0.0.1' -and $_.Status -eq 'Success' }).Count -eq 1 } 4000 'Restarting latency monitoring waited for obsolete queued peer rounds'
    $latency.Stop()
    'PASS real loopback ICMP, deduplication, failure has no RTT, removed peers stay removed, bounded peers and stop/restart'

    if (!$SkipIntegration) {
        $binaryFolder = if ($isWindowsHost) { 'windows-x86_64' } else { 'linux-x86_64' }
        $suffix = if ($isWindowsHost) { '.exe' } else { '' }
        $corePath = Join-Path $repoRoot ('vendor/easytier/' + $binaryFolder + '/easytier-core' + $suffix)
        $cliPath = Join-Path $repoRoot ('vendor/easytier/' + $binaryFolder + '/easytier-cli' + $suffix)
        $rpcPort = Get-FreeLoopbackPort
        $instanceId = [Guid]::NewGuid().ToString()
        $configPath = Join-Path $testRoot 'loopback core.toml'
        $config = @(
            ('instance_id = "' + $instanceId + '"'), 'instance_name = "live-route-loopback-test"',
            'hostname = "玩家甲"', 'ipv4 = "10.77.77.2/24"', 'listeners = []',
            'stun_servers = []', 'stun_servers_v6 = []', '[network_identity]',
            'network_name = "dummy-live-route-test"', 'network_secret = "dummy-live-route-test-secret"',
            '[flags]', 'no_tun = true', 'disable_upnp = true', '[console_logger]', 'level = "off"'
        )
        [IO.File]::WriteAllText($configPath, ($config -join "`n"), $script:Utf8NoBom)
        $core = Start-Process -FilePath $corePath -ArgumentList @('-c', ('"' + $configPath + '"'), '--disable-env-parsing', '--rpc-portal', ('127.0.0.1:' + $rpcPort)) -PassThru -RedirectStandardOutput (Join-Path $testRoot 'core.stdout') -RedirectStandardError (Join-Path $testRoot 'core.stderr')
        $script:OwnedProcesses.Add($core)
        $realPoller = New-RoutePoller
        $realPoller.Start($cliPath, $instanceId, $rpcPort)
        Wait-Until { !$core.HasExited -and $realPoller.ReadLatest().Stdout.Contains('10.77.77.2/24') } 10000 'Actual route CLI/RPC did not publish the local route'
        $sample = $realPoller.ReadLatest()
        $routes = @(ConvertFrom-MeshJson $sample.Stdout)
        Assert ($sample.ExitCode -eq 0 -and [string]::IsNullOrEmpty($sample.Error) -and $routes.Count -eq 1 -and $routes[0].hostname -ceq '玩家甲') 'Actual route snapshot lost JSON, UTF-8 hostname, or success state'
        $realPoller.Stop()
        Assert (!$core.HasExited) 'Stopping the route poller terminated the EasyTier core'
        'PASS real bundled core/CLI route RPC, Chinese hostname, and core survives monitor stop'
    }

    $script:LiveMessages.Clear(); $script:LiveLogTotal=0L; $script:LiveLogDropped=0L
    $secret = [Convert]::ToBase64String([byte[]](1..32))
    Add-LiveLog ("first`nsecond`ncredential_secret = dummy-live-private-marker`n" + $secret + "`ncontrol" + [char]27 + 'text')
    $log = Get-LiveLog
    Assert ($log.Text.Contains('first') -and $log.Text.Contains('second') -and $log.Text.Contains('[已隐藏]') -and $log.Text.Contains('敏感信息已隐藏。')) 'Event log dropped ordinary lines or failed to redact private values'
    Assert (!$log.Text.Contains('dummy-live-private-marker') -and !$log.Text.Contains($secret) -and !($log.Text.Replace("`r", '').Replace("`n", '') -match '[\p{Cc}\p{Cf}]')) 'Event log retained private data or control characters'
    $script:LiveMessages.Clear(); $script:LiveLogTotal=0L; $script:LiveLogDropped=0L
    for ($i=0; $i -lt 1005; $i++) { Add-LiveLog ('event-' + $i.ToString('0000')) }
    Assert ($script:LiveMessages.Count -eq 1000 -and $script:LiveLogDropped -eq 5) 'Event queue grew without its documented bound or lost overflow accounting'
    $batches=0
    while ($script:LiveMessages.Count -gt 0) {
        $log = Get-LiveLog
        Assert (@($log.Text -split '\r?\n').Count -le 200 -and !$log.Text.Contains('event-0000')) 'Event log exceeded its UI batch bound or retained evicted events'
        $batches++
        Assert ($batches -le 5) 'Event log queue did not drain in bounded batches'
    }
    Assert ($log.Status.Contains('1005') -and $log.Status.Contains('已省略 5')) 'Event status lost queue/overflow counts'
    'PASS bounded event queue/batches, redaction, control-character filtering and overflow status'
} finally {
    if (Get-Command Stop-LiveMonitor -ErrorAction SilentlyContinue) { try { Stop-LiveMonitor } catch {} }
    foreach ($monitor in $script:Monitors) { try { $monitor.Dispose() } catch {} }
    foreach ($process in $script:OwnedProcesses) {
        try { if (!$process.HasExited) { $process.Kill(); $null = $process.WaitForExit(1500) } } catch {}
        $process.Dispose()
    }
    try { if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force } }
    finally { $env:ProgramData = $oldProgramData }
}
