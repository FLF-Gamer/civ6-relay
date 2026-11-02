$env:ProgramData = [IO.Path]::GetTempPath()
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'client/windows/Civ6Relay.ps1') -LibraryOnly
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('civ6-key-'+[Guid]::NewGuid())
$script:ManagedRoot = Join-Path $testRoot 'managed'
$script:PackageRoot = Join-Path $testRoot 'package'
$null = New-Item -ItemType Directory $script:PackageRoot -Force
function Protect-ManagedDirectory { $null = New-Item -ItemType Directory $script:ManagedRoot -Force }
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
public sealed class KeyHttpFixture : IDisposable {
    public ConcurrentQueue<string> Replies = new ConcurrentQueue<string>();
    public ConcurrentQueue<string> Requests = new ConcurrentQueue<string>();
    public ConcurrentQueue<string> Methods = new ConcurrentQueue<string>();
    public int Port;
    private HttpListener listener;
    private Task worker;
    public KeyHttpFixture() {
        var probe = new TcpListener(IPAddress.Loopback, 0); probe.Start();
        Port = ((IPEndPoint)probe.LocalEndpoint).Port; probe.Stop();
        listener = new HttpListener(); listener.Prefixes.Add("http://127.0.0.1:"+Port+"/"); listener.Start();
        worker = Task.Run((Action)Serve);
    }
    private void Serve() {
        try {
            while (listener.IsListening) {
                var context = listener.GetContext();
                Methods.Enqueue(context.Request.HttpMethod);
                using (var reader = new StreamReader(context.Request.InputStream))
                    Requests.Enqueue(context.Request.RawUrl+" "+reader.ReadToEnd());
                string value;
                if (!Replies.TryDequeue(out value)) value = "{}";
                context.Response.StatusCode = value.Contains("KEY_REQUIRED") ? 401 :
                    value == "__404__" ? 404 : value == "__501__" ? 501 : value == "__503__" ? 503 : 200;
                context.Response.ContentType = "application/json; charset=utf-8";
                var bytes = Encoding.UTF8.GetBytes(value); context.Response.ContentLength64 = bytes.Length;
                context.Response.OutputStream.Write(bytes, 0, bytes.Length); context.Response.Close();
            }
        } catch (HttpListenerException) { } catch (ObjectDisposedException) { }
    }
    public void Dispose() { listener.Stop(); listener.Close(); worker.Wait(3000); }
}
'@
$fixture = New-Object KeyHttpFixture
try {
    Assert ((Get-KeyServiceUrl 'relay.example.com' '15888') -eq 'http://relay.example.com:15888') 'Public server URL is incorrect'
    $script:TestPreferences = New-ClientPreferences '测试玩家' '127.0.0.1' ([string]$fixture.Port)
    function Get-ClientPreferences { return $script:TestPreferences }
    Assert (Test-UseServerAccess $script:TestPreferences '') 'A universal package must request access from the chosen server'
    $fixture.Replies.Enqueue('{"error":"KEY_REQUIRED","message":"请填写 Key。"}')
    $task = Start-KeyApiRequest '127.0.0.1' ([string]$fixture.Port) '/v1/connect' @{device_id=(Get-DeviceInstanceId);key=''}
    $rejected = $false
    try { Complete-KeyApiRequest $task } catch { $rejected = $_.Exception.Data['AccessCode'] -eq 'KEY_REQUIRED' }
    Assert $rejected 'HTTP 401 must preserve the useful Key-required response'
    $fixture.Replies.Enqueue('{"key":"C6-EXAMPLE-KEY","duration_hours":48,"max_players":6}')
    $task = Start-KeyApiRequest '127.0.0.1' ([string]$fixture.Port) '/v1/keys' @{device_id=(Get-DeviceInstanceId)}
    $issued = Complete-KeyApiRequest $task
    Save-AccessKey '127.0.0.1' ([string]$fixture.Port) $issued.key
    Assert ((Get-SavedAccessKey '127.0.0.1' ([string]$fixture.Port)) -eq $issued.key) 'Generated Key was not retained'
    Assert ((Get-SavedAccessKey 'other.example.com' ([string]$fixture.Port)) -eq '') 'A Key must not be reused for a different server'
    $profile = @{
        schema=4;version='3.5.0-preview';backend='easytier';routing_mode='lan-mesh';engine_version='2.6.4-civ6.2';access_mode='shared'
        credential_id=[Guid]::NewGuid().ToString();network_name='civ6-key-test';network='10.231.0.0/24';mtu=1360
        credential_secret=[Convert]::ToBase64String((1..32));server_public_key=[Convert]::ToBase64String((33..64))
        client_public_key=[Convert]::ToBase64String((65..96));expires_at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600
    }
    $reply = @{profile=$profile;endpoint='8.8.8.8';port=20000;server_time=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}
    $fixture.Replies.Enqueue(($reply | ConvertTo-Json -Depth 8 -Compress))
    $task = Start-KeyApiRequest '127.0.0.1' ([string]$fixture.Port) '/v1/connect' @{device_id=(Get-DeviceInstanceId);key=$issued.key}
    $access = Complete-KeyApiRequest $task
    $loaded = Get-Profile -ServerAccess $access
    Assert ($loaded.endpoint -eq '8.8.8.8' -and $loaded.port -eq 20000) 'The mesh must use the granted endpoint, not the HTTP port'
    Assert ($loaded.player -eq '测试玩家') 'Nickname changed during access negotiation'
    Save-ServerAccess $access $script:TestPreferences
    Assert ((Get-Profile).credential_id -eq $loaded.credential_id) 'Diagnostics cannot load the current server-issued profile'
    Assert ($fixture.Requests.Count -eq 3) 'Unexpected capability probes or extra connection requests'
    $requests = $fixture.Requests.ToArray()
    Assert ($requests[2].StartsWith('/v1/connect ') -and $requests[2].Contains('C6-EXAMPLE-KEY')) 'A supplied Key was not sent on the first connection request'
    $fixture.Replies.Enqueue('{"key":null,"message":"此服务器无需 Key。"}')
    $task = Start-KeyApiRequest '127.0.0.1' ([string]$fixture.Port) '/v1/keys' @{device_id=(Get-DeviceInstanceId)}
    $free = Complete-KeyApiRequest $task
    Assert (!$free.key -and $free.message -eq '此服务器无需 Key。') 'Explicit Key request on a free server must return an informational reply'
    # Free server reply: the same profile flow works without a token or mode banner.
    Assert (!$access.PSObject.Properties['session_token']) 'Free connection unexpectedly needs a lease'
    $profile | ConvertTo-Json | Set-Content (Join-Path $script:PackageRoot 'profile.json') -Encoding UTF8
    Assert (!(Test-UseServerAccess $script:TestPreferences '')) 'Existing self-hosted exports must retain direct connection'
    Assert (Test-UseServerAccess $script:TestPreferences $issued.key) 'A supplied Key must select server access even with an old export'
    $fixture.Replies.Enqueue('{"server_version":"3.5.2-preview","engine_version":"2.6.4-civ6.2","api_version":1}')
    $task = Start-ServerVersionRequest '127.0.0.1' ([string]$fixture.Port)
    $version = Complete-ServerVersionRequest $task
    Assert ($version.server_version -eq '3.5.2-preview') 'Server version was not read from the response'
    Assert ($fixture.Methods.ToArray()[-1] -eq 'GET') 'Version query must be a read-only GET'
    Assert ($fixture.Requests.ToArray()[-1] -eq '/v1/version ') 'Version query unexpectedly transmitted a Key or device identity'
    foreach ($legacy in @('__404__','__501__')) {
        $fixture.Replies.Enqueue($legacy)
        $task = Start-ServerVersionRequest '127.0.0.1' ([string]$fixture.Port)
        $unsupported = $false
        try { Complete-ServerVersionRequest $task } catch { $unsupported = $_.Exception.Data['AccessCode'] -eq 'VERSION_UNAVAILABLE' }
        Assert $unsupported 'Legacy servers must show an unsupported-query message instead of a fake version'
    }
    $fixture.Replies.Enqueue('{}')
    $task = Start-ServerVersionRequest '127.0.0.1' ([string]$fixture.Port)
    $invalid = $false
    try { Complete-ServerVersionRequest $task } catch { $invalid = $_.Exception.Message -eq '服务器未返回有效的版本信息。' }
    Assert $invalid 'Missing version information must not be presented as a successful query'
    foreach ($kind in @('rooms','load')) {
        $fixture.Replies.Enqueue('{"active_rooms":2,"max_rooms":4,"status":"green","label":"正常"}')
        $task = Start-ServerStatusRequest '127.0.0.1' ([string]$fixture.Port) $kind ([Threading.CancellationToken]::None)
        $status = Complete-KeyApiRequest $task
        Assert ($status.active_rooms -eq 2 -and $status.status -eq 'green') 'Server status response was not read.'
        Assert ($fixture.Methods.ToArray()[-1] -eq 'GET' -and $fixture.Requests.ToArray()[-1] -eq ('/v1/'+$kind+' ')) 'Status query must not transmit a Key or device identity.'
    }
    foreach ($failure in @(@('__404__','STATUS_UNAVAILABLE'),@('__503__','STATUS_QUERY_FAILED'))) {
        $fixture.Replies.Enqueue($failure[0])
        $task = Start-ServerStatusRequest '127.0.0.1' ([string]$fixture.Port) 'rooms' ([Threading.CancellationToken]::None)
        $expected = $false
        try { Complete-KeyApiRequest $task } catch { $expected = $_.Exception.Data['AccessCode'] -eq $failure[1] }
        Assert $expected 'Server status HTTP errors were not mapped correctly.'
    }
    $script:OpenedUrls = New-Object 'Collections.Generic.List[string]'
    function Start-Process { param([string]$FilePath); $script:OpenedUrls.Add($FilePath) }
    Open-ProjectPage 'Repository'
    Open-ProjectPage 'Releases'
    Assert ($script:OpenedUrls[0] -eq 'https://github.com/FLF-Gamer/civ6-relay') 'Repository link is incorrect'
    Assert ($script:OpenedUrls[1] -eq 'https://github.com/FLF-Gamer/civ6-relay/releases') 'Update link is incorrect'
    $script:Stopped = 0
    $script:Owned = [pscustomobject]@{Id=12345;StartTime=[DateTime]::UtcNow}
    function Get-OwnRelayProcess { return $script:Owned }
    function Stop-RelayProcess { param($Process); $script:Stopped=$Process.Id }
    $session = [pscustomobject]@{target='127.0.0.1';target_port=$fixture.Port;access=[pscustomobject]@{
        session_token='fixture-token';lease_seconds=5;renew_seconds=1
    }}
    $fixture.Replies.Enqueue('{"error":"KEY_EXPIRED","message":"Key 已过期。"}')
    $fixture.Replies.Enqueue('{"released":true}')
    Watch-KeySession $session $script:Owned.Id $script:Owned.StartTime.ToUniversalTime().Ticks
    Assert ($script:Stopped -eq 12345) 'Expired Key did not stop its owned engine'
    $script:Stopped = 0
    $fixture.Replies.Enqueue('{"released":true}')
    Watch-KeySession $session 99999 $script:Owned.StartTime.ToUniversalTime().Ticks
    Assert ($script:Stopped -eq 0) 'A replaced engine was incorrectly stopped'
    $script:LeaseRequests = New-Object 'Collections.Generic.List[string]'
    function Start-KeyApiRequest {
        param([string]$Endpoint,[string]$Port,[string]$Path,[object]$Body,[string]$Token)
        $script:LeaseRequests.Add($Path)
        $pending=New-Object 'Threading.Tasks.TaskCompletionSource[string]'
        if ($Path -eq '/v1/release') { $pending.SetResult('{"released":true}') }
        return $pending.Task
    }
    $session.access.lease_seconds=2
    $deadline=[Diagnostics.Stopwatch]::StartNew()
    Watch-KeySession $session $script:Owned.Id $script:Owned.StartTime.ToUniversalTime().Ticks
    Assert ($script:Stopped -eq 12345 -and $deadline.Elapsed.TotalSeconds -lt 4) 'An unresponsive renewal delayed the local lease deadline'
    Assert ($script:LeaseRequests.Contains('/v1/release')) 'Lease worker failed to release on exit'
    'PASS actual HTTP Key generation/required response, first-request Key, server selection, free grant, profile and legacy compatibility'
    'PASS Key expiry, owned-process protection, renewal timeout and release'
    'PASS public server version GET, legacy-server messages and GitHub update links'
} finally {
    $fixture.Dispose()
    Remove-Item $testRoot -Recurse -Force
}
