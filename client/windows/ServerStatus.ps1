function Start-ServerStatusRequest {
    param([string]$Endpoint,[string]$Port,[ValidateSet('rooms','load')][string]$Kind,[Threading.CancellationToken]$Cancellation)
    Initialize-KeyApi
    $url = (Get-KeyServiceUrl $Endpoint $Port) + '/v1/' + $Kind
    return [Civ6Relay.Access.Api]::GetAsync($url, $true, $Cancellation)
}

function New-ServerStatusMonitor {
    return [pscustomobject]@{
        Target=''; Requests=@{}; Unavailable=@{}; Cancellation=$null
        Clock=[Diagnostics.Stopwatch]::StartNew(); NextPoll=0.0
        RoomsText='组网房间：—'; LoadText='服务器负载：未连接'
    }
}

function Stop-ServerStatusMonitor {
    param([object]$Monitor)
    if ($null -ne $Monitor.Cancellation) {
        $Monitor.Cancellation.Cancel()
        $Monitor.Cancellation.Dispose()
        $Monitor.Cancellation = $null
    }
    $Monitor.Requests.Clear(); $Monitor.Unavailable.Clear()
    $Monitor.Target = ''; $Monitor.NextPoll = 0.0
    $Monitor.RoomsText = '组网房间：—'; $Monitor.LoadText = '服务器负载：未连接'
}

function Update-ServerStatusMonitor {
    param([object]$Monitor,[string]$Endpoint,[string]$Port,[bool]$Connected)
    if (!$Connected) {
        if ($Monitor.Target) { Stop-ServerStatusMonitor $Monitor }
        return
    }
    $target = $Endpoint.Trim() + ':' + $Port.Trim()
    if ($Monitor.Target -ne $target) {
        Stop-ServerStatusMonitor $Monitor
        $Monitor.Target = $target
        $Monitor.Cancellation = New-Object Threading.CancellationTokenSource
        $Monitor.RoomsText = '组网房间：查询中…'; $Monitor.LoadText = '服务器负载：查询中…'
    }
    foreach ($kind in @($Monitor.Requests.Keys)) {
        $task = $Monitor.Requests[$kind]
        if (!$task.IsCompleted) { continue }
        try {
            $response = Complete-KeyApiRequest $task
            if ($kind -eq 'rooms') {
                $Monitor.RoomsText = '组网房间：{0} / {1}' -f $response.active_rooms, $response.max_rooms
            } else {
                $cpu = if ($null -eq $response.cpu_percent) { '采样中' } else { '{0:0.#}%' -f [double]$response.cpu_percent }
                $memory = if ($null -eq $response.memory_percent) { '—' } else { '{0:0.#}%' -f [double]$response.memory_percent }
                $Monitor.LoadText = 'CPU {0} · 内存 {1}' -f $cpu, $memory
                if ($null -ne $response.network_tx_bps -and $null -ne $response.network_rx_bps) {
                    $Monitor.LoadText += ' · ↑ {0:0.#} / ↓ {1:0.#} kbps' -f ([double]$response.network_tx_bps/1000), ([double]$response.network_rx_bps/1000)
                }
            }
        } catch {
            $label = if ($kind -eq 'rooms') { '组网房间' } else { '服务器负载' }
            $message = $label + '：暂不可用'
            if ($_.Exception.Data['AccessCode'] -eq 'STATUS_UNAVAILABLE') {
                $Monitor.Unavailable[$kind] = $true
                $message = $label + '：不支持查询'
            }
            if ($kind -eq 'rooms') { $Monitor.RoomsText = $message } else { $Monitor.LoadText = $message }
        } finally { [void]$Monitor.Requests.Remove($kind) }
    }
    if ($Monitor.Requests.Count -gt 0 -or $Monitor.Clock.Elapsed.TotalSeconds -lt $Monitor.NextPoll) { return }
    $Monitor.NextPoll = $Monitor.Clock.Elapsed.TotalSeconds + 10
    foreach ($kind in @('rooms','load')) {
        if ($Monitor.Unavailable.ContainsKey($kind)) { continue }
        try {
            $Monitor.Requests[$kind] = Start-ServerStatusRequest $Endpoint $Port $kind $Monitor.Cancellation.Token
        } catch {
            if ($kind -eq 'rooms') { $Monitor.RoomsText = '组网房间：暂不可用' }
            else { $Monitor.LoadText = '服务器负载：暂不可用' }
        }
    }
}
