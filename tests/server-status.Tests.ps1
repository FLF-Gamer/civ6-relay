$env:ProgramData = [IO.Path]::GetTempPath()
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'client/windows/Civ6Relay.ps1') -LibraryOnly
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
$script:StatusCalls = New-Object 'Collections.Generic.List[object]'
function Start-ServerStatusRequest {
    param([string]$Endpoint,[string]$Port,[string]$Kind,[Threading.CancellationToken]$Cancellation)
    $source = New-Object 'Threading.Tasks.TaskCompletionSource[string]'
    $script:StatusCalls.Add([pscustomobject]@{Endpoint=$Endpoint;Kind=$Kind;Source=$source;Token=$Cancellation})
    return $source.Task
}
$monitor = New-ServerStatusMonitor
$monitor.Clock.Stop()
$monitor.Clock = [pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=0.0}}
try {
    Update-ServerStatusMonitor $monitor 'relay.example.com' '15888' $false
    Assert ($script:StatusCalls.Count -eq 0) 'Disconnected clients must not poll.'
    Update-ServerStatusMonitor $monitor 'relay.example.com' '15888' $true
    Assert ($script:StatusCalls.Count -eq 2) 'Connection must start both status requests.'
    $script:StatusCalls[0].Source.SetResult('{"active_rooms":2,"max_rooms":4}')
    $script:StatusCalls[1].Source.SetResult('{"cpu_percent":12.5,"memory_percent":28.3,"network_tx_bps":128000,"network_rx_bps":64000}')
    Update-ServerStatusMonitor $monitor 'relay.example.com' '15888' $true
    Assert ($monitor.RoomsText -eq '组网房间：2 / 4' -and $monitor.LoadText -match '12.5%.*28.3%.*128.*64') 'Status response formatting is incorrect.'
    $monitor.Clock.Elapsed.TotalSeconds = 9.99
    Update-ServerStatusMonitor $monitor 'relay.example.com' '15888' $true
    Assert ($script:StatusCalls.Count -eq 2) 'Polling occurred before ten seconds.'
    $monitor.Clock.Elapsed.TotalSeconds = 10
    Update-ServerStatusMonitor $monitor 'relay.example.com' '15888' $true
    Assert ($script:StatusCalls.Count -eq 4) 'The next polling cycle did not start after ten seconds.'
    $monitor.Clock.Elapsed.TotalSeconds = 35
    Update-ServerStatusMonitor $monitor 'relay.example.com' '15888' $true
    Assert ($script:StatusCalls.Count -eq 4) 'Pending requests must not overlap with another polling cycle.'
    Update-ServerStatusMonitor $monitor 'other.example.com' '15888' $true
    Assert ($script:StatusCalls.Count -eq 6 -and $script:StatusCalls[2].Token.IsCancellationRequested) 'Changing server did not cancel old requests.'
    $script:StatusCalls[2].Source.SetResult('{"active_rooms":99,"max_rooms":99}')
    $script:StatusCalls[4].Source.SetResult('{"active_rooms":1,"max_rooms":8}')
    $script:StatusCalls[5].Source.SetResult('{"cpu_percent":null,"memory_percent":50,"network_tx_bps":null,"network_rx_bps":null}')
    Update-ServerStatusMonitor $monitor 'other.example.com' '15888' $true
    Assert ($monitor.RoomsText -eq '组网房间：1 / 8') 'A previous server response overwrote the current server.'
    Assert ($monitor.LoadText -match '采样中.*50%' -and $monitor.LoadText -notmatch 'kbps') 'Unknown initial counters must not display invented measurements.'
    Update-ServerStatusMonitor $monitor 'other.example.com' '15888' $false
    $monitor.Clock.Elapsed.TotalSeconds = 100
    Update-ServerStatusMonitor $monitor 'other.example.com' '15888' $false
    Assert ($script:StatusCalls.Count -eq 6 -and $script:StatusCalls[4].Token.IsCancellationRequested -and $monitor.RoomsText -eq '组网房间：—') 'Disconnect did not stop and clear server status.'
    Update-ServerStatusMonitor $monitor 'other.example.com' '15888' $true
    foreach ($call in $script:StatusCalls.ToArray()[6..7]) { $call.Source.SetResult('{"error":"STATUS_UNAVAILABLE","message":"此服务器未提供状态查询接口。"}') }
    Update-ServerStatusMonitor $monitor 'other.example.com' '15888' $true
    $monitor.Clock.Elapsed.TotalSeconds = 200
    Update-ServerStatusMonitor $monitor 'other.example.com' '15888' $true
    Assert ($script:StatusCalls.Count -eq 8 -and $monitor.RoomsText -match '不支持查询') 'Legacy servers must not be polled repeatedly.'
    Stop-ServerStatusMonitor $monitor
    Update-ServerStatusMonitor $monitor 'other.example.com' '15888' $true
    foreach ($call in $script:StatusCalls.ToArray()[8..9]) { $call.Source.SetResult('{"error":"STATUS_QUERY_FAILED","message":"服务器状态暂时不可用。"}') }
    Update-ServerStatusMonitor $monitor 'other.example.com' '15888' $true
    Assert ($monitor.LoadText -match '暂不可用') 'Unavailable status was presented as current data.'
    $monitor.Clock.Elapsed.TotalSeconds = 210
    Update-ServerStatusMonitor $monitor 'other.example.com' '15888' $true
    Assert ($script:StatusCalls.Count -eq 12) 'Temporary status errors must recover on the next polling cycle.'
    'PASS ten-second asynchronous polling, no overlap, cancellation, server changes, legacy compatibility and retry'
} finally { Stop-ServerStatusMonitor $monitor }
