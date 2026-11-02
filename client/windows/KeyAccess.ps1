function Initialize-KeyApi {
    if ('Civ6Relay.Access.Api' -as [type]) { return }
    Add-Type -AssemblyName System.Net.Http
    Add-Type -ReferencedAssemblies @('System.Net.Http', [Net.HttpStatusCode].Assembly.Location) -TypeDefinition @'
using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading.Tasks;
namespace Civ6Relay.Access {
    public static class Api {
        private static readonly HttpClient Client = CreateClient();
        private static HttpClient CreateClient() {
            var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false });
            client.Timeout = TimeSpan.FromSeconds(10);
            client.MaxResponseContentBufferSize = 32768;
            return client;
        }
        public static async Task<string> PostAsync(string url, string body, string token) {
            using (var request = new HttpRequestMessage(HttpMethod.Post, url)) {
                request.Content = new StringContent(body, Encoding.UTF8, "application/json");
                if (!String.IsNullOrEmpty(token))
                    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                using (var response = await Client.SendAsync(request).ConfigureAwait(false))
                    return await response.Content.ReadAsStringAsync().ConfigureAwait(false);
            }
        }
        public static async Task<string> GetAsync(string url) {
            using (var response = await Client.GetAsync(url).ConfigureAwait(false)) {
                if (response.StatusCode == System.Net.HttpStatusCode.NotFound ||
                    response.StatusCode == System.Net.HttpStatusCode.MethodNotAllowed ||
                    response.StatusCode == System.Net.HttpStatusCode.NotImplemented)
                    return "{\"error\":\"VERSION_UNAVAILABLE\",\"message\":\"此服务器未提供版本查询接口。\"}";
                if (!response.IsSuccessStatusCode)
                    return "{\"error\":\"VERSION_QUERY_FAILED\",\"message\":\"服务器版本查询失败，请稍后重试。\"}";
                return await response.Content.ReadAsStringAsync().ConfigureAwait(false);
            }
        }
    }
}
'@
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Get-KeyServiceUrl {
    param([string]$Endpoint, [string]$Port)
    $target = New-ClientPreferences '连接' $Endpoint $Port
    $address = $null
    $loopback = $target.endpoint -eq 'localhost'
    if ([Net.IPAddress]::TryParse($target.endpoint, [ref]$address)) { $loopback = [Net.IPAddress]::IsLoopback($address) }
    $scheme = if ($loopback) { 'http' } else { 'https' }
    return ($scheme + '://' + $target.endpoint + ':' + $target.port)
}

function Start-KeyApiRequest {
    param([string]$Endpoint,[string]$Port,[string]$Path,[object]$Body,[string]$Token='')
    Initialize-KeyApi
    $url = (Get-KeyServiceUrl $Endpoint $Port) + $Path
    return [Civ6Relay.Access.Api]::PostAsync($url, ($Body | ConvertTo-Json -Compress), $Token)
}

function Start-ServerVersionRequest {
    param([string]$Endpoint,[string]$Port)
    Initialize-KeyApi
    return [Civ6Relay.Access.Api]::GetAsync((Get-KeyServiceUrl $Endpoint $Port) + '/v1/version')
}

function Complete-ServerVersionRequest {
    param([object]$Task)
    $response = Complete-KeyApiRequest $Task
    foreach ($name in @('server_version','engine_version','api_version')) {
        if (!$response -or !$response.PSObject.Properties[$name] -or ![string]$response.$name) {
            throw '服务器未返回有效的版本信息。'
        }
    }
    return $response
}

function Complete-KeyApiRequest {
    param([object]$Task)
    try { $text = $Task.GetAwaiter().GetResult() }
    catch { throw '无法连接服务器接入接口。请检查地址、端口、网络和服务器 HTTPS 证书。' }
    try { $response = ConvertFrom-Json -InputObject $text }
    catch { throw '服务器未返回有效的接入信息，请检查服务器版本和接入端口。' }
    if ($response.PSObject.Properties['error']) {
        $failure = New-Object InvalidOperationException ([string]$response.message)
        $failure.Data['AccessCode'] = [string]$response.error
        throw $failure
    }
    return $response
}

