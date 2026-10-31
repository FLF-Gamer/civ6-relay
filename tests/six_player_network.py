#!/usr/bin/env python3
"""Six real mesh clients, independent NATs and controlled WAN conditions.

Only run in a disposable privileged Docker container with --network none.
All tc, iptables, forwarding and namespaces are confined to that container.
"""
import importlib.util
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path('/workspace')
BIN = Path(os.environ.get('MESH_TEST_BIN', str(ROOT / 'vendor/easytier/linux-x86_64')))
FAST = os.environ.get('MESH_TEST_FAST') == '1'
COMMON = os.environ.get('MESH_TEST_COMMON') == '1'
spec = importlib.util.spec_from_file_location('relayctl', ROOT / 'relayctl.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
# Reuse the isolated STUN fixture, without executing the two-player test.
source = (ROOT / 'tests/network_integration.py').read_text()
STUN = source.split("STUN = r'''", 1)[1].split("'''", 1)[0]
CLIENTS = range(1, 7)
ADDRESSES = {i: '10.77.77.%d' % (i + 1) for i in CLIENTS}
NODE_FOR_IP = {ip: i for i, ip in ADDRESSES.items()}
PAIRS = set(itertools.combinations(CLIENTS, 2))
PARTIAL = {(1, 2), (3, 4), (5, 6)}
PROCESSES = []
NAMESPACES = []
CORES = {}
ECHOS = {}
SAMPLES = None
REPORT = {'kind': 'isolated simulation with real EasyTier 2.6.4',
          'players': 6, 'pairs': 15, 'direct_rtt_model_ms': 80,
          'relay_rtt_model_ms_before_serialization': 120,
          'relay_egress_mbps': 1, 'relay_queue_limit_packets': 80, 'phases': []}


def cmd(*args, ns=None, data=None, check=True):
    prefix = ['ip', 'netns', 'exec', ns] if ns else []
    return subprocess.run(prefix + list(map(str, args)), input=data, text=True,
                          capture_output=True, check=check, timeout=12)


def spawn(args, namespace, **kwargs):
    p = subprocess.Popen(['ip', 'netns', 'exec', namespace] + list(map(str, args)), **kwargs)
    PROCESSES.append(p)
    return p


def cli(namespace, *args):
    return json.loads(cmd(BIN / 'easytier-cli', '-p', '127.0.0.1:15887', '-o', 'json',
                          *args, ns=namespace).stdout)


def wait_for(label, predicate, seconds=90):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        try:
            value = predicate()
            if value:
                print('PASS ' + label, flush=True)
                return value
        except (subprocess.SubprocessError, ValueError):
            pass
        time.sleep(1)
    raise AssertionError(label + ' timed out')


def namespace(name):
    cmd('ip', 'netns', 'add', name)
    NAMESPACES.append(name)
    cmd('ip', 'link', 'set', 'lo', 'up', ns=name)


def fabric_link(name, dev, address):
    peer = 'p' + name
    cmd('ip', 'link', 'add', peer, 'type', 'veth', 'peer', 'name', dev)
    cmd('ip', 'link', 'set', peer, 'netns', 'fabric')
    cmd('ip', 'link', 'set', dev, 'netns', name)
    cmd('ip', 'link', 'set', peer, 'master', 'publicbr', ns='fabric')
    cmd('ip', 'link', 'set', peer, 'up', ns='fabric')
    cmd('ip', 'addr', 'add', address, 'dev', dev, ns=name)
    cmd('ip', 'link', 'set', dev, 'up', ns=name)
    return peer


def netem(namespace, dev, delay, rate=None, limit=1000):
    args = ['tc', 'qdisc', 'add', 'dev', dev, 'root', 'netem', 'limit', str(limit),
            'delay', str(delay) + 'ms', '1ms', 'distribution', 'normal']
    if rate:
        args += ['rate', rate]
    cmd(*args, ns=namespace)


def topology():
    for name in ['fabric', 'server'] + ['nat%d' % i for i in CLIENTS] + ['client%d' % i for i in CLIENTS]:
        namespace(name)
    cmd('ip', 'link', 'add', 'publicbr', 'type', 'bridge', ns='fabric')
    for ip in ('192.0.2.1/24', '192.0.2.2/24'):
        cmd('ip', 'addr', 'add', ip, 'dev', 'publicbr', ns='fabric')
    cmd('ip', 'link', 'set', 'publicbr', 'up', ns='fabric')
    server_peer = fabric_link('server', 'wan0', '192.0.2.100/24')
    netem('server', 'wan0', 10, '1mbit', limit=80)
    netem('fabric', server_peer, 10)
    for i in CLIENTS:
        nat, client = 'nat%d' % i, 'client%d' % i
        wan, lan, eth = 'wan%d' % i, 'lan%d' % i, 'eth%d' % i
        peer = fabric_link(nat, wan, '192.0.2.%d/24' % (10 + i))
        netem(nat, wan, 20)
        netem('fabric', peer, 20)
        cmd('ip', 'link', 'add', lan, 'type', 'veth', 'peer', 'name', eth)
        cmd('ip', 'link', 'set', lan, 'netns', nat)
        cmd('ip', 'link', 'set', eth, 'netns', client)
        for name, dev, ip in ((nat, lan, '10.20%d.0.1/24' % i), (client, eth, '10.20%d.0.2/24' % i)):
            cmd('ip', 'addr', 'add', ip, 'dev', dev, ns=name)
            cmd('ip', 'link', 'set', dev, 'up', ns=name)
        cmd('ip', 'route', 'add', 'default', 'via', '10.20%d.0.1' % i, ns=client)
        cmd('python3', '-c', "open('/proc/sys/net/ipv4/ip_forward','w').write('1')", ns=nat)
        cmd('iptables', '-P', 'FORWARD', 'DROP', ns=nat)
        cmd('iptables', '-N', 'PAIR_BLOCK', ns=nat)
        cmd('iptables', '-A', 'FORWARD', '-j', 'PAIR_BLOCK', ns=nat)
        cmd('iptables', '-A', 'FORWARD', '-m', 'conntrack', '--ctstate', 'ESTABLISHED,RELATED', '-j', 'ACCEPT', ns=nat)
        cmd('iptables', '-A', 'FORWARD', '-i', lan, '-o', wan, '-j', 'ACCEPT', ns=nat)
        # Endpoint-independent UDP mapping plus port-restricted inbound filtering.
        cmd('iptables', '-t', 'nat', '-A', 'PREROUTING', '-i', wan, '-p', 'udp', '-j', 'DNAT', '--to-destination', '10.20%d.0.2' % i, ns=nat)
        cmd('iptables', '-t', 'nat', '-A', 'POSTROUTING', '-o', wan, '-j', 'MASQUERADE', ns=nat)
    spawn(['python3', '-u', '-c', STUN], 'fabric', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def block(pairs):
    for i in CLIENTS:
        rules = ['*filter', '-F PAIR_BLOCK']
        for a, b in sorted(pairs):
            if i not in (a, b):
                continue
            other = b if i == a else a
            for flag in ('-s', '-d'):
                rules.append('-A PAIR_BLOCK %s 192.0.2.%d -j DROP' % (flag, 10 + other))
        # One atomic table commit per gateway: an existing blocked pair must
        # never briefly reopen while adding other failed pairs.
        cmd('iptables-restore', '--noflush', data='\n'.join(rules + ['COMMIT', '']), ns='nat%d' % i)


def delay_pair(enable):
    """Only direct 1<->2 is slow; both links still pass game packets."""
    for i, other in ((1, 2), (2, 1)):
        nat, wan = 'nat%d' % i, 'wan%d' % i
        cmd('tc', 'qdisc', 'change', 'dev', wan, 'parent', '1:2', 'handle', '20:', 'netem', 'delay', '650ms' if enable else '20ms', ns=nat)


def prepare_delay_pair():
    # Create classification before any clients start. Changing only the leaf
    # delay later must not discard unrelated players' already queued packets.
    for i, other in ((1, 2), (2, 1)):
        nat, wan = 'nat%d' % i, 'wan%d' % i
        cmd('tc', 'qdisc', 'del', 'dev', wan, 'root', ns=nat)
        cmd('tc', 'qdisc', 'add', 'dev', wan, 'root', 'handle', '1:', 'prio', 'bands', '3', 'priomap', *(['0'] * 16), ns=nat)
        cmd('tc', 'qdisc', 'add', 'dev', wan, 'parent', '1:1', 'handle', '10:', 'netem', 'delay', '20ms', '1ms', ns=nat)
        cmd('tc', 'qdisc', 'add', 'dev', wan, 'parent', '1:2', 'handle', '20:', 'netem', 'delay', '20ms', ns=nat)
        cmd('tc', 'filter', 'add', 'dev', wan, 'parent', '1:', 'protocol', 'ip', 'prio', '1', 'u32',
            'match', 'ip', 'dst', '192.0.2.%d/32' % (10 + other), 'flowid', '1:2', ns=nat)


def duplicate_outer(enable):
    for i in (1, 2):
        args = ['tc', 'qdisc', 'replace', 'dev', 'wan%d' % i, 'root', 'netem', 'delay', '20ms', '1ms']
        if enable:
            args += ['duplicate', '100%']
        cmd(*args, ns='nat%d' % i)


def start_core(path, name, credential=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith('ET_')}
    if credential:
        env['ET_CREDENTIAL'] = credential
    with path.with_suffix('.log').open('wb') as log:
        CORES[name] = spawn([BIN / 'easytier-core', '-c', path, '--disable-env-parsing', '--rpc-portal', '127.0.0.1:15887'],
                            name, stdout=log, stderr=log, env=env)


def route_matrix():
    matrix = {}
    for i in CLIENTS:
        rows = cli('client%d' % i, 'route')
        for row in rows:
            if re.fullmatch('player[1-6]', row.get('hostname', '')):
                j = int(row['hostname'][-1])
                if j == i:
                    continue
                matrix['%d>%d' % (i, j)] = {'hops': row['path_len'], 'via': row.get('next_hop_hostname')}
    return matrix


def matches(matrix, blocked):
    return len(matrix) == 30 and all(
        value['hops'] == (2 if tuple(sorted(map(int, pair.split('>')))) in blocked else 1)
        and (value['hops'] != 2 or value['via'] == 'Civ6Coordinator')
        for pair, value in matrix.items())


def metrics():
    values = cmd('python3', '-c', "import json;from pathlib import Path; print(json.dumps({x:int(Path('/sys/class/net/wan0/statistics/'+x).read_text()) for x in ['tx_bytes','rx_bytes','tx_packets','rx_packets']}))", ns='server')
    result = json.loads(values.stdout)
    fields = Path('/proc/%d/stat' % CORES['server'].pid).read_text().split()
    result['cpu_ticks'] = int(fields[13]) + int(fields[14])
    result['rss_kib'] = int(fields[23]) * os.sysconf('SC_PAGE_SIZE') // 1024
    result['at'] = time.monotonic()
    return result


def percentile(values, p):
    if not values:
        return None
    return round(sorted(values)[min(len(values) - 1, int((len(values) - 1) * p))], 2)


def summary(nodes, pairs=None):
    samples = [sample for node in nodes for ip, flow in node['flows'].items()
               if pairs is None or tuple(sorted((node['node'], NODE_FOR_IP[ip]))) in pairs
               for sample in flow]
    latencies = [s[1] for s in samples if s[1] is not None]
    return dict(sent=len(samples), received=len(latencies), lost=len(samples) - len(latencies),
                loss_pct=round(100 * (len(samples) - len(latencies)) / len(samples), 2) if samples else 0,
                rtt_median_ms=round(statistics.median(latencies), 2) if latencies else None,
                rtt_p95_ms=percentile(latencies, .95), rtt_max_ms=max(latencies) if latencies else None,
                received_later_than_1s=sum(value > 1000 for value in latencies))


def phase(folder, label, duration=16, pps=2, payload=256, blocked=None, action=None, end_action=None):
    start = time.monotonic() + 2
    paths, jobs = [], []
    for i in CLIENTS:
        output = folder / ('%s-%d.json' % (label, i))
        paths.append(output)
        peers = ','.join(ADDRESSES[j] for j in CLIENTS if i != j)
        jobs.append(spawn(['python3', ROOT / 'tests/mesh_traffic.py', 'bench', '--node', i,
                           '--bind', ADDRESSES[i], '--peers', peers, '--start', start,
                           '--duration', duration, '--pps', pps, '--payload', payload, '--output', output],
                          'client%d' % i, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE))
    while time.monotonic() < start:
        time.sleep(.05)
    before = metrics()
    changed_at = None
    observed = []
    if action:
        time.sleep(3)
        changed_at = time.monotonic()
        action()
    while time.monotonic() < start + duration:
        if action:
            current = route_matrix()
            if not observed or current != observed[-1]['routes']:
                observed.append(dict(seconds=round(time.monotonic() - start, 3), routes=current))
        time.sleep(max(0, min(2, start + duration - time.monotonic())))
    after = metrics()
    matrix = route_matrix()
    if end_action:
        end_action()
    for job in jobs:
        _, err = job.communicate(timeout=duration + 8)
        if job.returncode:
            raise RuntimeError('UDP benchmark failed: ' + err.decode()[-300:])
    elapsed = after['at'] - before['at']
    nodes = [json.loads(path.read_text()) for path in paths]
    for path in paths:
        shutil.copyfile(path, SAMPLES / path.name)
    result = dict(name=label, duration=duration, pps_per_directed_flow=pps, payload_bytes=payload,
                  total=summary(nodes), routes=matrix,
                  server=dict(tx_kbps=round((after['tx_bytes'] - before['tx_bytes']) * 8 / elapsed / 1000, 2),
                              rx_kbps=round((after['rx_bytes'] - before['rx_bytes']) * 8 / elapsed / 1000, 2),
                              cpu_pct_one_core=round((after['cpu_ticks'] - before['cpu_ticks']) / os.sysconf('SC_CLK_TCK') / elapsed * 100, 2),
                              rss_mib=round(after['rss_kib'] / 1024, 2), measurement_seconds=round(elapsed, 2)))
    if blocked is not None:
        result['blocked_pairs'] = [list(pair) for pair in sorted(blocked)]
        result['blocked_flows'] = summary(nodes, blocked)
        result['other_flows'] = summary(nodes, PAIRS - blocked)
        result['expected_routes'] = matches(matrix, blocked)
    if changed_at is not None:
        offset = changed_at - start
        result['action_at_seconds'] = round(offset, 3)
        result['route_changes'] = observed
        expected_at = next((observation['seconds'] - offset for observation in observed
                            if matches(observation['routes'], blocked)), None)
        result['all_expected_routes_seconds_after_action'] = round(expected_at, 3) if expected_at is not None else None
        gaps = {}
        for node in nodes:
            for ip, samples in node['flows'].items():
                missing = [sample for sample in samples if sample[0] >= offset and sample[1] is None]
                if missing:
                    first_missing = missing[0][0]
                    arrivals = [sample[0] + sample[1] / 1000 - offset for sample in samples
                                if sample[0] > first_missing and sample[1] is not None]
                    recovery = min(arrivals) if arrivals else None
                    gaps['%d>%d' % (node['node'], NODE_FOR_IP[ip])] = {
                        'lost_packets': len(missing), 'data_recovered_seconds_after_action': round(recovery, 3) if recovery else None}
        result['affected_flow_recovery'] = gaps
    REPORT['phases'].append(result)
    print('PHASE ' + json.dumps({k: v for k, v in result.items() if k not in ('routes', 'affected_flow_recovery', 'route_changes')}), flush=True)
    return result


def main():
    global SAMPLES
    output = Path(sys.argv[1] if len(sys.argv) > 1 else '/workspace/.build/six-player-simulation.json')
    SAMPLES = output.with_name(output.stem + '-samples')
    SAMPLES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='civ6-six-') as td:
        folder = Path(td)
        try:
            topology()
            if FAST:
                prepare_delay_pair()
            baseline = {i: cmd('ip', 'route', 'show', 'default', ns='client%d' % i).stdout for i in CLIENTS}
            private = cmd(ROOT / 'vendor/linux-amd64/wg', 'genkey').stdout.strip()
            public = cmd(ROOT / 'vendor/linux-amd64/wg', 'pubkey', data=private + '\n').stdout.strip()
            state = r.settings('8.8.8.8', port=51820)
            state.update(instance_id=str(uuid.uuid4()), network_name='civ6-test', network_secret=uuid.uuid4().hex, private_key=private, public_key=public)
            path = folder / 'server.toml'
            path.write_text(r.server_config(state).replace('/etc/civ6-relay/credentials.json', str(folder / 'credentials.json')))
            start_core(path, 'server')
            wait_for('coordinator ready', lambda: cli('server', 'node', 'info'), 15)
            REPORT['engine_version'] = cmd(BIN / 'easytier-core', '--version').stdout.strip()
            REPORT['fast_failover_expected'] = FAST
            template = (ROOT / ('.build/common-client-test.toml' if COMMON else '.build/client-test.toml')).read_text()
            common_credential = cli('server', 'credential', 'generate', '--ttl', '3600', '--credential-id', str(uuid.uuid4()), '--reusable', 'true') if COMMON else None
            credentials = {}
            for i in CLIENTS:
                credential = common_credential if COMMON else cli('server', 'credential', 'generate', '--ttl', '3600', '--credential-id', str(uuid.uuid4()), '--reusable', 'false')
                credentials[i] = credential['credential_secret']
                client_public = cmd(ROOT / 'vendor/linux-amd64/wg', 'pubkey', data=credentials[i] + '\n').stdout.strip()
                trust = folder / ('trusted%d.json' % i)
                trust.write_text(json.dumps({'coordinator': dict(pubkey=public, secret='', groups=[], allow_relay=True, allowed_proxy_cidrs=[], reusable=True, expiry_unix=int(time.time()) + 3600, created_at_unix=int(time.time()))}))
                config = template
                for key, value in dict(instance_id=str(uuid.uuid4()), hostname='player%d' % i, ipv4='10.77.77.%d/24' % (i + 1), credential_file=str(trust), local_private_key=credentials[i], local_public_key=client_public).items():
                    config = re.sub(r'^' + key + r' = .*$', key + ' = ' + json.dumps(value), config, flags=re.M)
                config = re.sub(r'^peer_public_key = .*$', 'peer_public_key = ' + json.dumps(public), config, flags=re.M)
                config = config.replace('8.8.8.8:51820', '192.0.2.100:51820').replace('enable_ipv6 = true', 'enable_ipv6 = false')
                config = 'stun_servers = ["192.0.2.1:3478", "192.0.2.2:3478"]\nstun_servers_v6 = []\n' + config
                (folder / ('client%d.toml' % i)).write_text(config)
                ECHOS[i] = spawn(['python3', ROOT / 'tests/mesh_traffic.py', 'echo', '--stats', folder / ('echo%d.json' % i)], 'client%d' % i, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            before = metrics()
            for i in CLIENTS:
                start_core(folder / ('client%d.toml' % i), 'client%d' % i, credentials[i])
            wait_for('all 15 pairs / 30 directions use actual direct paths', lambda: matches(route_matrix(), set()), 110)
            if COMMON:
                def addresses_ready():
                    found = {}
                    for i in CLIENTS:
                        rows = cli('client%d' % i, 'route')
                        own = next((x for x in rows if x.get('hostname') == 'player%d' % i and x.get('path_len') == 0), {})
                        ip = own.get('ipv4', '').split('/')[0]
                        if not re.fullmatch(r'10\.77\.77\.(?:[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])', ip): return False
                        found[i] = ip
                    return found if len(set(found.values())) == 6 else False
                assigned = wait_for('six identical-access clients receive distinct automatic IPs', addresses_ready, 90)
                time.sleep(12)
                assert addresses_ready() == assigned, 'automatic addresses churned after convergence'
                ADDRESSES.update(assigned)
                NODE_FOR_IP.clear(); NODE_FOR_IP.update({ip:i for i,ip in assigned.items()})
                REPORT.update(common_access=True, all_six_share_same_key=len(set(credentials.values()))==1,
                              automatic_addresses=assigned, addresses_stable_after_12s=True)
            after = metrics()
            REPORT['startup'] = dict(seconds_to_all_direct=round(after['at'] - before['at'], 2),
                                     server_tx_kib=round((after['tx_bytes'] - before['tx_bytes']) / 1024, 2),
                                     server_rx_kib=round((after['rx_bytes'] - before['rx_bytes']) / 1024, 2))
            print('STARTUP ' + json.dumps(REPORT['startup']), flush=True)
            REPORT['nat_types'] = {str(i): cli('client%d' % i, 'node', 'info').get('stun_info', {}).get('udp_nat_type') for i in CLIENTS}
            direct = phase(folder, 'direct', blocked=set())
            assert direct['expected_routes'] and direct['total']['loss_pct'] < 1, 'direct connectivity failed'
            if FAST:
                false_alarm = phase(folder, 'false_positive', duration=8, pps=5, payload=64, blocked={(1, 2)},
                                    action=lambda: delay_pair(True), end_action=lambda: delay_pair(False))
                assert false_alarm['expected_routes'] and false_alarm['total']['lost'] == 0, 'slow but connected link did not safely use relay'
                recovered = phase(folder, 'false_positive_recovered', duration=8, blocked=set())
                assert recovered['expected_routes'] and recovered['total']['lost'] == 0
                duplicate_outer(True)
                try:
                    duplicated = phase(folder, 'duplicate_outer', duration=8, blocked=set())
                    assert duplicated['expected_routes'] and duplicated['total']['lost'] == 0
                finally:
                    duplicate_outer(False)
            transition = dict(duration=20, pps=5, payload=64) if FAST else dict(duration=45)
            partial = phase(folder, 'partial_failure', blocked=PARTIAL, action=lambda: block(PARTIAL), **transition)
            assert partial['expected_routes'], 'partial fallback routes failed'
            steady = phase(folder, 'partial_relay', blocked=PARTIAL)
            assert steady['total']['loss_pct'] < 1, 'steady partial relay data failed'
            full = phase(folder, 'all_failure', blocked=PAIRS, action=lambda: block(PAIRS), **transition)
            assert full['expected_routes'], 'full fallback routes failed'
            steady = phase(folder, 'all_relay', blocked=PAIRS)
            assert steady['total']['loss_pct'] < 1, 'steady relay data failed'
            if not FAST:
                phase(folder, 'all_relay_overload', duration=16, pps=4, payload=494, blocked=PAIRS)
            phase(folder, 'restore', duration=70, blocked=set(), action=lambda: block(set()))
            wait_for('all pairs return to direct paths', lambda: matches(route_matrix(), set()), 60)
            restored = phase(folder, 'restored_direct', blocked=set())
            assert restored['total']['loss_pct'] < 1, 'restored direct data failed'
            if FAST:
                for tested, skip in ((partial, set()), (full, PARTIAL)):
                    recoveries = [v['data_recovered_seconds_after_action'] for key, v in tested['affected_flow_recovery'].items()
                                  if tuple(sorted(map(int, key.split('>')))) not in skip]
                    assert recoveries and all(t is not None and t < 3 for t in recoveries), 'fast fallback exceeded 3 seconds'
            for p in ECHOS.values():
                p.send_signal(signal.SIGUSR1)
            time.sleep(.2)
            REPORT['game_socket_counts'] = {str(i): json.loads((folder / ('echo%d.json' % i)).read_text()) for i in CLIENTS}
            assert all(v['duplicates_delivered_to_game_socket'] == 0 for v in REPORT['game_socket_counts'].values()), 'duplicate tunnel packet leaked to game socket'
            assert all(cmd('ip', 'route', 'show', 'default', ns='client%d' % i).stdout == baseline[i] for i in CLIENTS)
            REPORT['default_routes_unchanged'] = True
            REPORT['passed'] = True
            print('PASS six-player direct / partial relay / all relay / recovery', flush=True)
        finally:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(REPORT, indent=2))
            for p in reversed(PROCESSES):
                if p.poll() is None:
                    p.send_signal(signal.SIGINT)
                    try:
                        p.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        p.kill()
                        p.wait()
            for name in reversed(NAMESPACES):
                cmd('ip', 'netns', 'del', name, check=False)


if __name__ == '__main__':
    main()
