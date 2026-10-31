param(
    [string]$CorePath = '',
    [string]$CliPath = '',
    [switch]$SkipIntegration
)
# Run in the cached PowerShell container with --network none. The integration
# uses only loopback, dummy access data, and no TUN or host network changes.
$oldProgramData = $env:ProgramData
$oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('civ6-status-' + [Guid]::NewGuid())
$env:ProgramData = $testRoot
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'client/windows/Civ6Relay.ps1') -LibraryOnly
$script:ManagedRoot = Join-Path $testRoot 'managed'
$script:TestProcesses = New-Object 'Collections.Generic.List[Diagnostics.Process]'
New-Item -ItemType Directory (Join-Path $script:ManagedRoot 'bin') -Force | Out-Null

function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Assert-ThrowsMessage([scriptblock]$Body, [string]$Expected, [string]$Message) {
    try { & $Body | Out-Null } catch {
        Assert ($_.Exception.Message -eq $Expected) $Message
        return
    }
    throw $Message
}
function Set-JsonArrayMode([bool]$WindowsPowerShellSemantics) {
    if (Test-Path Function:ConvertFrom-Json) { Remove-Item Function:ConvertFrom-Json }
    if ($WindowsPowerShellSemantics) {
        # PS7's switch reproduces PS5.1's single pipeline object for a JSON array.
        # This emulates output semantics only; it is not a Windows PS5.1 run.
        function script:ConvertFrom-Json {
            [CmdletBinding()]
            param([Parameter(Mandatory=$true, ValueFromPipeline=$true)][string]$InputObject)
            process { Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject -NoEnumerate }
        }
    }
}
function Test-JsonRouteParsing([bool]$WindowsPowerShellSemantics) {
    Set-JsonArrayMode $WindowsPowerShellSemantics
    $one = '[{"ipv4":"10.77.77.2/24","hostname":"玩家甲","path_len":0}]'
    $many = '[{"ipv4":"10.77.77.2/24","hostname":"玩家甲","path_len":0},{"ipv4":"","hostname":"Civ6Coordinator","path_len":1},{"ipv4":"10.77.77.3/24","hostname":"玩家乙","path_len":2,"next_hop_lat":12.34}]'
    Assert (@(ConvertFrom-MeshJson '[]').Count -eq 0) 'Empty route JSON must produce no pipeline objects'
    $rows = @(ConvertFrom-MeshJson $one)
    Assert ($rows.Count -eq 1 -and $rows[0].ipv4 -eq '10.77.77.2/24') 'Single route JSON must produce one row'
    Assert ($rows[0].hostname -ceq '玩家甲') 'Chinese own hostname changed during JSON parsing'
    Assert (@(Convert-MeshRoutes $rows '').Count -eq 0) 'Own route must not become a player row'
    $rows = @(ConvertFrom-MeshJson $many)
    Assert ($rows.Count -eq 3 -and $rows[0] -isnot [array]) 'Multiple JSON routes must be separate pipeline objects'
    $peers = @(Convert-MeshRoutes $rows '10.77.77.2')
    Assert ($peers.Count -eq 1 -and $peers[0].Player -ceq '玩家乙') 'Coordinator/own route filtering or Chinese peer name failed'
    Assert ($peers[0].VirtualIP -eq '10.77.77.3' -and $peers[0].Channel -eq '服务器中继') 'Peer virtual IP or actual route classification failed'
    Assert ($peers[0].RTT -eq '到中继 12.3 ms') 'Relay next-hop latency display changed'
    Assert-ThrowsMessage { ConvertFrom-MeshJson '{invalid-json:dummy-sensitive-marker}' } '状态组件返回的 JSON 无法解析，请检查组件。' 'Invalid JSON must return a safe error without raw content'
    if ($WindowsPowerShellSemantics) {
        $legacy = @($many | ConvertFrom-Json)
        Assert ($legacy.Count -eq 1 -and $legacy[0] -is [array]) 'PS5.1 array-output emulation did not reproduce the old nested array'
        Assert-ThrowsMessage { Convert-MeshRoutes $legacy '10.77.77.2' } '组网状态格式不匹配。' 'Legacy pipeline must reproduce the original nested-array failure'
    }
}
function Get-FreeLoopbackPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}
function Start-MeshTestCore([string]$Name, [string]$IPv4, [int]$ListenPort, [int]$PeerPort) {
    $id = [Guid]::NewGuid().ToString()
    $configPath = Join-Path $testRoot ($id + '.toml')
    $listen = if ($ListenPort) { 'listeners = ["tcp://127.0.0.1:' + $ListenPort + '"]' } else { 'listeners = []' }
    $config = @(
        ('instance_id = "' + $id + '"'), 'instance_name = "civ6-status-test"',
        ('hostname = "' + $Name + '"'), $listen,
        'stun_servers = []', 'stun_servers_v6 = []'
    )
    if ($IPv4) { $config += 'ipv4 = "' + $IPv4 + '/24"' }
    if ($PeerPort) { $config += @('[[peer]]', ('uri = "tcp://127.0.0.1:' + $PeerPort + '"')) }
    $config += @(
        '[network_identity]', 'network_name = "civ6-status-loopback-test"',
        'network_secret = "dummy-local-status-test-secret"', '[flags]',
        'no_tun = true', 'disable_p2p = true', 'disable_upnp = true',
        'disable_udp_hole_punching = true', 'disable_tcp_hole_punching = true',
        'accept_dns = false', 'enable_exit_node = false', '[console_logger]', 'level = "off"'
    )
    [IO.File]::WriteAllText($configPath, ($config -join "`n"), (New-Object Text.UTF8Encoding($false)))
    $rpcPort = Get-FreeLoopbackPort
    $process = Start-Process -FilePath $CorePath -ArgumentList @('-c', ('"' + $configPath + '"'), '--disable-env-parsing', '--rpc-portal', ('127.0.0.1:' + $rpcPort)) -PassThru -RedirectStandardOutput (Join-Path $testRoot ($id + '.stdout')) -RedirectStandardError (Join-Path $testRoot ($id + '.stderr'))
    $script:TestProcesses.Add($process)
    return [pscustomobject]@{Process=$process; InstanceId=$id; RpcPort=$rpcPort}
}
function Test-RealMeshSnapshot([object]$Client, [bool]$WindowsPowerShellSemantics) {
    Set-JsonArrayMode $WindowsPowerShellSemantics
    $script:RpcPort = $Client.RpcPort
    # Shared schema-4 clients save an empty client_ip; the self route supplies it.
    @{
        marker='civ6-relay/v3'; backend='easytier'; instance_id=$Client.InstanceId; client_ip=''
        process_id=$Client.Process.Id; start_ticks=$Client.Process.StartTime.ToUniversalTime().Ticks.ToString()
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Encoding UTF8
    Assert ($null -ne (Get-OwnRelayProcess -Fast)) 'Real client process ownership check failed'
    $routes = @(Invoke-MeshCli -InstanceId $Client.InstanceId -Command route)
    Assert ($routes.Count -eq 3 -and $routes[0] -isnot [array]) 'Real CLI/RPC route output must contain three separate rows'
    $own = @($routes | Where-Object { $_.path_len -eq 0 })
    Assert ($own.Count -eq 1 -and $own[0].hostname -ceq '玩家甲' -and $own[0].ipv4 -eq '10.77.77.2/24') 'Real CLI own IP or Chinese hostname changed'
    $snapshot = Get-MeshSnapshot
    Assert ($snapshot.Text -like '已接入服务器；虚拟 IP：10.77.77.2*') 'Connected snapshot must discover own virtual IP from real routes'
    Assert ($snapshot.Text -like '*直连 0 人，中继 1 人。') 'Connected snapshot must report actual relay count'
    Assert ($snapshot.Peers.Count -eq 1 -and $snapshot.Peers[0].Player -ceq '玩家乙') 'Connected grid must preserve Chinese peer name and omit coordinator/self'
    Assert ($snapshot.Peers[0].VirtualIP -eq '10.77.77.3' -and $snapshot.Peers[0].Channel -eq '服务器中继') 'Connected grid must use real peer IP and relay path'
    Assert-ThrowsMessage { Invoke-MeshCli -InstanceId ([Guid]::NewGuid().ToString()) } '后台实例与本机记录不匹配，请断开后重新连接。' 'Real RPC instance mismatch must produce a safe actionable error'
}

try {
    $canEmulate = (Get-Command Microsoft.PowerShell.Utility\ConvertFrom-Json).Parameters.ContainsKey('NoEnumerate')
    Test-JsonRouteParsing $false
    if ($canEmulate) { Test-JsonRouteParsing $true }
    'PASS empty/one/multiple route JSON, Chinese names, self/coordinator filtering, safe invalid JSON'
    if ($canEmulate) { 'PASS emulated PS5.1 array output; legacy nested-array failure reproduced and fixed helper verified' }
    Set-JsonArrayMode $false
    if (!$SkipIntegration) {
        $binaryFolder = if ($env:OS -eq 'Windows_NT') { 'windows-x86_64' } else { 'linux-x86_64' }
        $suffix = if ($env:OS -eq 'Windows_NT') { '.exe' } else { '' }
        if (!$CorePath) { $CorePath = Join-Path $repoRoot ('vendor/easytier/' + $binaryFolder + '/easytier-core' + $suffix) }
        if (!$CliPath) { $CliPath = Join-Path $repoRoot ('vendor/easytier/' + $binaryFolder + '/easytier-cli' + $suffix) }
        Assert ((Test-Path -LiteralPath $CorePath -PathType Leaf) -and (Test-Path -LiteralPath $CliPath -PathType Leaf)) 'Bundled core/CLI required for status integration'
        Copy-Item -LiteralPath $CliPath -Destination (Join-Path $script:ManagedRoot 'bin/easytier-cli.exe')
        $coordinatorPort = Get-FreeLoopbackPort
        $coordinator = Start-MeshTestCore 'Civ6Coordinator' '' $coordinatorPort 0
        $client = Start-MeshTestCore '玩家甲' '10.77.77.2' 0 $coordinatorPort
        $peer = Start-MeshTestCore '玩家乙' '10.77.77.3' 0 $coordinatorPort
        $script:RpcPort = $client.RpcPort
        $ready = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(40)
        do {
            Assert (!$coordinator.Process.HasExited -and !$client.Process.HasExited -and !$peer.Process.HasExited) 'A loopback test core exited before route discovery'
            try {
                $routes = @(Invoke-MeshCli -InstanceId $client.InstanceId)
                $ready = $routes.Count -eq 3 -and @($routes | Where-Object { $_.hostname -ceq '玩家乙' -and $_.path_len -eq 2 }).Count -eq 1
            } catch { $ready = $false }
            if (!$ready) { Start-Sleep -Milliseconds 200 }
        } while (!$ready -and [DateTime]::UtcNow -lt $deadline)
        Assert $ready 'Loopback test mesh did not discover coordinator, own route, and relayed peer'
        Test-RealMeshSnapshot $client $false
        if ($canEmulate) { Test-RealMeshSnapshot $client $true }
        'PASS real bundled core/CLI/RPC connected snapshot, own IP, Chinese peer, headless coordinator, relay count'
        if ($canEmulate) { 'PASS same real CLI/RPC snapshot under emulated PS5.1 array-output semantics' }
        Set-JsonArrayMode $false
        $script:RpcPort = Get-FreeLoopbackPort
        Assert-ThrowsMessage { Invoke-MeshCli -InstanceId $client.InstanceId } ('无法连接本机状态端口 ' + $script:RpcPort + '，后台接口尚未就绪。') 'Unavailable real RPC must produce a safe actionable error'
        $snapshot = Get-MeshSnapshot
        Assert ($snapshot.Text -like '后台仍在运行；状态读取失败：无法连接本机状态端口*' -and $snapshot.Peers.Count -eq 0) 'Snapshot must preserve running state and show safe RPC failure'
        Remove-Item -LiteralPath (Join-Path $script:ManagedRoot 'bin/easytier-cli.exe')
        Assert-ThrowsMessage { Invoke-MeshCli -InstanceId $client.InstanceId } '无法启动状态查询组件，请点击“检查组件”；若正在连接，请先断开。' 'Missing real CLI must produce a safe actionable error'
        'PASS real RPC instance mismatch/unavailable port/missing CLI and safe running-process failure snapshot'
    }
} finally {
    Set-JsonArrayMode $false
    foreach ($process in $script:TestProcesses) {
        if (!$process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
        $process.Dispose()
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
    $env:ProgramData = $oldProgramData
    [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
}
