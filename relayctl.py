#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Private Civ6 LAN mesh: direct peers first, authenticated relay fallback.

Python 3.6+. EasyTier owns encryption, NAT traversal and mesh routing.
The relay has no TUN, subnet proxy, exit node, IP forwarding or NAT rules.
"""
import argparse
import base64
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile

VERSION = '1.0.0'
MARKER = 'civ6-relay/v3'
BACKEND = 'easytier'
ENGINE_VERSION = '2.6.4-civ6.2'
SERVICE = 'civ6-relay.service'
DEFAULT_NETWORK = '10.77.77.0/24'
RPC_PORT = 15887

class RelayError(Exception):
    pass

class Runner:
    def run(self, argv, data=None, check=True):
        try:
            result = subprocess.run(list(map(str, argv)), input=data,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                encoding='utf-8', errors='replace', timeout=20)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            raise RelayError('命令缺失或超时：' + Path(str(argv[0])).name) from None
        if check and result.returncode:
            # Core/CLI diagnostics may contain credentials, so report only the operation name.
            raise RelayError('命令失败：' + Path(str(argv[0])).name + '；请检查服务状态。')
        return result

class Paths:
    def __init__(self, root=Path('/')):
        self.root = Path(root)
        self.state_dir = self.at('/etc/civ6-relay')
        self.state = self.state_dir / 'state.json'
        self.clients = self.state_dir / 'clients'
        self.exports = self.state_dir / 'exports'
        self.config = self.state_dir / 'server.toml'
        self.credentials = self.state_dir / 'credentials.json'
        self.unit = self.at('/etc/systemd/system/' + SERVICE)
        self.program = self.at('/opt/civ6-relay')
        self.lock = self.at('/run/civ6-relay.lock')
    def at(self, name):
        return self.root / name.lstrip('/')

def unlink(path):
    try:
        path.unlink()
    except FileNotFoundError:
        pass

def private_dir(path):
    if path.is_symlink():
        raise RelayError('配置目录不能是符号链接。')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)

def atomic_write(path, content, mode=0o600):
    if path.is_symlink():
        raise RelayError('配置文件不能是符号链接。')
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, str(path))
    finally:
        unlink(Path(name))

def valid_key(value):
    try:
        if len(base64.b64decode(value, validate=True)) == 32:
            return value
    except (ValueError, TypeError, base64.binascii.Error):
        pass
    raise RelayError('凭据密钥格式无效。')

def client_name(value):
    if not re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_-]{0,23}', value):
        raise RelayError('凭据编号须以英文字母开头，仅含字母、数字、_、-，最多 24 字符。')
    return value

def public_ipv4(value):
    try:
        addr = ipaddress.IPv4Address(value)
    except ValueError:
        raise RelayError('请输入公网 IPv4，不要附加协议或端口。') from None
    if not addr.is_global or addr.is_multicast:
        raise RelayError('服务端地址必须是公网 IPv4。')
    return str(addr)

def settings(endpoint, network=DEFAULT_NETWORK, port=51820, mtu=1360):
    endpoint = public_ipv4(endpoint)
    try:
        net = ipaddress.IPv4Network(network, strict=True)
    except ValueError:
        raise RelayError('虚拟网络必须是对齐的 RFC1918 /24 网段。') from None
    private = [ipaddress.ip_network(x) for x in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
    if net.prefixlen != 24 or not any(net.network_address in x and net.broadcast_address in x for x in private):
        raise RelayError('虚拟网络必须是 RFC1918 /24，不能使用默认路由或公网段。')
    if not 1024 <= int(port) <= 65535 or int(port) == RPC_PORT:
        raise RelayError('服务器端口须为 1024–65535，且不能占用本地管理端口。')
    if not 1280 <= int(mtu) <= 1400:
        raise RelayError('MTU 须为 1280–1400。')
    return {'marker': MARKER, 'version': VERSION, 'backend': BACKEND,
            'routing_mode': 'lan-mesh', 'endpoint': endpoint, 'network': str(net),
            'port': int(port), 'mtu': int(mtu), 'clients': {}, 'firewall_owned': []}

def next_address(state):
    occupied = {entry['ip'] for entry in state['clients'].values()}
    net = ipaddress.ip_network(state['network'])
    for offset in range(2, 255):
        address = str(net.network_address + offset)
        if address not in occupied:
            return address
    raise RelayError('虚拟地址池已用完；地址池大小不代表服务器承载人数。')

def toml_string(value):
    return json.dumps(value, ensure_ascii=False)

def server_config(state):
    """No virtual IP on relay: peers cannot use it to access host services."""
    lines = [
        '# Managed by ' + MARKER,
        'instance_id = ' + toml_string(state['instance_id']),
        'instance_name = "civ6-relay"',
        'hostname = "Civ6Coordinator"',
        'listeners = ' + json.dumps(['udp://0.0.0.0:' + str(state['port']),
                                    'tcp://0.0.0.0:' + str(state['port'])]),
        'credential_file = ' + toml_string('/etc/civ6-relay/credentials.json'),
        'exit_nodes = []', 'routes = []', 'proxy_network = []',
        'stun_servers = []', 'stun_servers_v6 = []',
        '[network_identity]', 'network_name = ' + toml_string(state['network_name']),
        'network_secret = ' + toml_string(state['network_secret']),
        '[secure_mode]', 'enabled = true',
        'local_private_key = ' + toml_string(state['private_key']),
        'local_public_key = ' + toml_string(state['public_key']),
        '[flags]', 'no_tun = true', 'enable_exit_node = false', 'accept_dns = false',
        'enable_encryption = true', 'private_mode = true', 'bind_device = false',
        'latency_first = false', 'p2p_only = false', 'disable_p2p = false',
        'disable_upnp = true', 'relay_all_peer_rpc = false',
        'relay_network_whitelist = ' + toml_string(state['network_name']),
        '[console_logger]', 'level = "off"', '']
    return '\n'.join(lines)

def client_profile(state, name, credential):
    return {'schema': 3, 'version': VERSION, 'backend': BACKEND, 'routing_mode': 'lan-mesh',
            'engine_version': ENGINE_VERSION, 'player': name,
            'instance_id': str(uuid.uuid4()), 'network_name': state['network_name'],
            'network': state['network'], 'client_ip': state['clients'][name]['ip'],
            'mtu': state['mtu'], 'server_public_key': state['public_key'],
            'credential_id': credential['credential_id'],
            'credential_secret': valid_key(credential['credential_secret']),
            'client_public_key': valid_key(credential['client_public_key']),
            'expires_at': state['clients'][name]['expires_at']}

def unit_config():
    return '''# Managed by civ6-relay/v3
[Unit]
Description=Civ6 private LAN discovery and fallback relay
Wants=network-online.target
After=network-online.target firewalld.service
Requires=firewalld.service
BindsTo=firewalld.service

[Service]
Type=simple
Environment=PYTHONIOENCODING=utf-8
WorkingDirectory=/etc/civ6-relay
ExecStartPre=/usr/bin/python3 /opt/civ6-relay/relayctl.py service-prepare
ExecStart=/opt/civ6-relay/bin/easytier-core -c /etc/civ6-relay/server.toml --disable-env-parsing --rpc-portal 127.0.0.1:15887
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
KillSignal=SIGINT
UMask=0077
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65536
# The core prints its effective config at startup; keep secrets out of the journal.
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
'''

class Relay:
    def __init__(self, paths=None, runner=None):
        self.p = paths or Paths()
        self.r = runner or Runner()
    def cmd(self, *args, **kwargs):
        return self.r.run(args, **kwargs)
    def load(self):
        if not self.p.state.is_file() or self.p.state.is_symlink():
            raise RelayError('尚未初始化。')
        state = json.loads(self.p.state.read_text(encoding='utf-8'))
        if state.get('marker') != MARKER or state.get('routing_mode') != 'lan-mesh':
            raise RelayError('发现旧版或非本工具配置；请先检查并卸载旧服务，不会自动转换整机代理。')
        return state
    def save(self, state):
        atomic_write(self.p.state, json.dumps(state, indent=2, ensure_ascii=False) + '\n')
    def cli(self, state, *args):
        result = self.cmd(str(self.p.program / 'bin/easytier-cli'), '-p',
            '127.0.0.1:' + str(RPC_PORT), '-i', state['instance_id'], '-o', 'json', *args)
        try:
            return json.loads(result.stdout)
        except (ValueError, TypeError):
            raise RelayError('组网组件返回了无法识别的数据。') from None
    def preflight(self, state):
        if self.cmd('firewall-cmd', '--state', check=False).returncode:
            raise RelayError('需要保持 firewalld 运行；不会停用现有防护。')
        route = self.cmd('ip', '-4', 'route', 'get', '1.1.1.1').stdout
        match = re.search(r'\bdev\s+(\S+)', route)
        if not match:
            raise RelayError('无法确定公网网卡。')
        zone = self.cmd('firewall-cmd', '--get-zone-of-interface=' + match.group(1), check=False).stdout.strip()
        if not zone or zone == 'no zone':
            zone = self.cmd('firewall-cmd', '--get-default-zone').stdout.strip()
        if not re.fullmatch(r'[a-zA-Z0-9_-]+', zone):
            raise RelayError('无法确定防火墙区域。')
        state['wan_zone'] = zone
        for protocol in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
            with socket.socket(socket.AF_INET, protocol) as probe:
                try:
                    probe.bind(('0.0.0.0', state['port']))
                except OSError:
                    raise RelayError('服务器端口已占用。') from None
        with socket.socket() as probe:
            try:
                probe.bind(('127.0.0.1', RPC_PORT))
            except OSError:
                raise RelayError('本地组网管理端口已占用。') from None
    def firewall(self, state, action, port, permanent):
        args = ['firewall-cmd'] + (['--permanent'] if permanent else [])
        return self.r.run(args + ['--zone=' + state['wan_zone'], '--' + action + '-port=' + port], check=False)
    def setup_firewall(self, state):
        for protocol in ('udp', 'tcp'):
            port = str(state['port']) + '/' + protocol
            for permanent in (True, False):
                query = self.firewall(state, 'query', port, permanent)
                if query.returncode == 0:
                    continue
                if query.returncode != 1:
                    raise RelayError('无法查询防火墙端口。')
                # Record before mutation, so interrupted installation remains recoverable.
                state['firewall_owned'].append({'port': port, 'permanent': permanent})
                self.save(state)
                if self.firewall(state, 'add', port, permanent).returncode:
                    raise RelayError('添加本工具端口失败。')
    def service_prepare(self, state):
        if self.cmd('firewall-cmd', '--state', check=False).returncode:
            raise RelayError('防火墙未运行。')
        for protocol in ('udp', 'tcp'):
            if self.firewall(state, 'query', str(state['port']) + '/' + protocol, False).returncode:
                raise RelayError('组网监听端口没有放行。')
    def init(self, state, names):
        if self.p.state_dir.exists():
            raise RelayError('已有配置目录；不会重置密钥。')
        self.preflight(state)
        private_dir(self.p.state_dir)
        private_dir(self.p.clients)
        private_dir(self.p.exports)
        state.update(instance_id=str(uuid.uuid4()), network_name='civ6-' + secrets.token_hex(8),
                     network_secret=secrets.token_urlsafe(32), phase='installing')
        wg = str(self.p.program / 'bin/wg')
        state['private_key'] = valid_key(self.cmd(wg, 'genkey').stdout.strip())
        state['public_key'] = valid_key(self.cmd(wg, 'pubkey', data=state['private_key'] + '\n').stdout.strip())
        self.save(state)
        atomic_write(self.p.config, server_config(state))
        atomic_write(self.p.unit, unit_config(), 0o644)
        try:
            self.setup_firewall(state)
            self.cmd('systemctl', 'daemon-reload')
            self.cmd('systemctl', 'enable', '--now', SERVICE)
            for attempt in range(30):
                try:
                    self.cli(state, 'node', 'info')
                    break
                except RelayError:
                    if attempt == 29:
                        raise
                    time.sleep(0.3)
            state['phase'] = 'ready'
            self.save(state)
            for name in names:
                self.add(name)
            self.common_profile()
        except Exception:
            # Keep recoverable state if rollback itself fails.
            self.uninstall(state=state, rollback=True)
            raise
        print('虚拟局域网协调及中继服务已启动。游戏请选择“局域网”。')
    def add(self, name, ttl_days=365):
        name = client_name(name)
        state = self.load()
        if state.get('phase') != 'ready':
            raise RelayError('服务尚未就绪。')
        if name in state['clients']:
            raise RelayError('该玩家凭据编号已存在。')
        if not 1 <= int(ttl_days) <= 3650:
            raise RelayError('有效期须为 1–3650 天。')
        credential_id = str(uuid.uuid4())
        created = self.cli(state, 'credential', 'generate', '--ttl', str(int(ttl_days) * 86400),
                           '--credential-id', credential_id, '--reusable', 'false')
        try:
            if created.get('credential_id') != credential_id:
                raise RelayError('凭据编号不匹配。')
            valid_key(created.get('credential_secret'))
            created['client_public_key'] = valid_key(self.cmd(str(self.p.program / 'bin/wg'),
                'pubkey', data=created['credential_secret'] + '\n').stdout.strip())
            state['clients'][name] = {'ip': next_address(state), 'credential_id': credential_id,
                                     'expires_at': int(time.time()) + int(ttl_days) * 86400}
            profile = client_profile(state, name, created)
            atomic_write(self.p.clients / (name + '.json'), json.dumps(profile, ensure_ascii=False, indent=2) + '\n')
            self.save(state)
        except Exception:
            self.cli(state, 'credential', 'revoke', credential_id)
            unlink(self.p.clients / (name + '.json'))
            raise
        print('已创建独立玩家凭据：' + name)
        return profile
    def revoke(self, name):
        state = self.load()
        name = client_name(name)
        if name not in state['clients']:
            raise RelayError('玩家不存在。')
        self.cli(state, 'credential', 'revoke', state['clients'][name]['credential_id'])
        del state['clients'][name]
        self.save(state)
        unlink(self.p.clients / (name + '.json'))
        unlink(self.p.exports / (name + '.zip'))
        print('凭据已撤销；组网组件向在线节点同步撤销，其他玩家无需更换密钥。')
    def common_profile(self):
        state = self.load()
        path = self.p.state_dir / 'common-profile.json'
        if path.is_file():
            profile = json.loads(path.read_text(encoding='utf-8'))
            if profile.get('schema') != 4 or profile.get('access_mode') != 'shared':
                raise RelayError('通用客户端配置格式不匹配。')
            if profile['expires_at'] <= int(time.time()):
                raise RelayError('通用接入信息已过期。')
            profile.update(version=VERSION, engine_version=ENGINE_VERSION)
            return profile
        credential_id = str(uuid.uuid4())
        created = self.cli(state, 'credential', 'generate', '--ttl', str(3650 * 86400),
                           '--credential-id', credential_id, '--reusable', 'true')
        try:
            secret = valid_key(created['credential_secret'])
            pub = valid_key(self.cmd(str(self.p.program / 'bin/wg'), 'pubkey', data=secret+'\n').stdout.strip())
            profile = dict(schema=4, version=VERSION, backend=BACKEND, routing_mode='lan-mesh',
                           engine_version=ENGINE_VERSION, access_mode='shared', network_name=state['network_name'],
                           network=state['network'], mtu=state['mtu'], server_public_key=state['public_key'],
                           credential_id=credential_id, credential_secret=secret, client_public_key=pub,
                           expires_at=int(time.time())+3650*86400)
            atomic_write(path, json.dumps(profile, ensure_ascii=False, indent=2)+'\n')
        except Exception:
            self.cli(state, 'credential', 'revoke', credential_id)
            raise
        return profile
    def bundle(self, name=None, output=None):
        if name is None:
            profile = self.common_profile()
            destination = Path(output) if output else self.p.exports / 'windows.zip'
        else:
            state = self.load()
            name = client_name(name)
            if name not in state['clients']:
                raise RelayError('玩家不存在。')
            profile = json.loads((self.p.clients / (name + '.json')).read_text(encoding='utf-8'))
            if profile.get('backend') != BACKEND or profile.get('schema') != 3:
                raise RelayError('拒绝打包旧版代理配置。')
            profile.update(version=VERSION, engine_version=ENGINE_VERSION)
            destination = Path(output) if output else self.p.exports / (name + '.zip')
        if destination.is_symlink() or destination.exists():
            raise RelayError('导出文件已存在；请选择新的输出文件名。')
        fd = os.open(str(destination), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            # The installer compresses shared binaries once. Each export copies
            # that cache and appends only a small personal profile.
            with os.fdopen(fd, 'wb') as output_file:
                with (self.p.program / 'client/windows-template.zip').open('rb') as template:
                    shutil.copyfileobj(template, output_file, 1024 * 1024)
            with zipfile.ZipFile(str(destination), 'a', zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('profile.json', json.dumps(profile, indent=2, ensure_ascii=False) + '\n')
        except Exception:
            unlink(destination)
            raise
        print(str(destination))
        return destination
    def status(self):
        state = self.load()
        active = self.cmd('systemctl', 'is-active', SERVICE, check=False).stdout.strip()
        print('服务：' + active + '；模式：P2P 优先，失败经服务器中继；虚拟网段：' + state['network'])
        print('客户端：所有玩家共用同一个通用 ZIP，虚拟地址自动分配。')
        if active == 'active':
            for route in self.cli(state, 'route'):
                if route.get('ipv4') and route.get('path_len', 0) > 0:
                    print('{} {} 已接入'.format(route.get('hostname', ''), route['ipv4']))
        print('玩家互连路径请在各自客户端查看；服务器自身的连接不能代表玩家互连路径。')
    def uninstall(self, state=None, rollback=False):
        state = state or self.load()
        if state.get('marker') != MARKER:
            raise RelayError('拒绝卸载非本版本服务。')
        self.cmd('systemctl', 'disable', '--now', SERVICE, check=False)
        if self.cmd('systemctl', 'is-active', SERVICE, check=False).stdout.strip() == 'active':
            raise RelayError('服务未停止，已保留配置。')
        while state['firewall_owned']:
            owned = state['firewall_owned'][-1]
            query = self.firewall(state, 'query', owned['port'], owned['permanent'])
            if query.returncode not in (0, 1):
                raise RelayError('无法查询防火墙，保留状态以便重试。')
            if query.returncode == 0 and self.firewall(state, 'remove', owned['port'], owned['permanent']).returncode:
                raise RelayError('无法移除本工具端口，保留状态。')
            state['firewall_owned'].pop()
            self.save(state)
        unlink(self.p.unit)
        self.cmd('systemctl', 'daemon-reload')
        shutil.rmtree(str(self.p.state_dir))
        if not rollback:
            print('组网服务、玩家凭据及本工具新增端口已移除；其他安全服务和规则保留。')

def parser():
    main = argparse.ArgumentParser(description='文明6虚拟局域网：P2P 优先，中继兜底')
    main.add_argument('--version', action='version', version=VERSION)
    commands = main.add_subparsers(dest='command')
    for name in ('init', 'plan'):
        sub = commands.add_parser(name)
        sub.add_argument('--endpoint', required=True)
        sub.add_argument('--port', type=int, default=51820)
        sub.add_argument('--network', default=DEFAULT_NETWORK)
        sub.add_argument('--mtu', type=int, default=1360)
        sub.add_argument('--client', action='append')
    for name in ('add-client', 'revoke', 'bundle'):
        sub = commands.add_parser(name)
        sub.add_argument('name', **({'nargs': '?'} if name == 'bundle' else {}))
        if name == 'bundle':
            sub.add_argument('--output')
        if name == 'add-client':
            sub.add_argument('--ttl-days', type=int, default=365)
    for name in ('status', 'service-prepare', 'uninstall'):
        commands.add_parser(name)
    return main

def main(argv=None):
    ap = parser()
    args = ap.parse_args(argv)
    if not args.command:
        ap.error('需要指定命令')
    os.umask(0o077)
    if args.command in ('init', 'plan'):
        state = settings(args.endpoint, args.network, args.port, args.mtu)
        names = [client_name(n) for n in (args.client or [])]
        if len(names) != len(set(names)):
            raise RelayError('凭据编号不能重复。')
    if args.command == 'plan':
        print('模式：文明6局域网；P2P 优先，无法直连时由私有服务器中继。')
        print('监听 TCP/UDP 同一端口；客户端仅添加虚拟网段路由：' + state['network'])
        print('服务器不建 TUN、不设默认路由、不改 DNS、不启用出口转发。')
        print('客户端只填写昵称、服务器 IP 和端口；游戏 IP 自动分配，所有玩家共用同一个 ZIP。')
        return 0
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise RelayError('此管理命令须在 Linux 服务器上以 root/sudo 执行。')
    relay = Relay()
    if args.command == 'service-prepare':
        relay.service_prepare(relay.load())
        return 0
    with open(str(relay.p.lock), 'a') as lock:
        os.chmod(str(relay.p.lock), 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RelayError('另一个管理命令正在运行。') from None
        if args.command == 'init':
            relay.init(state, names)
        elif args.command == 'add-client':
            relay.add(args.name, args.ttl_days)
        elif args.command == 'revoke':
            relay.revoke(args.name)
        elif args.command == 'bundle':
            relay.bundle(args.name, args.output)
        elif args.command == 'status':
            relay.status()
        elif args.command == 'uninstall':
            relay.uninstall()
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RelayError, ValueError, OSError, KeyError) as error:
        print('错误：' + (str(error) if isinstance(error, RelayError) else '配置或系统操作失败；未输出含密钥的详细信息。'), file=sys.stderr)
        sys.exit(1)