function Get-SavedAccessKey {
    param([string]$Endpoint,[string]$Port)
    $path = Join-Path $script:ManagedRoot 'access-key.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($saved.endpoint -eq $Endpoint -and [string]$saved.port -eq $Port) { return [string]$saved.key }
    return ''
}

function Save-AccessKey {
    param([string]$Endpoint,[string]$Port,[string]$Key)
    Protect-ManagedDirectory
    $saved = @{endpoint=$Endpoint.Trim();port=$Port.Trim();key=$Key.Trim()}
    [IO.File]::WriteAllText((Join-Path $script:ManagedRoot 'access-key.json'),
        ($saved | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}

function Test-UseServerAccess {
    param([object]$Preferences,[string]$Key)
    # Old self-hosted exports retain their private profile and direct connection.
    # New universal packages receive the profile from the chosen server.
    return ($Key.Trim().Length -gt 0 -or !(Test-Path -LiteralPath (Join-Path $script:PackageRoot 'profile.json') -PathType Leaf))
}

function Save-ServerAccess {
    param([object]$Access,[object]$Preferences)
    Protect-ManagedDirectory
    $value = @{target=$Preferences.endpoint;target_port=$Preferences.port;access=$Access}
    [IO.File]::WriteAllText((Join-Path $script:ManagedRoot 'server-session.json'),
        ($value | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
}

function Get-SavedServerAccess {
    param([object]$Preferences)
    $path = Join-Path $script:ManagedRoot 'server-session.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $value = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($value.target -eq $Preferences.endpoint -and [string]$value.target_port -eq [string]$Preferences.port) { return $value.access }
    return $null
}

function Start-KeyLeaseWorker {
    param([object]$Access,[object]$Process)
    if (!$Access -or !$Access.PSObject.Properties['session_token']) { return }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $worker = Join-Path $script:PackageRoot 'KeyLease.ps1'
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $worker + '" -EngineId ' + $Process.Id + ' -EngineStartTicks ' + $Process.StartTime.ToUniversalTime().Ticks
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $workerProcess = [Diagnostics.Process]::Start($info)
    $workerProcess.Dispose()
}

function Watch-KeySession {
    param([object]$Session,[int]$EngineId,[long]$EngineStartTicks)
    $access = $Session.access
    $token = [string]$access.session_token
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lease = [double]$access.lease_seconds
    $renew = [double]$access.renew_seconds
    $nextRenew = [Math]::Min($renew,$lease/2)
    try {
        while ($true) {
            $owned = Get-OwnRelayProcess -Fast
            if (!$owned -or $owned.Id -ne $EngineId -or $owned.StartTime.ToUniversalTime().Ticks -ne $EngineStartTicks) { break }
            if ($clock.Elapsed.TotalSeconds -ge $lease) {
                Stop-RelayProcess $owned
                break
            }
            if ($clock.Elapsed.TotalSeconds -ge $nextRenew) {
                try {
                    $task = Start-KeyApiRequest $session.target ([string]$session.target_port) '/v1/renew' @{} $token
                    $remaining = [Math]::Max(1,[int](($lease-$clock.Elapsed.TotalSeconds)*1000))
                    if (!$task.Wait($remaining)) { Stop-RelayProcess $owned; break }
                    $response = Complete-KeyApiRequest $task
                    $lease = [double]$response.lease_seconds
                    $renew = [double]$response.renew_seconds
                    $clock.Restart()
                    $nextRenew = [Math]::Min($renew,$lease/2)
                } catch {
                    if ($_.Exception.Data['AccessCode'] -in @('KEY_EXPIRED','SESSION_EXPIRED')) {
                        Stop-RelayProcess $owned
                        break
                    }
                    $nextRenew = $clock.Elapsed.TotalSeconds + 5
                }
            }
            Start-Sleep -Seconds 1
        }
    } finally {
        try {
            $task = Start-KeyApiRequest $session.target ([string]$session.target_port) '/v1/release' @{} $token
            [void](Complete-KeyApiRequest $task)
        } catch { }
    }
}
