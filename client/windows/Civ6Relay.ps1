[CmdletBinding()]
param(
    [ValidateSet('Gui','Connect','Disconnect','Status','Diagnose','Install','Remove')]
    [string]$Action = 'Gui',
    [switch]$LibraryOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PackageRoot = $PSScriptRoot
$script:ManagedRoot = Join-Path $env:ProgramData 'Civ6RelayMesh'
$script:ManagedConfig = Join-Path $script:ManagedRoot 'network.toml'
$script:RpcPort = 15887
$script:Busy = $false
$script:LiveRuntime = $null
$script:LiveSourcePath = Join-Path $PSScriptRoot 'LiveMonitor.cs'
$script:LiveMessages = New-Object 'Collections.Generic.Queue[string]'
$script:LiveLogDropped = 0L
$script:LiveLogTotal = 0L
$script:ComponentFiles = @('easytier-core.exe','easytier-cli.exe','wintun.dll','WinDivert64.sys')

function New-ClientPreferences {
    param([string]$DisplayName, [string]$Endpoint, [string]$Port)
    $DisplayName = $DisplayName.Trim()
    if (!$DisplayName -or $DisplayName.Length -gt 24 -or $DisplayName -match '[\p{Cc}\p{Cf}]') {
        throw '请填写 1–24 个字符的玩家昵称，支持中文。'
    }
    $Endpoint = $Endpoint.Trim()
    $address = $null
    if ($Endpoint -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        ![Net.IPAddress]::TryParse($Endpoint, [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw '请填写服务器 IPv4 地址，不要包含协议或端口。'
    }
    $portNumber = 0
    if (![int]::TryParse($Port, [ref]$portNumber) -or $portNumber -lt 1024 -or $portNumber -gt 65535 -or $portNumber -eq $script:RpcPort) {
        throw '端口须为 1024–65535，不能占用本地管理端口。'
    }
    return [pscustomobject]@{display_name=$DisplayName; endpoint=$address.ToString(); port=$portNumber}
}

function Get-ClientPreferences {
    $path = Join-Path $script:ManagedRoot 'preferences.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{display_name=''; endpoint=''; port=''}
    }
    $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return New-ClientPreferences $saved.display_name $saved.endpoint $saved.port
}

function Set-PrivateDirectoryAcl {
    param([string]$Directory)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Directory -AclObject $acl
}

function Protect-ManagedDirectory {
    $marker = Join-Path $script:ManagedRoot 'managed.json'
    if (Test-Path -LiteralPath $script:ManagedRoot) {
        if (((Get-Item -LiteralPath $script:ManagedRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '配置目录不能是链接或目录联接。'
        }
        if (!(Test-Path -LiteralPath $marker -PathType Leaf)) { throw '本机配置目录被其他文件占用。' }
        $saved = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.marker -ne 'civ6-relay/v3') { throw '本机管理标记不匹配。' }
    } else {
        New-Item -ItemType Directory -Path $script:ManagedRoot | Out-Null
        @{marker='civ6-relay/v3'} | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $script:ManagedRoot -Force -Recurse)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '配置目录内不能有链接。' }
    }
    Set-PrivateDirectoryAcl $script:ManagedRoot
}

function Save-ClientPreferences {
    param([string]$DisplayName, [string]$Endpoint, [string]$Port)
    $saved = New-ClientPreferences $DisplayName $Endpoint $Port
    Protect-ManagedDirectory
    $saved | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:ManagedRoot 'preferences.json') -Encoding UTF8
    return $saved
}

function Test-Base64Key {
    param([string]$Key)
    try { return ($Key -cmatch '^[A-Za-z0-9+/]{43}=$' -and [Convert]::FromBase64String($Key).Length -eq 32) }
    catch { return $false }
}

function Get-DeviceInstanceId {
    $path = Join-Path $script:ManagedRoot 'identity.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return [Guid]::Parse([IO.File]::ReadAllText($path)).ToString()
    }
    Protect-ManagedDirectory
    $id = [Guid]::NewGuid().ToString()
    [IO.File]::WriteAllText($path, $id, (New-Object Text.UTF8Encoding($false)))
    return $id
}

function Get-Profile {
    $path = Join-Path $script:PackageRoot 'profile.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        throw '客户端配置缺失，请完整解压 ZIP。'
    }
    $profile = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $fields = @('schema','version','backend','routing_mode','engine_version','player','instance_id','network_name',
                'network','client_ip','mtu','server_public_key','client_public_key','credential_id','credential_secret','expires_at')
    $shared = $profile.schema -eq 4
    if ($shared) {
        $fields = @($fields | Where-Object { $_ -notin @('player','instance_id','client_ip') }) + @('access_mode')
    }
    foreach ($field in $fields) {
        if (!$profile.PSObject.Properties[$field]) { throw '客户端配置不完整，请重新解压客户端。' }
    }
    foreach ($field in $profile.PSObject.Properties.Name) {
        if ($field -notin $fields) { throw '客户端配置格式不兼容，请重新解压客户端。' }
    }
    if ($profile.schema -notin @(3,4) -or $profile.backend -ne 'easytier' -or
        $profile.routing_mode -ne 'lan-mesh' -or $profile.engine_version -notin @('2.6.4','2.6.4-civ6.1','2.6.4-civ6.2')) {
        throw '客户端版本不兼容，请下载新版客户端。'
    }
    if ($shared -and $profile.access_mode -ne 'shared') { throw '客户端接入模式无效。' }
    if ((!$shared -and $profile.player -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,23}$') -or $profile.network_name -notmatch '^[a-zA-Z0-9_-]{1,64}$') {
        throw '客户端网络配置无效，请重新解压客户端。'
    }
    foreach ($field in $(if ($shared) { @('credential_id') } else { @('instance_id','credential_id') })) {
        $parsedId = [Guid]::Empty
        if (![Guid]::TryParse([string]$profile.$field, [ref]$parsedId)) { throw '客户端配置无效，请重新解压客户端。' }
    }
    foreach ($field in @('server_public_key','client_public_key','credential_secret')) {
        if (!(Test-Base64Key ([string]$profile.$field))) { throw '客户端配置损坏，请重新解压客户端。' }
    }
    if ($profile.network -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.0/24$') { throw '仅支持私有 /24 游戏网段。' }
    $prefix = $Matches[1]
    $networkAddress = $null
    if (![Net.IPAddress]::TryParse(($prefix + '.0'), [ref]$networkAddress)) { throw '游戏网段无效。' }
    $octets = $networkAddress.GetAddressBytes()
    $isPrivate = $octets[0] -eq 10 -or ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
                 ($octets[0] -eq 192 -and $octets[1] -eq 168)
    if (!$isPrivate) { throw '仅支持私有游戏网段。' }
    if (!$shared -and $profile.client_ip -notmatch ('^' + [regex]::Escape($prefix) + '\.(\d{1,3})$')) {
        throw '玩家地址不在游戏网段内。'
    }
    $lastOctet = if ($shared) { 2 } else { [int]$Matches[1] }
    if ($lastOctet -lt 2 -or $lastOctet -gt 254) { throw '玩家地址无效。' }
    if ([int]$profile.mtu -lt 1280 -or [int]$profile.mtu -gt 1400) { throw 'MTU 无效。' }
    if ([long]$profile.expires_at -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { throw '客户端配置已过期，请获取新版客户端。' }
    $preferences = Get-ClientPreferences
    $preferences = New-ClientPreferences $preferences.display_name $preferences.endpoint $preferences.port
    foreach ($field in @('display_name','endpoint','port')) {
        $profile | Add-Member -NotePropertyName $field -NotePropertyValue $preferences.$field
    }
    if ($shared) {
        $profile | Add-Member -NotePropertyName instance_id -NotePropertyValue (Get-DeviceInstanceId)
        $profile | Add-Member -NotePropertyName player -NotePropertyValue $preferences.display_name
        $profile | Add-Member -NotePropertyName client_ip -NotePropertyValue ''
    }
    return $profile
}

function ConvertTo-TomlString {
    param([string]$Text)
    return ConvertTo-Json -InputObject $Text -Compress
}

function Get-ConnectionConfig {
    param([object]$Profile)
    $qName = ConvertTo-TomlString $Profile.display_name
    $qNetwork = ConvertTo-TomlString $Profile.network
    $qIPv4 = ConvertTo-TomlString ($Profile.client_ip + '/24')
    $qRoom = ConvertTo-TomlString $Profile.network_name
    $ipConfig = if ($Profile.schema -eq 4) { 'dhcp = true' + [Environment]::NewLine + 'dhcp_subnet = ' + $qNetwork } else { 'ipv4 = ' + $qIPv4 }
    $lines = @(
        '# Managed by civ6-relay/v3. Private game subnet only.',
        ('instance_id = "' + $Profile.instance_id + '"'),
        'instance_name = "civ6-relay"',
        ('hostname = ' + $qName), $ipConfig,
        'listeners = []', ('routes = [' + $qNetwork + ']'),
        'exit_nodes = []', 'proxy_network = []',
        ('credential_file = ' + (ConvertTo-TomlString (Join-Path $script:ManagedRoot 'trusted-server.json'))),
        '[[peer]]', ('uri = "udp://' + $Profile.endpoint + ':' + $Profile.port + '"'),
        ('peer_public_key = "' + $Profile.server_public_key + '"'),
        '[[peer]]', ('uri = "tcp://' + $Profile.endpoint + ':' + $Profile.port + '"'),
        ('peer_public_key = "' + $Profile.server_public_key + '"'),
        '[network_identity]', ('network_name = ' + $qRoom),
        '[secure_mode]', 'enabled = true',
        ('local_private_key = "' + $Profile.credential_secret + '"'),
        ('local_public_key = "' + $Profile.client_public_key + '"'),
        '[flags]', 'dev_name = "civ6mesh"', ('mtu = ' + [int]$Profile.mtu),
        'default_protocol = "udp"', 'enable_encryption = true', 'enable_ipv6 = true',
        'no_tun = false', 'enable_exit_node = false', 'accept_dns = false',
        'private_mode = true', 'latency_first = false', 'disable_p2p = false',
        'p2p_only = false', 'lazy_p2p = false', 'disable_relay_data = true',
        'disable_upnp = true', 'relay_network_whitelist = ""',
        'enable_udp_broadcast_relay = true',
        '[console_logger]', 'level = "off"'
    )
    # Civ6 LAN uses UDP. Do not expose TCP services such as file sharing or RDP.
    foreach ($chain in @(1,2)) {
        $lines += @('[[acl.acl_v1.chains]]', ('name = "civ6-udp-' + $chain + '"'),
            ('chain_type = ' + $chain), 'enabled = true', 'default_action = 2',
            '[[acl.acl_v1.chains.rules]]', 'name = "game-udp"', 'enabled = true',
            'priority = 1000', 'action = 1', 'protocol = 2',
            ('source_ips = [' + $qNetwork + ']'),
            ('destination_ips = [' + $qNetwork + ', "255.255.255.255/32", "224.0.0.0/4"]'),
            '[[acl.acl_v1.chains.rules]]', 'name = "mesh-ping"', 'enabled = true',
            'priority = 900', 'action = 1', 'protocol = 3',
            ('source_ips = [' + $qNetwork + ']'), ('destination_ips = [' + $qNetwork + ']'))
    }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-ConfigurationHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) }
    finally { $sha.Dispose() }
}

