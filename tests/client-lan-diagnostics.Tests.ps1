param([switch]$SkipIntegration)
# Windows cmdlets below are read-only fixtures. The integration uses actual
# bundled core/CLI RPC in a --network none container, with no TUN or real keys.
$oldProgramData = $env:ProgramData
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('civ6-lan-diagnostics-' + [Guid]::NewGuid())
$env:ProgramData = $testRoot
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'client/windows/Civ6Relay.ps1') -LibraryOnly
$script:ManagedRoot = Join-Path $testRoot 'managed'
New-Item -ItemType Directory (Join-Path $script:ManagedRoot 'bin') -Force | Out-Null
$script:RealInvokeMeshCli = (Get-Command Invoke-MeshCli -CommandType Function).ScriptBlock
$script:RealGetProfile = (Get-Command Get-Profile -CommandType Function).ScriptBlock
$script:RealGetNetworkFingerprint = (Get-Command Get-NetworkFingerprint -CommandType Function).ScriptBlock
$script:PrivateMarker = 'dummy-private-credential-and-path-marker'
$script:MutationAttempts = 0
$script:WindowsReadCalls = 0
$script:ThrowProcess = $false
$script:ThrowUdp = $false
$script:ThrowProfiles = $false
$script:ThrowRules = $false
$core = $null

