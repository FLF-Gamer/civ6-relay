param([string]$ConfigOutput = '', [string]$SharedConfigOutput = '')
$env:ProgramData = '/tmp/civ6-mesh-powershell'
. /workspace/client/windows/Civ6Relay.ps1 -LibraryOnly
function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Throws([scriptblock]$Body) { try { & $Body } catch { return }; throw 'Expected failure' }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('civ6-test-' + [Guid]::NewGuid())
New-Item -ItemType Directory $testRoot | Out-Null
$script:ManagedRoot = Join-Path $testRoot 'managed'
$script:ManagedConfig = Join-Path $script:ManagedRoot 'network.toml'
$script:PackageRoot = Join-Path $testRoot 'package'
New-Item -ItemType Directory $script:PackageRoot | Out-Null
try {
    $prefs = Get-ClientPreferences
    Assert ($prefs.endpoint -eq '' -and $prefs.port -eq '' -and $prefs.display_name -eq '') 'Initial inputs must be blank'
    $prefs = New-ClientPreferences '玩家 "甲"' '8.8.8.8' '51820'
    Assert ($prefs.display_name -eq '玩家 "甲"') 'Chinese nickname changed'
    Throws { New-ClientPreferences '玩家' '8.8.8.8:1234' '51820' }
    Throws { New-ClientPreferences '玩家' '8.8.8.8' '70000' }
    function Get-ClientPreferences { return $prefs }
    $profile = [ordered]@{
        schema=3;version='3.4.0-preview';backend='easytier';routing_mode='lan-mesh';engine_version='2.6.4-civ6.2'
        player='player1';instance_id=[Guid]::NewGuid().ToString();credential_id=[Guid]::NewGuid().ToString()
        network_name='civ6-test';network='10.77.77.0/24';client_ip='10.77.77.2';mtu=1360
        credential_secret=[Convert]::ToBase64String((1..32));server_public_key=[Convert]::ToBase64String((33..64))
        client_public_key=[Convert]::ToBase64String((65..96));expires_at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600
    }
    $profile | ConvertTo-Json | Set-Content (Join-Path $script:PackageRoot 'profile.json') -Encoding UTF8
    $loaded = Get-Profile
    $profile.engine_version='2.6.4'
    $profile | ConvertTo-Json | Set-Content (Join-Path $script:PackageRoot 'profile.json') -Encoding UTF8
    Assert ((Get-Profile).credential_secret -eq $loaded.credential_secret) 'Existing mesh credential cannot upgrade'
    $profile.engine_version='2.6.4-civ6.2'
    $config = Get-ConnectionConfig $loaded
    Assert ($config.Contains('routes = ["10.77.77.0/24"]')) 'Game route missing'
    Assert (!$config.Contains('0.0.0.0/0') -and $config.Contains('accept_dns = false') -and $config.Contains('enable_exit_node = false')) 'Full-device routing found'
    Assert ($config.Contains('hostname = "玩家 \"甲\""')) 'Nickname TOML escaping failed'
    Assert (!$config.Contains('--credential') -and !(Get-RelayArguments).Contains($loaded.credential_secret)) 'Credential exposed in argv'
    if ($ConfigOutput) { [IO.File]::WriteAllText($ConfigOutput, $config, (New-Object Text.UTF8Encoding($false))) }
    $profile.schema=2
    $profile | ConvertTo-Json | Set-Content (Join-Path $script:PackageRoot 'profile.json') -Encoding UTF8
    Throws { Get-Profile }
    # All copies contain identical shared access data; each computer gets its own identity.
    function Protect-ManagedDirectory { New-Item -ItemType Directory $script:ManagedRoot -Force | Out-Null }
    $shared = [ordered]@{}
    foreach ($key in $profile.Keys) { if ($key -notin @('player','instance_id','client_ip')) { $shared[$key]=$profile[$key] } }
    $shared.schema=4; $shared.access_mode='shared'; $shared.engine_version='2.6.4-civ6.2'
    $shared | ConvertTo-Json | Set-Content (Join-Path $script:PackageRoot 'profile.json') -Encoding UTF8
    $firstShared = Get-Profile
    Assert ((Get-Profile).instance_id -eq $firstShared.instance_id) 'Local identity changed on reconnect'
    $baseRoot=$script:ManagedRoot
    $script:ManagedRoot=Join-Path $testRoot 'other-computer'
    $secondShared=Get-Profile
    Assert ($firstShared.instance_id -ne $secondShared.instance_id) 'Same common package reuses node identity'
    Assert ($firstShared.credential_secret -eq $secondShared.credential_secret) 'Access information is not shared'
    $script:ManagedRoot=$baseRoot
    $sharedConfig=Get-ConnectionConfig $firstShared
    Assert ($sharedConfig.Contains('dhcp = true') -and $sharedConfig.Contains('dhcp_subnet = "10.77.77.0/24"')) 'Common package has no automatic game IP allocation'
    Assert (!$sharedConfig.Contains('ipv4 = ') -and !$sharedConfig.Contains('0.0.0.0/0')) 'Common package reuses a fixed IP or exit route'
    if ($SharedConfigOutput) { [IO.File]::WriteAllText($SharedConfigOutput,$sharedConfig,(New-Object Text.UTF8Encoding($false))) }
    $routes = @(
        [pscustomobject]@{ipv4='10.77.77.2/24';hostname='self';path_len=0;next_hop_lat=0},
        [pscustomobject]@{ipv4='';hostname='Civ6Coordinator';path_len=1;next_hop_lat=20},
        [pscustomobject]@{ipv4='10.77.77.3/24';hostname='玩家乙';path_len=1;next_hop_lat=12.34;path_latency=500},
        [pscustomobject]@{ipv4='10.77.77.4/24';hostname='玩家丙';path_len=2;next_hop_lat=20.5;path_latency=1000}
    )
    $peers = @(Convert-MeshRoutes $routes '10.77.77.2')
    Assert ($peers.Count -eq 2 -and $peers[0].Channel -eq 'P2P 直连' -and $peers[1].Channel -eq '服务器中继') 'Actual path classification failed'
    Assert ($peers[0].RTT -eq '12.3 ms' -and $peers[1].RTT -eq '到中继 20.5 ms') 'Unmeasured route cost shown as RTT'
    Throws { Convert-MeshRoutes @([pscustomobject]@{hostname='bad'}) '10.77.77.2' }
    # Reconnect must not hash/copy large components when the version is unchanged.
    New-Item -ItemType Directory (Join-Path $script:PackageRoot 'bin') | Out-Null
    $script:InstallCalls=0
    function Install-Component {
        $script:InstallCalls++
        New-Item -ItemType Directory (Join-Path $script:ManagedRoot 'bin') -Force | Out-Null
        Copy-Item (Join-Path $script:PackageRoot 'bin/checksums.json') (Join-Path $script:ManagedRoot 'bin/checksums.json') -Force
    }
    Set-Content (Join-Path $script:PackageRoot 'bin/checksums.json') '{"version":1}'
    Ensure-Component
    Ensure-Component
    Assert ($script:InstallCalls -eq 1) 'Unchanged components reinstalled'
    Set-Content (Join-Path $script:PackageRoot 'bin/checksums.json') '{"version":2}'
    Ensure-Component
    Assert ($script:InstallCalls -eq 2) 'Updated components not installed'
    Initialize-RelayNative
    'PASS shared package, per-computer identity, automatic IP config, preferences, profile compatibility, route scope, real path display, install-once, PowerShell/C# compilation'
} finally { Remove-Item $testRoot -Recurse -Force }