function Write-CoordinatorTrust {
    param([object]$Profile)
    # Public key only. Required by the core to authenticate a pinned bootstrap
    # peer before it has received the administrator's propagated trust list.
    $trusted = @{coordinator=@{
        pubkey=$Profile.server_public_key;secret='';groups=@();allow_relay=$true
        allowed_proxy_cidrs=@();reusable=$true;expiry_unix=[long]$Profile.expires_at
        created_at_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }}
    $json = $trusted | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $script:ManagedRoot 'trusted-server.json'), $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-NetworkFingerprint {
    $routes = @(Get-NetRoute -ErrorAction Stop | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1','::/0','::/1','8000::/1') } |
        ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.DestinationPrefix, $_.InterfaceIndex, $_.NextHop, $_.RouteMetric } | Sort-Object)
    $dns = @(Get-DnsClientServerAddress -ErrorAction Stop | Where-Object { $_.ServerAddresses.Count -gt 0 } |
        ForEach-Object { '{0}|{1}|{2}' -f $_.InterfaceIndex, $_.AddressFamily, ($_.ServerAddresses -join ',') } | Sort-Object)
    return Get-ConfigurationHash (($routes -join ';') + ';DNS;' + ($dns -join ';'))
}

function Assert-NoSubnetConflict {
    param([object]$Profile)
    $target = [Net.IPAddress]::Parse(($Profile.network -split '/')[0]).GetAddressBytes()
    foreach ($route in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)) {
        $parts = $route.DestinationPrefix.Split('/')
        if ($parts.Length -ne 2 -or [int]$parts[1] -eq 0) { continue }
        $other = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        $bits = [Math]::Min(24, [int]$parts[1])
        $overlap = $true
        for ($index=0; $index -lt 4; $index++) {
            $take = [Math]::Min(8, [Math]::Max(0, $bits - 8*$index))
            $mask = if ($take -eq 0) { 0 } else { (255 -shl (8-$take)) -band 255 }
            if (($target[$index] -band $mask) -ne ($other[$index] -band $mask)) { $overlap = $false; break }
        }
        if ($overlap) { throw '游戏虚拟网段与本机现有路由重叠。请让管理员更换游戏网段。' }
    }
}

function Install-Component {
    $source = Join-Path $script:PackageRoot 'bin'
    $manifest = Join-Path $source 'checksums.json'
    if (!(Test-Path -LiteralPath $manifest -PathType Leaf)) { throw '组件不完整，请完整解压 ZIP。' }
    $hashes = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    $target = Join-Path $script:ManagedRoot 'bin'
    $replace = @()
    foreach ($name in $script:ComponentFiles) {
        $path = Join-Path $source $name
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or !$hashes.PSObject.Properties[$name] -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hashes.$name) {
            throw '随包组件校验失败，请重新获取完整 ZIP。'
        }
        $installed = Join-Path $target $name
        if (!(Test-Path -LiteralPath $installed -PathType Leaf) -or
            (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ine $hashes.$name) {
            $replace += $name
        }
    }
    if ($replace.Count -gt 0) {
        if (Get-OwnRelayProcess) { throw '发现组件需要修复或升级，请先断开后再检查组件。' }
        Protect-ManagedDirectory
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        # An unchanged loaded driver must never be overwritten. If a driver
        # really needs replacement, try it before modifying executable files.
        foreach ($name in @($replace | Sort-Object { if ($_ -eq 'WinDivert64.sys') { 0 } else { 1 } })) {
            try { Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $target $name) -Force }
            catch [IO.IOException] { throw ('组件 ' + $name + ' 正被系统或其他程序使用，未能替换；请重启电脑后再检查组件。') }
        }
    }
    $installedManifest = Join-Path $target 'checksums.json'
    if (!(Test-Path -LiteralPath $installedManifest -PathType Leaf) -or
        [IO.File]::ReadAllText($manifest) -cne [IO.File]::ReadAllText($installedManifest)) {
        Protect-ManagedDirectory
        [IO.File]::WriteAllText($installedManifest,[IO.File]::ReadAllText($manifest),(New-Object Text.UTF8Encoding($false)))
    }
    if ($replace.Count -eq 0) { return '组件正常。' }
    return '组件修复完成。'
}

function Test-ComponentCurrent {
    $source = Join-Path $script:PackageRoot 'bin/checksums.json'
    $installed = Join-Path $script:ManagedRoot 'bin/checksums.json'
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw '组件不完整，请完整解压 ZIP。' }
    return ((Test-Path -LiteralPath $installed -PathType Leaf) -and
        [IO.File]::ReadAllText($source) -eq [IO.File]::ReadAllText($installed))
}

function Ensure-Component {
    if (!(Test-ComponentCurrent)) { Install-Component | Out-Null }
}

function Get-EnginePath {
    $root = Join-Path $script:ManagedRoot 'bin'
    foreach ($name in $script:ComponentFiles) {
        if (!(Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)) { throw '组件缺失，请点击“检查组件”。' }
    }
    return Join-Path $root 'easytier-core.exe'
}

function Get-RelayArguments {
    return '-c "' + $script:ManagedConfig + '" --disable-env-parsing --rpc-portal 127.0.0.1:' + $script:RpcPort
}

function Get-OwnRelayProcess {
    param([switch]$Fast)
    $path = Join-Path $script:ManagedRoot 'managed.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($saved.marker -ne 'civ6-relay/v3') { throw '本机管理标记不匹配。' }
    if (!$saved.PSObject.Properties['process_id']) { return $null }
    if ($saved.backend -ne 'easytier') { throw '组网组件归属不匹配。' }
    $owned = Get-Process -Id ([int]$saved.process_id) -ErrorAction SilentlyContinue
    if (!$owned -or $owned.HasExited -or $owned.StartTime.ToUniversalTime().Ticks -ne [long]$saved.start_ticks) { return $null }
    if ($Fast) { return $owned }
    $details = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$saved.process_id)
    $expected = '"' + $saved.image_path + '" ' + (Get-RelayArguments)
    if (!$details -or $details.CommandLine -cne $expected -or $owned.Path -ine $saved.image_path) {
        throw '无法确认组网进程归属，已停止操作。'
    }
    return $owned
}