function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Assert-Private($Result) {
    $text = $Result | Out-String
    Assert (!$text.Contains($script:PrivateMarker)) 'Diagnostics leaked private fixture data or raw exception text'
    Assert (!$text.Contains('C:\Users\')) 'Diagnostics exposed a full local executable path'
}
function Set-StatsFixture($Metrics) {
    $script:FixtureMetrics = @($Metrics)
    function script:Invoke-MeshCli {
        param([string]$InstanceId, [string]$Command)
        Assert ($Command -eq 'stats') 'Broadcast diagnostic must query stats, not config or node information'
        Assert ($InstanceId -eq 'dummy-local-instance') 'Broadcast diagnostic changed the selected instance'
        return $script:FixtureMetrics
    }
}
function New-StatsFixture([long[]]$Values) {
    $names = @('captured','ignored','forwarded','forward_failed')
    for ($i=0; $i -lt $names.Count; $i++) {
        [pscustomobject]@{
            name=('udp_broadcast_relay_packets_' + $names[$i]); value=$Values[$i]
            labels=[pscustomobject]@{network_name=$script:PrivateMarker}
        }
    }
}
function Reset-WindowsFixtures {
    $script:FixtureProcesses = @(
        [pscustomobject]@{Id=41001; ProcessName='CivilizationVI'; Path=('C:\Users\' + $script:PrivateMarker + '\CivilizationVI.exe')},
        [pscustomobject]@{Id=41002; ProcessName='CivilizationVI_DX12'; Path=('C:\Users\' + $script:PrivateMarker + '\CivilizationVI_DX12.exe')}
    )
    $script:FixtureEndpoints = @(
        [pscustomobject]@{OwningProcess=41001; LocalAddress='0.0.0.0'; LocalPort=62001},
        [pscustomobject]@{OwningProcess=41002; LocalAddress='10.77.77.3'; LocalPort=62002},
        [pscustomobject]@{OwningProcess=41002; LocalAddress='::'; LocalPort=62003},
        [pscustomobject]@{OwningProcess=49999; LocalAddress='192.0.2.123'; LocalPort=62999}
    )
    $script:FixtureProfiles = @(
        [pscustomobject]@{Name='Public'; Enabled=$true; AllowInboundRules='False'; AllowLocalFirewallRules='False'},
        [pscustomobject]@{Name='Private'; Enabled=$false; AllowInboundRules='True'; AllowLocalFirewallRules='True'}
    )
    $script:FixtureAppFilters = @(
        [pscustomobject]@{Program=('C:\Users\' + $script:PrivateMarker + '\CivilizationVI.exe')},
        [pscustomobject]@{Program=('C:\Users\' + $script:PrivateMarker + '\unrelated.exe')},
        [pscustomobject]@{Program='C:\Games\CivilizationVI\LaunchPad\LauncherPatcher.exe'}
    )
    $script:FixtureRules = @(
        [pscustomobject]@{Direction='Inbound'; Enabled='True'; Action='Block'; Profile='Public'; PolicyStoreSourceType='GroupPolicy'; DisplayName=$script:PrivateMarker; Description=$script:PrivateMarker},
        [pscustomobject]@{Direction='Inbound'; Enabled='True'; Action='Allow'; Profile='Private'; PolicyStoreSourceType='Local'; DisplayName=$script:PrivateMarker; Description=$script:PrivateMarker},
        [pscustomobject]@{Direction='Outbound'; Enabled='True'; Action='Block'; Profile='Domain'; PolicyStoreSourceType=$script:PrivateMarker; DisplayName=$script:PrivateMarker},
        [pscustomobject]@{Direction='Inbound'; Enabled='False'; Action='Block'; Profile='Domain'; PolicyStoreSourceType=$script:PrivateMarker; DisplayName=$script:PrivateMarker}
    )
    $script:ThrowProcess=$false; $script:ThrowUdp=$false; $script:ThrowProfiles=$false; $script:ThrowRules=$false
}
function Get-Process {
    [CmdletBinding()]
    param([string[]]$Name, [int]$Id)
    if ($PSBoundParameters.ContainsKey('Id')) { return Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction SilentlyContinue }
    $script:WindowsReadCalls++
    if ($script:ThrowProcess) { throw $script:PrivateMarker }
    Assert ($Name.Count -gt 0 -and @($Name | Where-Object { $_ -notin @('CivilizationVI','CivilizationVI_DX12') }).Count -eq 0) 'Game diagnostics enumerated unrelated processes'
    return @($script:FixtureProcesses | Where-Object { $_.ProcessName -in $Name })
}
function Get-NetUDPEndpoint {
    [CmdletBinding()]
    param([int[]]$OwningProcess)
    $script:WindowsReadCalls++
    if ($script:ThrowUdp) { throw $script:PrivateMarker }
    if ($PSBoundParameters.ContainsKey('OwningProcess')) {
        return @($script:FixtureEndpoints | Where-Object { $_.OwningProcess -in $OwningProcess })
    }
    return $script:FixtureEndpoints
}
function Get-NetFirewallProfile {
    [CmdletBinding()]
    param([string]$PolicyStore)
    $script:WindowsReadCalls++
    Assert ($PolicyStore -eq 'ActiveStore') 'Firewall profile diagnostic did not read effective ActiveStore'
    if ($script:ThrowProfiles) { throw $script:PrivateMarker }
    return $script:FixtureProfiles
}
function Get-NetFirewallApplicationFilter {
    [CmdletBinding()]
    param([string]$PolicyStore)
    $script:WindowsReadCalls++
    Assert ($PolicyStore -eq 'ActiveStore') 'Firewall application diagnostic did not read effective ActiveStore'
    if ($script:ThrowRules) { throw $script:PrivateMarker }
    return $script:FixtureAppFilters
}
function Get-NetFirewallRule {
    [CmdletBinding()]
    param($AssociatedNetFirewallApplicationFilter, [string]$PolicyStore, [switch]$TracePolicyStore)
    $script:WindowsReadCalls++
    Assert ($PolicyStore -eq 'ActiveStore' -and $TracePolicyStore) 'Game rules must read effective ActiveStore and trace their policy source'
    $fileName = [regex]::Replace([string]$AssociatedNetFirewallApplicationFilter.Program, '^.*[\\/]', '')
    Assert ($fileName -match '^CivilizationVI(?:_DX12)?\.exe$') 'Game rule diagnostic enumerated an unrelated application or launcher'
    if ($script:ThrowRules) { throw $script:PrivateMarker }
    return $script:FixtureRules
}
foreach ($command in @('New-NetFirewallRule','Set-NetFirewallRule','Set-NetFirewallProfile','Set-NetConnectionProfile','Enable-NetFirewallRule','Remove-NetFirewallRule','netsh')) {
    Set-Item -Path ('Function:script:' + $command) -Value { $script:MutationAttempts++; throw 'Read-only diagnostic attempted a system mutation' }
}

try {
    Set-StatsFixture @()
    $result = @(Get-LanBroadcastDiagnostics 'dummy-local-instance')
    Assert (($result -join "`n").Contains('广播统计：暂无数据。')) 'Absent counters must be unknown, not a stopped capture claim'
    Assert-Private $result
    Set-StatsFixture (New-StatsFixture @(0,0,0,0))
    $result = @(Get-LanBroadcastDiagnostics 'dummy-local-instance')
    Assert (($result -join "`n").Contains('广播统计（全部应用）：捕获 0；忽略 0；转发提交 0；失败 0。')) 'Present zero counters were confused with missing counters'
    Assert-Private $result
    Set-StatsFixture @([pscustomobject]@{name='traffic_packets_rx';value=999;labels=$script:PrivateMarker})
    $result = @(Get-LanBroadcastDiagnostics 'dummy-local-instance')
    Assert (($result -join "`n").Contains('广播统计：暂无数据。')) 'Unrelated metrics must not be interpreted as broadcast health'
    $metrics = @(New-StatsFixture @(29,4,21,3))
    Set-StatsFixture $metrics[0..2]
    Assert ((@(Get-LanBroadcastDiagnostics 'dummy-local-instance') -join "`n").Contains('广播统计：暂无数据。')) 'Incomplete counter sets must not fabricate a fourth zero'
    Set-StatsFixture $metrics
    $result = @(Get-LanBroadcastDiagnostics 'dummy-local-instance')
    $text = $result -join "`n"
    Assert ($text.Contains('广播统计（全部应用）：捕获 29；忽略 4；转发提交 21；失败 3。')) 'Broadcast metric names or values were mapped incorrectly'
    Assert ($text.Contains('全部应用') -and $text.Contains('转发提交')) 'Broadcast labels must retain their application scope and submission meaning'
    Assert-Private $result
    function script:Invoke-MeshCli { param([string]$InstanceId, [string]$Command); throw $script:PrivateMarker }
    $result = @(Get-LanBroadcastDiagnostics 'dummy-local-instance')
    Assert (($result -join "`n") -match '广播统计：读取失败') 'Stats failure must remain a partial diagnostic'
    Assert-Private $result
    'PASS absent/partial/zero/nonzero broadcast metrics, safe selected fields, partial stats failure'

    Reset-WindowsFixtures
    $result = @(Get-Civ6WindowsDiagnostics '10.77.77.0/24')
    $text = $result -join "`n"
    foreach ($expected in @('CivilizationVI','CivilizationVI_DX12','41001','41002','62001','62002','62003','0.0.0.0','10.77.77.3','Public','Private','GroupPolicy','Block','Allow')) {
        Assert ($text.Contains($expected)) ('Windows diagnostic omitted expected safe field: ' + $expected)
    }
    Assert (!$text.Contains('62999') -and !$text.Contains('192.0.2.123') -and !$text.Contains('unrelated.exe') -and !$text.Contains('LauncherPatcher.exe')) 'Windows diagnostic included an unrelated process endpoint, application or game-folder launcher'
    Assert ($text.Contains('防火墙 Public：启用 True；允许入站规则 False；允许本地规则 False') -and $text.Contains('防火墙 Private：启用 False；允许入站规则 True；允许本地规则 True')) 'Effective profile states or local-policy restrictions were mixed together'
    Assert-Private $result
    $script:FixtureEndpoints=@()
    $result = @(Get-Civ6WindowsDiagnostics '10.77.77.0/24')
    Assert (($result -join "`n").Contains('文明6 UDP 监听：暂无数据。')) 'Successful empty UDP query must be distinct from a failed query or absent game'
    Reset-WindowsFixtures
    $script:FixtureProcesses = @($script:FixtureProcesses | Where-Object { $_.ProcessName -eq 'CivilizationVI_DX12' })
    $result = @(Get-Civ6WindowsDiagnostics '10.77.77.0/24')
    Assert (($result -join "`n").Contains('CivilizationVI_DX12') -and !($result -join "`n").Contains('41001')) 'DX12-only game was lost when standard executable is absent'
    Assert-Private $result
    $script:FixtureProcesses=@()
    $result = @(Get-Civ6WindowsDiagnostics '10.77.77.0/24')
    Assert (($result -join "`n") -match '未.*(运行|进程)|没有.*(运行|进程)') 'Game-not-running state must be explicit'
    Assert-Private $result
    foreach ($failingSection in @('ThrowProcess','ThrowUdp','ThrowProfiles','ThrowRules')) {
        Reset-WindowsFixtures
        Set-Variable -Name $failingSection -Scope Script -Value $true
        $result = @(Get-Civ6WindowsDiagnostics '10.77.77.0/24')
        $text = $result -join "`n"
        Assert-Private $result
        Assert ($text -match '无法|失败|未能|不可用') 'Windows query failure did not produce a safe explicit partial result'
        if ($failingSection -in @('ThrowProcess','ThrowUdp')) { Assert ($text.Contains('Public')) 'Game/UDP query failure hid firewall results' }
        if ($failingSection -in @('ThrowProfiles','ThrowRules')) { Assert ($text.Contains('62001')) 'Firewall query failure hid successful game UDP bindings' }
    }
    Assert ($script:MutationAttempts -eq 0) 'LAN diagnostics attempted to change firewall/network state'
    'PASS Civ6/DX12 PID filtering, UDP bindings, effective firewall fields, private path/error redaction, isolated Windows query failures, read-only behavior'

    if (!$SkipIntegration) {
        Set-Item Function:Invoke-MeshCli -Value $script:RealInvokeMeshCli
        $binaryFolder = if ($env:OS -eq 'Windows_NT') { 'windows-x86_64' } else { 'linux-x86_64' }
        $suffix = if ($env:OS -eq 'Windows_NT') { '.exe' } else { '' }
        $corePath = Join-Path $repoRoot ('vendor/easytier/' + $binaryFolder + '/easytier-core' + $suffix)
        $cliPath = Join-Path $repoRoot ('vendor/easytier/' + $binaryFolder + '/easytier-cli' + $suffix)
        Copy-Item -LiteralPath $cliPath -Destination (Join-Path $script:ManagedRoot 'bin/easytier-cli.exe')
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        try { $listener.Start(); $script:RpcPort = $listener.LocalEndpoint.Port } finally { $listener.Stop() }
        $id = [Guid]::NewGuid().ToString()
        $configPath = Join-Path $testRoot 'stats.toml'
        $config = @(
            ('instance_id = "' + $id + '"'), 'instance_name = "local-lan-diagnostic-test"', 'hostname = "local-lan-diagnostic-test"',
            'listeners = []', 'stun_servers = []', 'stun_servers_v6 = []', '[network_identity]',
            'network_name = "dummy-local-lan-diagnostic-test"', 'network_secret = "dummy-local-lan-diagnostic-test-secret"',
            '[flags]', 'no_tun = true', 'disable_upnp = true', '[console_logger]', 'level = "off"'
        )
        [IO.File]::WriteAllText($configPath, ($config -join "`n"), (New-Object Text.UTF8Encoding($false)))
        $core = Start-Process -FilePath $corePath -ArgumentList @('-c', ('"' + $configPath + '"'), '--disable-env-parsing', '--rpc-portal', ('127.0.0.1:' + $script:RpcPort)) -PassThru -RedirectStandardOutput (Join-Path $testRoot 'stdout') -RedirectStandardError (Join-Path $testRoot 'stderr')
        $ready=$false; $deadline=[DateTime]::UtcNow.AddSeconds(20)
        do {
            Assert (!$core.HasExited) 'Local stats test core exited during startup'
            try { $stats=@(Invoke-MeshCli -InstanceId $id -Command stats); $ready=$stats.Count -gt 0 } catch { $ready=$false }
            if (!$ready) { Start-Sleep -Milliseconds 100 }
        } while (!$ready -and [DateTime]::UtcNow -lt $deadline)
        Assert $ready 'Actual bundled stats RPC did not become ready'
        Assert ($stats[0].PSObject.Properties['name'] -and $stats[0].PSObject.Properties['value'] -and $stats[0].PSObject.Properties['labels']) 'Actual CLI stats JSON shape changed'
        $result=@(Get-LanBroadcastDiagnostics $id)
        Assert (($result -join "`n").Contains('广播统计：暂无数据。')) 'Real noTun stats must not falsely report broadcast capture stopped or active'
        Assert-Private $result
        if ((Get-Command Microsoft.PowerShell.Utility\ConvertFrom-Json).Parameters.ContainsKey('NoEnumerate')) {
            function script:ConvertFrom-Json {
                [CmdletBinding()]
                param([Parameter(Mandatory=$true, ValueFromPipeline=$true)][string]$InputObject)
                process { Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject -NoEnumerate }
            }
            $stats=@(Invoke-MeshCli -InstanceId $id -Command stats)
            Assert ($stats.Count -gt 1 -and $stats[0] -isnot [array]) 'Real stats array was nested under PS5.1-output emulation'
            $result=@(Get-LanBroadcastDiagnostics $id)
            Assert (($result -join "`n").Contains('广播统计：暂无数据。')) 'Broadcast diagnostic failed under PS5.1-array-output emulation'
            Assert-Private $result
            Remove-Item Function:ConvertFrom-Json
        }
        'PASS actual bundled core/CLI stats RPC, absent broadcast metrics remain unknown, PS5.1 array-output emulation'
        $script:NativeCommands = New-Object 'Collections.Generic.List[string]'
        $script:FailNativeStats = $false
        function script:Invoke-MeshCli {
            param([string]$InstanceId, [string]$Command='route')
            $script:NativeCommands.Add($Command)
            if ($Command -eq 'stats' -and $script:FailNativeStats) { throw $script:PrivateMarker }
            & $script:RealInvokeMeshCli -InstanceId $InstanceId -Command $Command
        }
        @{
            marker='civ6-relay/v3'; backend='easytier'; instance_id=$id; client_ip=''
            process_id=$core.Id; start_ticks=$core.StartTime.ToUniversalTime().Ticks.ToString()
            network_fingerprint='dummy-fingerprint'; credential_secret=$script:PrivateMarker
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Encoding UTF8
        Reset-WindowsFixtures
        $beforeReads = $script:WindowsReadCalls
        $snapshot = Get-MeshSnapshot
        Assert ($snapshot.Text -notmatch '状态读取失败|未连接') 'Real connected snapshot failed before on-demand diagnostic check'
        Assert ($script:NativeCommands.Count -eq 1 -and $script:NativeCommands[0] -eq 'route') 'Regular snapshot queried heavy stats outside on-demand diagnosis'
        Assert ($script:WindowsReadCalls -eq $beforeReads) 'Regular snapshot queried Windows game/firewall diagnostics'
        function script:Get-Profile { return [pscustomobject]@{network='10.77.77.0/24';credential_secret=$script:PrivateMarker} }
        function script:Get-NetworkFingerprint { return 'dummy-fingerprint' }
        $result = Test-Relay
        Assert ($result -match '^版本：.+；时间：\d{4}-' -and $result.Contains($snapshot.Text)) 'On-demand diagnosis lost timestamp or real route status'
        Assert ($result.Contains('广播统计：暂无数据。') -and $result.Contains('62001') -and $result.Contains('Public')) 'On-demand diagnosis did not append stats and Windows evidence'
        Assert-Private $result
        function script:Get-NetworkFingerprint { throw $script:PrivateMarker }
        $result = Test-Relay
        Assert ($result.Contains($snapshot.Text) -and $result.Contains('默认路由和 DNS：读取失败') -and $result.Contains('广播统计：暂无数据。') -and $result.Contains('62001')) 'Fingerprint failure hid independent broadcast/game diagnostics'
        Assert-Private $result
        function script:Get-NetworkFingerprint { return 'dummy-fingerprint' }
        $script:FailNativeStats = $true
        $script:ThrowProfiles = $true
        $result = Test-Relay
        Assert ($result.Contains($snapshot.Text) -and $result.Contains('广播统计：读取失败') -and $result.Contains('62001') -and $result.Contains('防火墙策略读取失败')) 'Partial diagnostic failures hid route status or successful UDP evidence'
        Assert-Private $result
        '{malformed-managed-record:' + $script:PrivateMarker | Set-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Encoding UTF8
        $result = Test-Relay
        Assert ($result.Contains('玩家连接状态：读取失败。') -and $result.Contains('本机连接记录：读取失败') -and $result.Contains('62001')) 'Real corrupt-metadata snapshot failure hid independent game evidence'
        Assert-Private $result
        $originalPackageRoot = $script:PackageRoot
        try {
            $script:PackageRoot = Join-Path $testRoot 'corrupt-test-package'
            New-Item -ItemType Directory $script:PackageRoot | Out-Null
            '{malformed-profile:' + $script:PrivateMarker | Set-Content -LiteralPath (Join-Path $script:PackageRoot 'profile.json') -Encoding UTF8
            Set-Item Function:Get-Profile -Value $script:RealGetProfile
            $profileError = ''
            try { Test-Relay | Out-Null } catch { $profileError = $_.Exception.Message }
            Assert ($profileError -eq '无法读取客户端配置，请检查设置或重新解压客户端。') 'Real malformed private profile was not replaced with a fixed safe diagnostic error'
            Assert-Private $profileError
        } finally { $script:PackageRoot = $originalPackageRoot }
        Assert ($script:MutationAttempts -eq 0) 'On-demand diagnosis attempted a firewall/network mutation'
        'PASS connected periodic snapshot stays lightweight; on-demand report retains real routes, safe partial failures and private metadata redaction'
    }
} finally {
    Set-Item Function:Invoke-MeshCli -Value $script:RealInvokeMeshCli
    Set-Item Function:Get-Profile -Value $script:RealGetProfile
    Set-Item Function:Get-NetworkFingerprint -Value $script:RealGetNetworkFingerprint
    if (Test-Path Function:ConvertFrom-Json) { Remove-Item Function:ConvertFrom-Json }
    if ($null -ne $core) {
        if (!$core.HasExited) { Stop-Process -Id $core.Id -Force; $core.WaitForExit() }
        $core.Dispose()
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
    $env:ProgramData = $oldProgramData
}