function Initialize-RelayNative {
    if ('Civ6Relay.ConsoleEngine' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace Civ6Relay {
    public static class ConsoleEngine {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO {
            public int cb;
            public string lpReserved, lpDesktop, lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION {
            public IntPtr hProcess, hThread;
            public uint dwProcessId, dwThreadId;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processAttributes,
            IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory,
            ref STARTUPINFO startup, out PROCESS_INFORMATION process);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] private static extern bool FreeConsole();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint id);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GenerateConsoleCtrlEvent(uint kind, uint group);
        public static int Start(string image, string arguments, string credential) {
            var values = new System.Collections.Generic.SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables()) {
                string key = (string)entry.Key;
                if (!key.StartsWith("ET_", StringComparison.OrdinalIgnoreCase)) values[key] = (string)entry.Value;
            }
            // EasyTier's file loader normalizes an absent network secret to an empty secret.
            // This child-only environment option selects credential authentication explicitly.
            values["ET_CREDENTIAL"] = credential;
            StringBuilder block = new StringBuilder();
            foreach (var entry in values) block.Append(entry.Key).Append('=').Append(entry.Value).Append((char)0);
            block.Append((char)0);
            IntPtr environment = Marshal.StringToHGlobalUni(block.ToString());
            try {
                STARTUPINFO startup = new STARTUPINFO();
                startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                startup.dwFlags = 1;
                startup.wShowWindow = 0;
                PROCESS_INFORMATION process;
                if (!CreateProcessW(image, new StringBuilder(((char)34) + image + ((char)34) + " " + arguments), IntPtr.Zero,
                    IntPtr.Zero, false, 0x410, environment, null, ref startup, out process))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                try { return checked((int)process.dwProcessId); }
                finally { CloseHandle(process.hThread); CloseHandle(process.hProcess); }
            } finally { Marshal.FreeHGlobal(environment); }
        }
        public static void Interrupt(uint id) {
            // Called only by a separate short-lived helper, after ownership checks.
            FreeConsole();
            if (!AttachConsole(id)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!SetConsoleCtrlHandler(IntPtr.Zero, true)) throw new Win32Exception(Marshal.GetLastWin32Error());
            // Ctrl+C targets this isolated console, not arbitrary system processes.
            if (!GenerateConsoleCtrlEvent(0, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
}

function Start-RelayProcess {
    param([string]$Image, [string]$Credential)
    Initialize-RelayNative
    $nativeId = [Civ6Relay.ConsoleEngine]::Start($Image, (Get-RelayArguments), $Credential)
    return Get-Process -Id $nativeId -ErrorAction Stop
}

function Stop-RelayProcess {
    param([object]$Owned)
    if ($Owned.HasExited) { return }
    $library = (Join-Path $script:PackageRoot 'Civ6Relay.ps1').Replace("'", "''")
    $image = $Owned.Path.Replace("'", "''")
    $expected = ('"' + $Owned.Path + '" ' + (Get-RelayArguments)).Replace("'", "''")
    $ticks = $Owned.StartTime.ToUniversalTime().Ticks
    $helper = @"
`$ErrorActionPreference = 'Stop'
. '$library' -LibraryOnly
try {
    `$engine = Get-Process -Id $($Owned.Id) -ErrorAction SilentlyContinue
    if (!`$engine -or `$engine.HasExited -or `$engine.StartTime.ToUniversalTime().Ticks -ne [long]'$ticks') { exit 0 }
    `$details = Get-CimInstance Win32_Process -Filter 'ProcessId=$($Owned.Id)'
    if (`$engine.Path -ine '$image' -or !`$details -or `$details.CommandLine -cne '$expected') { exit 1 }
    Initialize-RelayNative
    [Civ6Relay.ConsoleEngine]::Interrupt([uint32]`$engine.Id)
    if (!`$engine.WaitForExit(5000)) { exit 1 }
    exit 0
} catch { exit 1 }
"@
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helper))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $signal = [Diagnostics.Process]::Start($info)
    try {
        if (!$signal.WaitForExit(12000) -or !$Owned.WaitForExit(1000)) {
            throw '中转组件未正常退出，已保留进程；请检查组件状态。'
        }
    } finally { $signal.Dispose() }
}


function ConvertFrom-MeshJson {
    param([string]$Text)
    try { $parsed = ConvertFrom-Json -InputObject $Text }
    catch { throw '状态组件返回的 JSON 无法解析，请检查组件。' }
    # Windows PowerShell 5.1 emits an entire JSON array as one pipeline object.
    # Explicit iteration gives both 5.1 and 7 the same per-route output.
    foreach ($row in $parsed) { Write-Output -InputObject $row }
}

function Invoke-MeshCli {
    param([string]$InstanceId, [ValidateSet('route','stats')][string]$Command = 'route')
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $script:ManagedRoot 'bin\easytier-cli.exe'
    $info.Arguments = '-p 127.0.0.1:' + $script:RpcPort + ' -i ' + $InstanceId + ' -o json ' + $Command
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    try { $process = [Diagnostics.Process]::Start($info) }
    catch { throw '无法启动状态查询组件，请点击“检查组件”；若正在连接，请先断开。' }
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(5000)) { $process.Kill(); throw '本机状态查询超过 5 秒，请断开后重新连接。' }
        if ($process.ExitCode -ne 0) {
            $detail = $stderr.Result
            if ($detail -match 'Instance not found|No instance matches') { throw '后台实例与本机记录不匹配，请断开后重新连接。' }
            if ($detail -match 'refused|timed out|failed to connect|os error 10061|os error 10060') { throw ('无法连接本机状态端口 ' + $script:RpcPort + '，后台接口尚未就绪。') }
            if ($detail -match 'unexpected argument|unrecognized|invalid value') { throw '状态查询组件版本不一致，请断开后点击“检查组件”。' }
            if ($process.ExitCode -in @(-1073741515,-1073741701,-1073741502)) { throw '状态组件的 DLL 无法加载，请断开后点击“检查组件”。' }
            throw ('状态查询组件退出，错误码 ' + $process.ExitCode + '。')
        }
        return ConvertFrom-MeshJson $stdout.Result
    } finally { $process.Dispose() }
}

function Convert-MeshRoutes {
    param([object[]]$Routes, [string]$OwnIP)
    $items = @()
    foreach ($route in $Routes) {
        if (!$route.PSObject.Properties['path_len'] -or !$route.PSObject.Properties['ipv4'] -or
            !$route.PSObject.Properties['hostname']) { throw '组网状态格式不匹配。' }
        $ip = ([string]$route.ipv4 -split '/')[0]
        if (!$ip -or $ip -eq $OwnIP -or [int]$route.path_len -eq 0) { continue }
        $mode = if ([int]$route.path_len -eq 1) { 'P2P 直连' } elseif ([int]$route.path_len -gt 1) { '服务器中继' } else { '路径未知' }
        $rtt = '待测'
        if ($route.PSObject.Properties['next_hop_lat'] -and [double]$route.next_hop_lat -gt 0) {
            $rtt = ([double]$route.next_hop_lat).ToString('0.0') + ' ms'
            if ([int]$route.path_len -gt 1) { $rtt = '到中继 ' + $rtt }
        }
        $name = [regex]::Replace([string]$route.hostname, '[\p{Cc}\p{Cf}]', '')
        if ($name.Length -gt 48) { $name = $name.Substring(0,48) }
        $items += [pscustomobject]@{Player=$name; VirtualIP=$ip; Channel=$mode; RTT=$rtt; Hops=[int]$route.path_len}
    }
    return $items
}

function Connect-Relay {
    $profile = Get-Profile
    $config = Get-ConnectionConfig $profile
    $hash = Get-ConfigurationHash $config
    $owned = Get-OwnRelayProcess
    if ($owned) {
        if (!(Test-ComponentCurrent)) { throw '组件版本已更新，请先断开旧客户端再连接。' }
        $saved = Get-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.config_hash -ne $hash) { throw '设置已改变，请先断开再连接。' }
        return '连接已启动。'
    }
    if (Get-Service -Name 'WireGuardTunnel$civ6relay' -ErrorAction SilentlyContinue) {
        throw '旧版整机隧道仍在运行，请先在旧客户端中断开。'
    }
    if (Get-Process -Name 'wiresock-client' -ErrorAction SilentlyContinue) {
        throw '检测到旧版进程代理，请先断开旧版客户端。'
    }
    Assert-NoSubnetConflict $profile
    $probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $script:RpcPort)
    try { $probe.Start() } catch { throw '本地组网管理端口已被其他程序占用。' } finally { $probe.Stop() }
    Ensure-Component
    $image = Get-EnginePath
    $baseline = Get-NetworkFingerprint
    Protect-ManagedDirectory
    [IO.File]::WriteAllText($script:ManagedConfig, $config, (New-Object Text.UTF8Encoding($false)))
    Write-CoordinatorTrust $profile
    $metadata = @{marker='civ6-relay/v3';backend='easytier';player=$profile.player;instance_id=$profile.instance_id;
        client_ip=$profile.client_ip;network=$profile.network;config_hash=$hash;image_path=$image;network_fingerprint=$baseline}
    $owned = Start-RelayProcess -Image $image -Credential $profile.credential_secret
    try {
        $metadata.process_id = $owned.Id
        $metadata.start_ticks = $owned.StartTime.ToUniversalTime().Ticks.ToString()
        $metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Encoding UTF8
        if ($owned.WaitForExit(1000)) { throw '组网组件未启动成功，请检查驱动、安全软件提示或网络冲突。' }
        if ((Get-NetworkFingerprint) -ne $baseline) { throw '默认路由或 DNS 发生变化，已中止本次连接。' }
    } catch {
        if (!$owned.HasExited) { Stop-RelayProcess $owned }
        throw
    }
    return '正在连接…'
}

function Disconnect-Relay {
    $owned = Get-OwnRelayProcess
    if ($owned) { Stop-RelayProcess $owned }
    $path = Join-Path $script:ManagedRoot 'managed.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @('process_id','start_ticks')) { $saved.PSObject.Properties.Remove($name) }
        $saved | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    }
    return '已断开虚拟局域网。'
}

function ConvertTo-MeshSnapshot {
    param([object[]]$Routes, [string]$OwnIP)
    $ownRows = @($Routes | Where-Object { $_.path_len -eq 0 -and $_.ipv4 })
    if ($ownRows.Count -gt 0) { $OwnIP = ([string]$ownRows[0].ipv4 -split '/')[0] }
    $peers = @(Convert-MeshRoutes $Routes $OwnIP)
    $direct = @($peers | Where-Object {$_.Hops -eq 1}).Count
    $relayed = @($peers | Where-Object {$_.Hops -gt 1}).Count
    $coordinator = @($Routes | Where-Object {$_.hostname -eq 'Civ6Coordinator' -and $_.path_len -gt 0}).Count
    $ipText = if ($OwnIP) { $OwnIP } else { '分配中' }
    $text = if ($coordinator -gt 0) { '已接入服务器；虚拟 IP：' + $ipText } else { '等待服务器认证；虚拟 IP：' + $ipText }
    if ($peers.Count -gt 0) { $text += '；直连 ' + $direct + ' 人，中继 ' + $relayed + ' 人。' }
    else { $text += '；尚未发现其他玩家。' }
    return [pscustomobject]@{Text=$text;Peers=$peers;OwnIP=$OwnIP}
}

function Get-MeshSnapshot {
    if (!(Get-OwnRelayProcess -Fast)) { return [pscustomobject]@{Text='未连接'; Peers=@()} }
    $saved = Get-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    try {
        $routes = @(Invoke-MeshCli -InstanceId $saved.instance_id -Command 'route')
        return ConvertTo-MeshSnapshot -Routes $routes -OwnIP ([string]$saved.client_ip)
    } catch {
        return [pscustomobject]@{Text=('后台仍在运行；状态读取失败：' + $_.Exception.Message);Peers=@()}
    }
}

function Get-RelayStatus {
    return (Get-MeshSnapshot).Text
}

function Get-LanBroadcastDiagnostics {
    param([string]$InstanceId)
    try {
        $metrics = @(Invoke-MeshCli -InstanceId $InstanceId -Command 'stats')
        $names = @('captured','ignored','forwarded','forward_failed')
        $counts = @{}
        foreach ($metric in $metrics) {
            if (!$metric.PSObject.Properties['name'] -or !$metric.PSObject.Properties['value']) { continue }
            foreach ($name in $names) {
                if ($metric.name -ceq ('udp_broadcast_relay_packets_' + $name)) {
                    if (!$counts.ContainsKey($name)) { $counts[$name] = [decimal]0 }
                    $counts[$name] += [decimal]$metric.value
                }
            }
        }
        if ($counts.Count -ne 4) {
            '广播统计：暂无数据。'
        } else {
            ('广播统计（全部应用）：捕获 {0}；忽略 {1}；转发提交 {2}；失败 {3}。' -f $counts.captured,$counts.ignored,$counts.forwarded,$counts.forward_failed)
        }
    } catch { '广播统计：读取失败。' }
}

function Get-Civ6WindowsDiagnostics {
    param([string]$Network)
    $games = @()
    try {
        $games = @(Get-Process -Name 'CivilizationVI','CivilizationVI_DX12' -ErrorAction SilentlyContinue)
        if ($games.Count -eq 0) { '未检测到文明6进程；请保持游戏开着再诊断。' }
        else {
            $gameIds = @($games | ForEach-Object { $_.Id })
            $endpoints = @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $_.OwningProcess -in $gameIds })
            if ($endpoints.Count -eq 0) { '文明6 UDP 监听：暂无数据。' }
            foreach ($endpoint in $endpoints) {
                $game = @($games | Where-Object { $_.Id -eq $endpoint.OwningProcess })[0]
                '文明6监听：' + $game.ProcessName + '；PID ' + $game.Id + '；' + $endpoint.LocalAddress + ':' + $endpoint.LocalPort
            }
        }
    } catch { '文明6监听信息读取失败；请在管理员模式保持游戏运行后重试。' }
    try {
        $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
        foreach ($item in $profiles) {
            '防火墙 ' + $item.Name + '：启用 ' + $item.Enabled + '；允许入站规则 ' + $item.AllowInboundRules + '；允许本地规则 ' + $item.AllowLocalFirewallRules
        }
    } catch { 'Windows 有效防火墙策略读取失败。' }
    try {
        $filters = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -ErrorAction Stop |
            Where-Object { ([regex]::Replace([string]$_.Program, '^.*[\\/]', '')) -match '^CivilizationVI(?:_DX12)?\.exe$' })
        $count = 0
        foreach ($filter in $filters) {
            $executable = [regex]::Replace([string]$filter.Program, '^.*[\\/]', '')
            $rules = @(Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $filter -PolicyStore ActiveStore -TracePolicyStore -ErrorAction Stop |
                Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' })
            foreach ($rule in $rules) {
                $count++
                '文明6入站：' + $executable + '；' + $rule.Action + '；配置 ' + $rule.Profile + '；来源 ' + $rule.PolicyStoreSourceType
            }
        }
        if ($count -eq 0) { '文明6入站规则：未找到程序专用规则。' }
    } catch { '文明6入站规则：读取失败。' }
}

function Test-Relay {
    try { $profile = Get-Profile }
    catch { throw '无法读取客户端配置，请检查设置或重新解压客户端。' }
    try { $snapshot = Get-MeshSnapshot }
    catch { $snapshot = [pscustomobject]@{Text='玩家连接状态：读取失败。';Peers=@()} }
    $lines = @(('版本：3.3.0；时间：' + [DateTimeOffset]::Now.ToString('o')), $snapshot.Text,
        ('游戏虚拟网段：' + $profile.network))
    foreach ($peer in $snapshot.Peers) {
        $lines += $peer.Player + ' | ' + $peer.VirtualIP + ' | ' + $peer.Channel + ' | ' + $peer.RTT
    }
    $path = Join-Path $script:ManagedRoot 'managed.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            try {
                if ((Get-NetworkFingerprint) -eq $saved.network_fingerprint) {
                    $lines += '默认上网路由和 DNS 与连接前一致。'
                } else { $lines += '默认上网路由或 DNS 与连接前不同，请检查系统网络设置。' }
            } catch { $lines += '默认路由和 DNS：读取失败。' }
            if (Get-OwnRelayProcess -Fast) { $lines += @(Get-LanBroadcastDiagnostics -InstanceId $saved.instance_id) }
        } catch { $lines += '本机连接记录：读取失败。' }
    }
    $lines += @(Get-Civ6WindowsDiagnostics -Network $profile.network)
    return $lines -join [Environment]::NewLine
}

function Remove-Relay {
    Disconnect-Relay | Out-Null
    if (Test-Path -LiteralPath $script:ManagedRoot) {
        Protect-ManagedDirectory
        Remove-Item -LiteralPath $script:ManagedRoot -Recurse -Force
    }
    return '本工具的本机配置和组件文件已移除。'
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $PSCommandPath,$Action
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait
        exit
    }
}

function Initialize-LiveMonitor {
    if ('Civ6Relay.Live.RoutePoller' -as [type]) { return }
    try { Add-Type -TypeDefinition ([IO.File]::ReadAllText($script:LiveSourcePath)) -Language CSharp -ErrorAction Stop }
    catch { throw '实时监测组件无法加载，请完整解压新版客户端。' }
}

function Add-LiveLog {
    param([string]$Text)
    foreach ($line in @($Text -split '\r?\n')) {
        $safe = [regex]::Replace($line, '[\p{Cc}\p{Cf}]', ' ').Trim()
        if (!$safe) { continue }
        if ($safe -match '(?i)(credential_secret|local_private_key|private_key|network_secret)\s*["'':=]') {
            $safe = '敏感信息已隐藏。'
        }
        $safe = [regex]::Replace($safe, '(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])', '[已隐藏]')
        if ($safe.Length -gt 2000) { $safe = $safe.Substring(0,2000) + '…' }
        if ($script:LiveMessages.Count -ge 1000) { $null = $script:LiveMessages.Dequeue(); $script:LiveLogDropped++ }
        $script:LiveMessages.Enqueue(([DateTimeOffset]::Now.ToString('HH:mm:ss.fff') + '  ' + $safe))
        $script:LiveLogTotal++
    }
}

function Get-LiveLog {
    $batch = New-Object 'Collections.Generic.List[string]'
    while ($script:LiveMessages.Count -gt 0 -and $batch.Count -lt 200) { $batch.Add($script:LiveMessages.Dequeue()) }
    return [pscustomobject]@{Text=($batch -join [Environment]::NewLine);
        Status=('日志 ' + $script:LiveLogTotal + ' 条' + $(if ($script:LiveLogDropped -gt 0) { '；已省略 ' + $script:LiveLogDropped + ' 条' } else { '' }))}
}

function Start-LiveMonitor {
    if ($null -ne $script:LiveRuntime) { return }
    Initialize-LiveMonitor
    $script:LiveRuntime = @{
        RouteWorker=(New-Object Civ6Relay.Live.RoutePoller); PingWorker=(New-Object Civ6Relay.Live.LatencyMonitor)
        Session=''; Generation=0L; RoutePeers=@(); BaseText='未连接'; Connected=$false
        LastGood=[DateTimeOffset]::MinValue; LastError=''; Paths=@{}; OwnIP=''
    }
    Add-LiveLog '延迟监测已启动。'
}

function Stop-LiveMonitor {
    if ($null -eq $script:LiveRuntime) { return }
    $runtime=$script:LiveRuntime
    $script:LiveRuntime=$null
    try { $runtime.RouteWorker.Dispose() } finally { $runtime.PingWorker.Dispose() }
}

function Get-LiveView {
    $state=$script:LiveRuntime
    if ($null -eq $state) { return [pscustomobject]@{Text='实时监测尚未启动';Peers=@()} }
    try {
        $owned=Get-OwnRelayProcess -Fast
        if (!$owned) {
            if ($state.Connected) { Add-LiveLog '连接进程已退出。' }
            if ($state.Session) { $state.RouteWorker.Stop();$state.PingWorker.Stop() }
            $state.Session='';$state.Connected=$false;$state.RoutePeers=@();$state.Paths=@{};$state.LastError=''
            return [pscustomobject]@{Text='未连接';Peers=@()}
        }
        $saved=Get-Content -LiteralPath (Join-Path $script:ManagedRoot 'managed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $id=([Guid]$saved.instance_id).ToString()
        $session=$id+'|'+$owned.Id+'|'+$owned.StartTime.ToUniversalTime().Ticks
        if ($state.Session -ne $session) {
            $state.RouteWorker.Stop();$state.PingWorker.Stop()
            $state.Generation=0L;$state.RoutePeers=@();$state.Paths=@{};$state.LastError='';$state.OwnIP=''
            $state.LastGood=[DateTimeOffset]::MinValue;$state.BaseText='正在读取组网状态…'
            $state.RouteWorker.Start((Join-Path $script:ManagedRoot 'bin/easytier-cli.exe'),$id,$script:RpcPort)
            $state.PingWorker.SetPeers([string[]]@());$state.PingWorker.Start()
            $state.Session=$session;$state.Connected=$true
            Add-LiveLog '正在获取玩家列表。'
        }
        $sample=$state.RouteWorker.ReadLatest()
        if ($sample.Generation -gt $state.Generation -and $sample.SampleTime -ne [DateTimeOffset]::MinValue) {
            $state.Generation=$sample.Generation
            if ($sample.ExitCode -eq 0 -and !$sample.Error) {
                try {
                    $routes=@(ConvertFrom-MeshJson $sample.Stdout)
                    $snapshot=ConvertTo-MeshSnapshot -Routes $routes -OwnIP ([string]$saved.client_ip)
                    $state.BaseText=$snapshot.Text;$state.RoutePeers=@($snapshot.Peers);$state.OwnIP=$snapshot.OwnIP
                    $state.LastGood=$sample.SampleTime;$state.LastError=''
                    $paths=@{}
                    foreach ($peer in $state.RoutePeers) {
                        $key=$peer.VirtualIP;$value=$peer.Player+' | '+$peer.Channel
                        $paths[$key]=$value
                        if (!$state.Paths.ContainsKey($key)) { Add-LiveLog ('发现玩家：'+$peer.Player+' | '+$key+' | '+$peer.Channel) }
                        elseif ($state.Paths[$key] -ne $value) { Add-LiveLog ('玩家路径变化：'+$peer.Player+' | '+$key+' | '+$peer.Channel) }
                    }
                    foreach ($key in @($state.Paths.Keys)) { if (!$paths.ContainsKey($key)) { Add-LiveLog ('玩家路由已不可见：'+$key) } }
                    $state.Paths=$paths
                    # Probe only players in the same game /24; never use an advertised public address as a ping target.
                    $prefix=if ($snapshot.OwnIP -match '^(\d+\.\d+\.\d+)\.\d+$') { $Matches[1]+'.' } else { '' }
                    $targets=@($state.RoutePeers | Where-Object { $prefix -and $_.VirtualIP.StartsWith($prefix) } | ForEach-Object { $_.VirtualIP })
                    $state.PingWorker.SetPeers([string[]]$targets)
                } catch {
                    $state.BaseText='后台仍在运行；玩家状态格式无法读取。'
                    if ($state.LastError -ne $state.BaseText) { Add-LiveLog $state.BaseText;$state.LastError=$state.BaseText }
                }
            } else {
                $message='后台状态查询失败：'+$sample.Error
                if (!$sample.Error) { $message='后台状态查询失败，错误码 '+$sample.ExitCode+'。' }
                $state.BaseText=$message
                if ($state.LastError -ne $message) { Add-LiveLog $message;$state.LastError=$message }
            }
        }
        $latencies=@{}
        foreach ($ping in @($state.PingWorker.ReadLatest())) { $latencies[$ping.IP]=$ping }
        $peers=@()
        $now=[DateTimeOffset]::Now
        $stale=($now-$state.LastGood).TotalSeconds -gt 4
        foreach ($peer in $state.RoutePeers) {
            $rtt='等待采样';$when='—'
            if ($latencies.ContainsKey($peer.VirtualIP)) {
                $ping=$latencies[$peer.VirtualIP]
                if ($ping.Time -ne [DateTimeOffset]::MinValue) { $when=$ping.Time.ToLocalTime().ToString('HH:mm:ss') }
                $rtt=switch ($ping.Status) {
                    'success' { if (($now-$ping.Time).TotalSeconds -gt 4) { '采样已过期' } else { ([string]$ping.RttMs)+' ms' } }
                    'timeout' { '无回应（ICMP）' }
                    'unreachable' { 'ICMP 不可达' }
                    'error' { '采样失败' }
                    'stopped' { '已停止' }
                    default { '等待采样' }
                }
            }
            $peers += [pscustomobject]@{Player=$peer.Player;VirtualIP=$peer.VirtualIP;
                Channel=$(if ($stale) { '路径状态已过期' } else { $peer.Channel });
                LinkRTT=$(if ($stale) { '已过期' } else { $peer.RTT });RTT=$rtt;SampleTime=$when}
        }
        return [pscustomobject]@{Text=$state.BaseText;Peers=$peers}
    } catch {
        if ($state.Session) { $state.RouteWorker.Stop();$state.PingWorker.Stop() }
        $state.Session='';$state.Connected=$false;$state.RoutePeers=@();$state.Paths=@{}
        $message='实时监测无法读取本机连接记录，请断开后重新连接。'
        if ($state.LastError -ne $message) { Add-LiveLog $message;$state.LastError=$message }
        return [pscustomobject]@{Text=$message;Peers=@()}
    }
}

function Show-RelayWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ('Civ6Relay.Ui.Dpi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Civ6Relay.Ui {
    public static class Dpi {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
        public static void Enable() {
            bool enabled = false;
            try { enabled = SetProcessDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
            if (!enabled) {
                try { SetProcessDPIAware(); }
                catch (EntryPointNotFoundException) { }
                catch (DllNotFoundException) { }
            }
            try { SetThreadDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
        }
    }
}
'@
    }
    [Civ6Relay.Ui.Dpi]::Enable()
    [Windows.Forms.Application]::EnableVisualStyles()
    $palette=@{
        Canvas=[Drawing.ColorTranslator]::FromHtml('#F2F5FA')
        White=[Drawing.Color]::White
        Text=[Drawing.ColorTranslator]::FromHtml('#172B4D')
        Muted=[Drawing.ColorTranslator]::FromHtml('#64748B')
        Blue=[Drawing.ColorTranslator]::FromHtml('#2563EB')
        BlueHover=[Drawing.ColorTranslator]::FromHtml('#1D4ED8')
        BlueSoft=[Drawing.ColorTranslator]::FromHtml('#EAF1FF')
        Border=[Drawing.ColorTranslator]::FromHtml('#DFE6F0')
        Surface=[Drawing.ColorTranslator]::FromHtml('#F7F9FC')
        Green=[Drawing.ColorTranslator]::FromHtml('#137C66')
        GreenSoft=[Drawing.ColorTranslator]::FromHtml('#EAF7F2')
        Amber=[Drawing.ColorTranslator]::FromHtml('#9A6716')
        Red=[Drawing.ColorTranslator]::FromHtml('#C24145')
    }
    $fontBase=New-Object Drawing.Font('Segoe UI',10)
    $fontTitle=New-Object Drawing.Font('Microsoft YaHei UI',18,[Drawing.FontStyle]::Bold)
    $fontStrong=New-Object Drawing.Font('Microsoft YaHei UI',10,[Drawing.FontStyle]::Bold)
    $fontSmall=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $fontInput=New-Object Drawing.Font('Segoe UI',11)
    $fontMono=New-Object Drawing.Font('Consolas',9.5)
    $form=New-Object Windows.Forms.Form
    $form.Text='文明6联机助手';$form.Font=$fontBase
    $form.ForeColor=$palette.Text;$form.BackColor=$palette.Canvas
    $form.AutoScaleDimensions=New-Object Drawing.SizeF(96,96)
    $form.AutoScaleMode='Dpi'
    $form.ClientSize=New-Object Drawing.Size(984,740)
    $form.MinimumSize=New-Object Drawing.Size(900,660)
    $form.StartPosition='CenterScreen'
    $windowIcon=$null
    try {
        $launcherPath=Join-Path $script:PackageRoot 'Civ6Relay.exe'
        if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
            $windowIcon=[Drawing.Icon]::ExtractAssociatedIcon($launcherPath)
            $form.Icon=$windowIcon
        }
    } catch { }
    $tips=New-Object Windows.Forms.ToolTip
    $tips.AutoPopDelay=6000;$tips.InitialDelay=450;$tips.ReshowDelay=200
    $form.SuspendLayout()
    $canvas=New-Object Windows.Forms.Panel
    $canvas.Dock='Fill';$canvas.AutoScroll=$true;$canvas.BackColor=$palette.Canvas
    $form.Controls.Add($canvas)
    $layout=New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock='Top';$layout.ColumnCount=1;$layout.RowCount=4
    $layout.Padding=New-Object Windows.Forms.Padding(22,18,22,14)
    $layout.Margin=New-Object Windows.Forms.Padding(0)
    $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,72))) | Out-Null
    $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,148))) | Out-Null
    $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $canvas.Controls.Add($layout)

    $header=New-Object Windows.Forms.TableLayoutPanel
    $header.Dock='Fill';$header.AutoSize=$false;$header.Height=60;$header.ColumnCount=1;$header.RowCount=2
    $header.Margin=New-Object Windows.Forms.Padding(0,0,0,12)
    $header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $header.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,38))) | Out-Null
    $header.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $title=New-Object Windows.Forms.Label
    $title.Text='文明6联机助手';$title.Font=$fontTitle;$title.AutoSize=$true;$title.Dock='Fill'
    $title.Margin=New-Object Windows.Forms.Padding(0,0,0,4)
    $header.Controls.Add($title,0,0)
    $notice=New-Object Windows.Forms.Label
    $notice.AutoSize=$true;$notice.Dock='Fill';$notice.ForeColor=$palette.Muted;$notice.Font=$fontSmall
    $notice.Margin=New-Object Windows.Forms.Padding(0)
    $notice.Text='文明6：多人游戏 → 局域网'
    $header.Controls.Add($notice,0,1)
    $layout.Controls.Add($header,0,0)

    $connectionCard=New-Object Windows.Forms.TableLayoutPanel
    $connectionCard.Dock='Fill';$connectionCard.AutoSize=$false;$connectionCard.Height=136
    $connectionCard.BackColor=$palette.White;$connectionCard.Padding=New-Object Windows.Forms.Padding(18,16,18,12)
    $connectionCard.Margin=New-Object Windows.Forms.Padding(0,0,0,12)
    $connectionCard.ColumnCount=1;$connectionCard.RowCount=2
    $connectionCard.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $connectionCard.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,64))) | Out-Null
    $connectionCard.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,44))) | Out-Null
    $layout.Controls.Add($connectionCard,0,1)
    $preferences=Get-ClientPreferences
    $fields=New-Object Windows.Forms.TableLayoutPanel
    $fields.Dock='Fill';$fields.AutoSize=$false;$fields.Height=54
    $fields.ColumnCount=3;$fields.RowCount=2;$fields.GrowStyle='FixedSize'
    $fields.Margin=New-Object Windows.Forms.Padding(0,0,0,10)
    foreach ($weight in @(36,46,18)) {
        $fields.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,$weight))) | Out-Null
    }
    $fields.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,24))) | Out-Null
    $fields.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    foreach ($item in @(@('玩家昵称',0),@('服务器 IP',1),@('端口',2))) {
        $label=New-Object Windows.Forms.Label
        $label.Text=$item[0];$label.AutoSize=$true;$label.Dock='Fill'
        $label.Font=$fontSmall;$label.ForeColor=$palette.Muted
        $label.Margin=New-Object Windows.Forms.Padding(0,0,12,7)
        $fields.Controls.Add($label,[int]$item[1],0)
    }
    $nameInput=New-Object Windows.Forms.TextBox
    $nameInput.Text=$preferences.display_name;$nameInput.MaxLength=24;$nameInput.TabIndex=0
    $serverInput=New-Object Windows.Forms.TextBox
    $serverInput.Text=$preferences.endpoint;$serverInput.MaxLength=15;$serverInput.TabIndex=1
    $portInput=New-Object Windows.Forms.TextBox
    $portInput.Text=[string]$preferences.port;$portInput.MaxLength=5;$portInput.TabIndex=2
    $fieldInputs=@($nameInput,$serverInput,$portInput)
    for ($index=0;$index -lt $fieldInputs.Count;$index++) {
        $fieldInput=$fieldInputs[$index]
        $fieldInput.Dock='Fill';$fieldInput.Font=$fontInput;$fieldInput.BorderStyle='FixedSingle'
        $fieldInput.BackColor=$palette.White;$fieldInput.ForeColor=$palette.Text
        $rightMargin=if ($index -eq 2) {0} else {16}
        $fieldInput.Margin=New-Object Windows.Forms.Padding(0,0,$rightMargin,0)
        $fields.Controls.Add($fieldInput,$index,1)
    }
    $tips.SetToolTip($serverInput,'填写服务器的 IPv4 地址。')
    $connectionCard.Controls.Add($fields,0,0)
    $actionLayout=New-Object Windows.Forms.TableLayoutPanel
    $actionLayout.Dock='Fill';$actionLayout.AutoSize=$false;$actionLayout.Height=44;$actionLayout.ColumnCount=2;$actionLayout.RowCount=1
    $actionLayout.Margin=New-Object Windows.Forms.Padding(0)
    $actionLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,138))) | Out-Null
    $actionLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $actionLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $connectionCard.Controls.Add($actionLayout,0,1)
    $actions=New-Object Windows.Forms.FlowLayoutPanel
    $actions.Dock='Fill';$actions.AutoSize=$false;$actions.Height=44;$actions.WrapContents=$false
    $actions.FlowDirection='LeftToRight';$actions.Margin=New-Object Windows.Forms.Padding(12,0,0,0)
    $actionLayout.Controls.Add($actions,1,0)

    $tabs=New-Object Windows.Forms.TabControl
    $tabs.Dock='Fill';$tabs.Margin=New-Object Windows.Forms.Padding(0,0,0,12)
    $tabs.DrawMode='OwnerDrawFixed';$tabs.SizeMode='Fixed';$tabs.ItemSize=New-Object Drawing.Size(132,40)
    $tabs.Font=$fontStrong
    $tabs.Add_DrawItem({
        param($sender,$eventArgs)
        $selected=($sender.SelectedIndex -eq $eventArgs.Index)
        $background=if ($selected) {$palette.White} else {$palette.Canvas}
        $foreground=if ($selected) {$palette.Blue} else {$palette.Muted}
        $brush=New-Object Drawing.SolidBrush($background)
        try { $eventArgs.Graphics.FillRectangle($brush,$eventArgs.Bounds) } finally { $brush.Dispose() }
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,$sender.TabPages[$eventArgs.Index].Text,
            $sender.Font,$eventArgs.Bounds,$foreground,([Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
        if ($selected) {
            $accent=New-Object Drawing.SolidBrush($palette.Blue)
            try { $eventArgs.Graphics.FillRectangle($accent,$eventArgs.Bounds.Left+18,$eventArgs.Bounds.Bottom-3,[Math]::Max(0,$eventArgs.Bounds.Width-36),3) }
            finally { $accent.Dispose() }
        }
    })
    $statePage=New-Object Windows.Forms.TabPage
    $statePage.Text='网络状态';$statePage.Padding=New-Object Windows.Forms.Padding(16)
    $statePage.BackColor=$palette.White
    $eventsPage=New-Object Windows.Forms.TabPage
    $eventsPage.Text='运行日志';$eventsPage.Padding=New-Object Windows.Forms.Padding(16)
    $eventsPage.BackColor=$palette.White
    $tabs.TabPages.Add($statePage);$tabs.TabPages.Add($eventsPage)
    $layout.Controls.Add($tabs,0,2)
    $stateLayout=New-Object Windows.Forms.TableLayoutPanel
    $stateLayout.Dock='Fill';$stateLayout.ColumnCount=1;$stateLayout.RowCount=4
    $stateLayout.Margin=New-Object Windows.Forms.Padding(0)
    $stateLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $stateLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $stateLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $stateLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $stateLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $statePage.Controls.Add($stateLayout)
    $status=New-Object Windows.Forms.Label
    $status.AutoSize=$true;$status.Dock='Fill';$status.Text='正在读取状态…'
    $status.Font=$fontStrong;$status.ForeColor=$palette.Text;$status.BackColor=$palette.BlueSoft
    $status.Padding=New-Object Windows.Forms.Padding(12,10,12,10)
    $status.Margin=New-Object Windows.Forms.Padding(0,0,0,12)
    $stateLayout.Controls.Add($status,0,0)
    $grid=New-Object Windows.Forms.DataGridView
    $grid.Dock='Fill';$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false
    $grid.AllowUserToResizeRows=$false;$grid.RowHeadersVisible=$false
    $grid.AutoSizeColumnsMode='Fill';$grid.AutoSizeRowsMode='AllCells'
    $grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false
    $grid.BorderStyle='None';$grid.CellBorderStyle='SingleHorizontal';$grid.GridColor=$palette.Border
    $grid.BackgroundColor=$palette.White;$grid.EnableHeadersVisualStyles=$false
    $grid.ColumnHeadersBorderStyle='None';$grid.ColumnHeadersHeightSizeMode='AutoSize'
    $grid.ColumnHeadersDefaultCellStyle.BackColor=$palette.Surface
    $grid.ColumnHeadersDefaultCellStyle.ForeColor=$palette.Muted
    $grid.ColumnHeadersDefaultCellStyle.Font=$fontSmall
    $grid.ColumnHeadersDefaultCellStyle.Padding=New-Object Windows.Forms.Padding(10,10,10,10)
    $grid.DefaultCellStyle.BackColor=$palette.White;$grid.DefaultCellStyle.ForeColor=$palette.Text
    $grid.DefaultCellStyle.Font=$fontBase;$grid.DefaultCellStyle.Padding=New-Object Windows.Forms.Padding(10,8,10,8)
    $grid.DefaultCellStyle.SelectionBackColor=$palette.BlueSoft;$grid.DefaultCellStyle.SelectionForeColor=$palette.Text
    $grid.AlternatingRowsDefaultCellStyle.BackColor=$palette.Surface
    $grid.Margin=New-Object Windows.Forms.Padding(0,0,0,9)
    foreach ($column in @(@('Player','玩家',17,96),@('VirtualIP','虚拟 IP',17,110),@('Channel','实际路径',19,130),
        @('RTT','延迟（Ping）',18,124),@('LinkRTT','链路延迟',17,110),@('SampleTime','采样时间',12,86))) {
        $columnIndex=$grid.Columns.Add($column[0],$column[1])
        $grid.Columns[$columnIndex].FillWeight=[single]$column[2]
        $grid.Columns[$columnIndex].MinimumWidth=[int]$column[3]
        $grid.Columns[$columnIndex].SortMode='NotSortable'
    }
    $grid.Columns['VirtualIP'].DefaultCellStyle.Font=$fontMono
    $grid.Columns['SampleTime'].DefaultCellStyle.Font=$fontMono
    $grid.Columns['SampleTime'].DefaultCellStyle.ForeColor=$palette.Muted
    $grid.Columns['RTT'].HeaderCell.ToolTipText='对玩家虚拟 IP 的 Ping 往返延迟。'
    $grid.Columns['LinkRTT'].HeaderCell.ToolTipText='中继时为到中继节点的延迟。'
    $stateLayout.Controls.Add($grid,0,1)
    $latencyNote=New-Object Windows.Forms.Label
    $latencyNote.AutoSize=$true;$latencyNote.Dock='Fill';$latencyNote.Font=$fontSmall;$latencyNote.ForeColor=$palette.Muted
    $latencyNote.Margin=New-Object Windows.Forms.Padding(0)
    $latencyNote.Text='中继时，链路延迟只到中继节点。'
    $stateLayout.Controls.Add($latencyNote,0,2)
    $operationPanel=New-Object Windows.Forms.TableLayoutPanel
    $operationPanel.Dock='Fill';$operationPanel.ColumnCount=1;$operationPanel.RowCount=2
    $operationPanel.Height=104;$operationPanel.MinimumSize=New-Object Drawing.Size(0,104)
    $operationPanel.Margin=New-Object Windows.Forms.Padding(0,12,0,0)
    $operationPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $operationPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $operationPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $resultLabel=New-Object Windows.Forms.Label
    $resultLabel.AutoSize=$true;$resultLabel.Text='操作结果';$resultLabel.Font=$fontSmall;$resultLabel.ForeColor=$palette.Muted
    $resultLabel.Margin=New-Object Windows.Forms.Padding(0,0,0,6)
    $operationPanel.Controls.Add($resultLabel,0,0)
    $result=New-Object Windows.Forms.TextBox
    $result.Dock='Fill';$result.Multiline=$true;$result.ReadOnly=$true;$result.ScrollBars='Vertical'
    $result.BorderStyle='None';$result.BackColor=$palette.Surface;$result.ForeColor=$palette.Text
    $result.Font=$fontSmall;$result.Margin=New-Object Windows.Forms.Padding(0)
    $result.Text=''
    $operationPanel.Controls.Add($result,0,1)
    $stateLayout.Controls.Add($operationPanel,0,3);$operationPanel.Visible=$false

    $eventLayout=New-Object Windows.Forms.TableLayoutPanel
    $eventLayout.Dock='Fill';$eventLayout.ColumnCount=1;$eventLayout.RowCount=4
    $eventLayout.Margin=New-Object Windows.Forms.Padding(0)
    $eventLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $eventLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $eventLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $eventLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
    $eventLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $eventsPage.Controls.Add($eventLayout)
    $eventActions=New-Object Windows.Forms.FlowLayoutPanel
    $eventActions.Dock='Fill';$eventActions.AutoSize=$true;$eventActions.AutoSizeMode='GrowAndShrink';$eventActions.WrapContents=$true
    $eventActions.Margin=New-Object Windows.Forms.Padding(0,0,0,10)
    $eventLayout.Controls.Add($eventActions,0,0)
    $eventStatus=New-Object Windows.Forms.Label
    $eventStatus.AutoSize=$true;$eventStatus.Dock='Fill';$eventStatus.Text=''
    $eventStatus.Font=$fontSmall;$eventStatus.ForeColor=$palette.Muted
    $eventStatus.Margin=New-Object Windows.Forms.Padding(0,0,0,8)
    $eventLayout.Controls.Add($eventStatus,0,1)
    $runningLog=New-Object Windows.Forms.RichTextBox
    $runningLog.Dock='Fill';$runningLog.ReadOnly=$true;$runningLog.WordWrap=$false;$runningLog.DetectUrls=$false
    $runningLog.Font=$fontMono;$runningLog.ForeColor=$palette.Text;$runningLog.BackColor=$palette.Surface
    $runningLog.BorderStyle='None';$runningLog.ScrollBars='Both';$runningLog.HideSelection=$false
    $runningLog.Margin=New-Object Windows.Forms.Padding(0,0,0,8)
    $eventLayout.Controls.Add($runningLog,0,2)
    $eventFeedback=New-Object Windows.Forms.Label
    $eventFeedback.AutoSize=$true;$eventFeedback.Dock='Fill';$eventFeedback.Text=''
    $eventFeedback.Font=$fontSmall;$eventFeedback.ForeColor=$palette.Muted
    $eventFeedback.Margin=New-Object Windows.Forms.Padding(0)
    $eventLayout.Controls.Add($eventFeedback,0,3)
    $autoDisconnect=New-Object Windows.Forms.CheckBox
    $autoDisconnect.AutoSize=$true;$autoDisconnect.Text='关闭窗口时自动断开';$autoDisconnect.Checked=$true
    $autoDisconnect.Font=$fontSmall;$autoDisconnect.ForeColor=$palette.Muted
    $autoDisconnect.Margin=New-Object Windows.Forms.Padding(0)
    $layout.Controls.Add($autoDisconnect,0,3)
    $buttons=New-Object Collections.ArrayList
    $newButton={
        param([string]$Caption,[bool]$Primary=$false)
        $control=New-Object Windows.Forms.Button
        $control.Text=$Caption;$control.AutoSize=$true;$control.FlatStyle='Flat'
        $control.Font=$fontSmall;$control.Cursor=[Windows.Forms.Cursors]::Hand
        $control.MinimumSize=New-Object Drawing.Size(100,36)
        $control.Padding=New-Object Windows.Forms.Padding(10,6,10,6)
        $control.Margin=New-Object Windows.Forms.Padding(0,0,8,0)
        $control.UseVisualStyleBackColor=$false
        $control.FlatAppearance.BorderSize=1;$control.FlatAppearance.BorderColor=$palette.Border
        $control.BackColor=$palette.White;$control.ForeColor=$palette.Text
        $control.FlatAppearance.MouseOverBackColor=$palette.Surface
        $control.FlatAppearance.MouseDownBackColor=$palette.BlueSoft
        if ($Primary) {
            $control.Font=$fontStrong;$control.MinimumSize=New-Object Drawing.Size(138,36)
            $control.BackColor=$palette.Blue;$control.ForeColor=$palette.White
            $control.FlatAppearance.BorderSize=0;$control.FlatAppearance.MouseOverBackColor=$palette.BlueHover
            $control.FlatAppearance.MouseDownBackColor=$palette.BlueHover
            $control.Margin=New-Object Windows.Forms.Padding(0)
        }
        return $control
    }
    $setBusyControls={
        foreach ($control in $buttons) { $control.Enabled=!$script:Busy }
        $fields.Enabled=!$script:Busy
    }
    $uiState=[pscustomobject]@{LastViewError=''}
    $refresh={
        try {
            $snapshot=Get-LiveView
            $status.Text=[string]$snapshot.Text;$status.ForeColor=$palette.Text
            $peers=@($snapshot.Peers)
            $firstVisibleRow=if ($grid.FirstDisplayedScrollingRowIndex -ge 0) {
                $grid.Rows[$grid.FirstDisplayedScrollingRowIndex]
            } else { $null }
            $rowsByIP=@{}
            foreach ($row in $grid.Rows) { $rowsByIP[[string]$row.Cells['VirtualIP'].Value]=$row }
            $grid.SuspendLayout()
            try {
                foreach ($peer in $peers) {
                    $key=[string]$peer.VirtualIP
                    if ($rowsByIP.ContainsKey($key)) {
                        $row=$rowsByIP[$key];$rowsByIP.Remove($key)
                    } else {
                        $rowIndex=$grid.Rows.Add()
                        $row=$grid.Rows[$rowIndex]
                        $row.Cells['Channel'].Style.Font=$fontStrong
                        $row.Cells['RTT'].Style.Font=$fontStrong
                    }
                    $values=@($peer.Player,$peer.VirtualIP,$peer.Channel,$peer.RTT,$peer.LinkRTT,$peer.SampleTime)
                    for ($cellIndex=0;$cellIndex -lt $values.Count;$cellIndex++) {
                        $value=[string]$values[$cellIndex]
                        if ([string]$row.Cells[$cellIndex].Value -ne $value) { $row.Cells[$cellIndex].Value=$value }
                    }
                    $pathCell=$row.Cells['Channel']
                    $pathBackground=$palette.Surface;$pathForeground=$palette.Muted
                    if ($peer.Channel -eq 'P2P 直连') {
                        $pathBackground=$palette.GreenSoft;$pathForeground=$palette.Green
                    } elseif ($peer.Channel -eq '服务器中继') {
                        $pathBackground=$palette.BlueSoft;$pathForeground=$palette.Blue
                    }
                    if ($pathCell.Style.BackColor -ne $pathBackground) { $pathCell.Style.BackColor=$pathBackground }
                    if ($pathCell.Style.ForeColor -ne $pathForeground) { $pathCell.Style.ForeColor=$pathForeground }
                    $pingCell=$row.Cells['RTT']
                    $pingForeground=if ([string]$peer.RTT -match '^\d+(\.\d+)? ms$') { $palette.Blue } else { $palette.Muted }
                    if ($pingCell.Style.ForeColor -ne $pingForeground) { $pingCell.Style.ForeColor=$pingForeground }
                }
                foreach ($row in $rowsByIP.Values) { $grid.Rows.Remove($row) }
                if ($null -ne $firstVisibleRow -and $firstVisibleRow.Index -ge 0) {
                    $grid.FirstDisplayedScrollingRowIndex=$firstVisibleRow.Index
                }
            } finally { $grid.ResumeLayout() }
            $uiState.LastViewError=''
        } catch {
            $status.Text='状态暂不可用。';$status.ForeColor=$palette.Red
            $message=$_.Exception.Message
            if ($uiState.LastViewError -ne $message) {
                $uiState.LastViewError=$message
                Add-LiveLog ('实时状态读取失败：'+$message)
            }
        }
    }
    $autoScroll=New-Object Windows.Forms.CheckBox
    $autoScroll.AutoSize=$true;$autoScroll.Text='自动滚动';$autoScroll.Checked=$true
    $autoScroll.Font=$fontSmall;$autoScroll.ForeColor=$palette.Muted
    $autoScroll.Margin=New-Object Windows.Forms.Padding(8,9,0,0)
    $appendLog={
        param([string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return }
        $selectionStart=$runningLog.SelectionStart;$selectionLength=$runningLog.SelectionLength
        $runningLog.AppendText($Text.TrimEnd([char[]]@([char]13,[char]10))+[Environment]::NewLine)
        if ($runningLog.TextLength -gt 160000) {
            $removeCount=$runningLog.TextLength-120000
            $newline=$runningLog.Text.IndexOf([char]10,$removeCount)
            if ($newline -ge 0) { $removeCount=$newline+1 }
            $runningLog.Select(0,$removeCount);$runningLog.SelectedText=''
            $selectionStart=[Math]::Max(0,$selectionStart-$removeCount)
        }
        if ($autoScroll.Checked) {
            $runningLog.SelectionStart=$runningLog.TextLength;$runningLog.SelectionLength=0;$runningLog.ScrollToCaret()
        } else {
            $selectionStart=[Math]::Min($selectionStart,$runningLog.TextLength)
            $selectionLength=[Math]::Min($selectionLength,$runningLog.TextLength-$selectionStart)
            $runningLog.Select($selectionStart,$selectionLength)
        }
    }
    $refreshLog={
        try {
            $batch=Get-LiveLog
            & $appendLog ([string]$batch.Text)
            $eventStatus.Text=[string]$batch.Status
        } catch { $eventStatus.Text='日志暂不可用。' }
    }
    $captions=@('连接','断开','网络诊断','检查组件','保存设置')
    for ($index=0;$index -lt $captions.Count;$index++) {
        $button=& $newButton $captions[$index] ($index -eq 0);$button.Tag=$index
        $button.Add_Click({
            param($sender,$eventArgs)
            if ($script:Busy) { return }
            $script:Busy=$true;& $setBusyControls
            $tabs.SelectedTab=$statePage;$operationPanel.Visible=$true
            $result.ForeColor=$palette.Text;$result.Text='正在处理…'
            Add-LiveLog ('开始：'+$sender.Text)
            [Windows.Forms.Application]::DoEvents()
            try {
                if ([int]$sender.Tag -in @(0,4)) {
                    $saved=Save-ClientPreferences $nameInput.Text $serverInput.Text $portInput.Text
                    $form.Text='文明6联机助手 · '+$saved.display_name
                }
                $operationOutput=switch ([int]$sender.Tag) {
                    0 { Connect-Relay }
                    1 { Disconnect-Relay }
                    2 { Test-Relay }
                    3 { Install-Component }
                    4 { '设置已保存，重新连接后生效。' }
                }
                $result.Text=[string]$operationOutput
                Add-LiveLog ($sender.Text+'：'+$result.Text)
                if ([int]$sender.Tag -in @(0,1)) {
                    try { Start-LiveMonitor }
                    catch {
                        $monitorError='状态监测未启动。'
                        $result.AppendText([Environment]::NewLine+$monitorError)
                        Add-LiveLog $monitorError
                    }
                }
            } catch {
                $result.ForeColor=$palette.Red;$result.Text=$_.Exception.Message
                Add-LiveLog ($sender.Text+'失败：'+$result.Text)
            } finally {
                $script:Busy=$false;& $setBusyControls
                & $refresh;& $refreshLog
            }
        })
        if ($index -eq 0) { $actionLayout.Controls.Add($button,0,0) }
        else { $actions.Controls.Add($button) }
        $buttons.Add($button) | Out-Null
    }
    $copyButton=& $newButton '复制日志'
    $copyButton.Add_Click({
        if ($script:Busy) { return }
        try {
            $text=if ($runningLog.SelectionLength -gt 0) { $runningLog.SelectedText } else { $runningLog.Text }
            if ([string]::IsNullOrEmpty($text)) { $eventFeedback.Text='日志为空。';return }
            [Windows.Forms.Clipboard]::SetText($text)
            $eventFeedback.Text='已复制。'
        } catch { $eventFeedback.Text='复制失败。' }
    })
    $eventActions.Controls.Add($copyButton);$buttons.Add($copyButton) | Out-Null
    $exportButton=& $newButton '导出日志'
    $exportButton.Add_Click({
        if ($script:Busy) { return }
        $script:Busy=$true;& $setBusyControls
        $dialog=New-Object Windows.Forms.SaveFileDialog
        try {
            $dialog.Filter='文本日志 (*.log)|*.log|文本文件 (*.txt)|*.txt'
            $dialog.DefaultExt='log';$dialog.AddExtension=$true;$dialog.OverwritePrompt=$true
            $dialog.FileName='civ6-relay-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'.log'
            if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
                [IO.File]::WriteAllText($dialog.FileName,$runningLog.Text,(New-Object Text.UTF8Encoding($true)))
                $eventFeedback.Text='已导出。'
            }
        } catch { $eventFeedback.Text='导出失败。' }
        finally { $dialog.Dispose();$script:Busy=$false;& $setBusyControls }
    })
    $eventActions.Controls.Add($exportButton);$buttons.Add($exportButton) | Out-Null
    $clearButton=& $newButton '清空显示'
    $clearButton.Add_Click({
        if ($script:Busy) { return }
        $runningLog.Clear();$eventFeedback.Text='已清空。'
    })
    $eventActions.Controls.Add($clearButton);$buttons.Add($clearButton) | Out-Null
    $eventActions.Controls.Add($autoScroll)
    $timer=New-Object Windows.Forms.Timer
    $timer.Interval=1000
    $timer.Add_Tick({ if (!$script:Busy) { & $refresh } })
    $logTimer=New-Object Windows.Forms.Timer
    $logTimer.Interval=250
    $logTimer.Add_Tick({ if (!$script:Busy) { & $refreshLog } })
    $fitContent={
        if (!$form.IsHandleCreated) { return }
        $graphics=$form.CreateGraphics()
        try { $minimumContentHeight=[int][Math]::Ceiling(700*$graphics.DpiY/96) }
        finally { $graphics.Dispose() }
        $canvas.AutoScrollMinSize=New-Object Drawing.Size(0,$minimumContentHeight)
        $contentHeight=[Math]::Max($canvas.ClientSize.Height,$minimumContentHeight)
        if ($layout.Height -ne $contentHeight) { $layout.Height=$contentHeight }
    }
    $canvas.Add_SizeChanged({ & $fitContent })
    $form.Add_Load({
        $workArea=[Windows.Forms.Screen]::FromControl($form).WorkingArea
        $maximumWidth=[Math]::Max(1,$workArea.Width-24)
        $maximumHeight=[Math]::Max(1,$workArea.Height-24)
        $form.MinimumSize=New-Object Drawing.Size(
            ([Math]::Min($form.MinimumSize.Width,$maximumWidth)),
            ([Math]::Min($form.MinimumSize.Height,$maximumHeight)))
        $form.Size=New-Object Drawing.Size(
            ([Math]::Min($form.Width,$maximumWidth)),
            ([Math]::Min($form.Height,$maximumHeight)))
        $form.Location=New-Object Drawing.Point(
            ($workArea.Left+[int](($workArea.Width-$form.Width)/2)),
            ($workArea.Top+[int](($workArea.Height-$form.Height)/2)))
        & $fitContent
    })
    $form.Add_Shown({
        try { Start-LiveMonitor;& $refresh;& $refreshLog }
        catch {
            $status.Text='状态监测未启动。';$status.ForeColor=$palette.Red
            Add-LiveLog $status.Text
        }
        $timer.Start();$logTimer.Start()
    })
    $form.Add_FormClosing({
        param($sender,$eventArgs)
        if ($script:Busy) { $eventArgs.Cancel=$true;return }
        if ($autoDisconnect.Checked) {
            try { $message=Disconnect-Relay;Add-LiveLog ('关闭窗口：'+$message) }
            catch {
                $eventArgs.Cancel=$true;$operationPanel.Visible=$true
                $result.ForeColor=$palette.Red;$result.Text=$_.Exception.Message;$tabs.SelectedTab=$statePage;return
            }
        }
        $timer.Stop();$logTimer.Stop()
    })
    $form.ResumeLayout($true)
    try { [Windows.Forms.Application]::Run($form) }
    finally {
        $timer.Stop();$logTimer.Stop();$timer.Dispose();$logTimer.Dispose()
        try { Stop-LiveMonitor } catch { }
        $form.Dispose();$tips.Dispose()
        if ($null -ne $windowIcon) { $windowIcon.Dispose() }
        foreach ($font in @($fontBase,$fontTitle,$fontStrong,$fontSmall,$fontInput,$fontMono)) { $font.Dispose() }
    }
}

if ($LibraryOnly) { return }
try {
    if ($env:OS -ne 'Windows_NT') { throw '此客户端适用于 Windows 10/11 x64。' }
    Assert-Administrator
    switch ($Action) {
        'Gui' { Show-RelayWindow }
        'Connect' { Connect-Relay }
        'Disconnect' { Disconnect-Relay }
        'Status' { Get-RelayStatus }
        'Diagnose' { Test-Relay }
        'Install' { Install-Component }
        'Remove' { Remove-Relay }
    }
} catch {
    if ($Action -eq 'Gui') {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,'文明6联机助手') | Out-Null
    } else { Write-Error $_.Exception.Message }
    exit 1
}
