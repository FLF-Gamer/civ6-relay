#!/usr/bin/env python3
"""Bounded six-client relay measurement against the existing deployment.

Controller runs on the Docker host. Uses a preauthenticated SSH control socket,
issues six one-day credentials, forces the actual clients through the relay,
and revokes/removes them in finally. No service restart or firewall changes.
MESH_TEST_ENDPOINT is supplied externally, never stored in distributable files.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
DOCKER = shutil.which('docker') or str(Path.home() / '.docker/bin/docker')


def command(args, data=None, timeout=30):
    result = subprocess.run(list(map(str, args)), input=data, text=True,
                            capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Test command failed: %s; %s' % (args[0], result.stderr[-300:]))
    return result.stdout


def summarize(nodes):
    samples = [sample for node in nodes for flow in node['flows'].values() for sample in flow]
    rtt = sorted(sample[1] for sample in samples if sample[1] is not None)
    pairs = {}
    for node in nodes:
        for ip, flow in node['flows'].items():
            values = [sample[1] for sample in flow if sample[1] is not None]
            pairs['%s>%s' % (node['node'], ip)] = dict(sent=len(flow), received=len(values),
                                                     median_ms=round(statistics.median(values), 2) if values else None,
                                                     lost_at_seconds=[sample[0] for sample in flow if sample[1] is None])
    return dict(sent=len(samples), received=len(rtt), lost=len(samples) - len(rtt),
                loss_pct=round(100 * (len(samples) - len(rtt)) / len(samples), 2),
                rtt_median_ms=round(statistics.median(rtt), 2) if rtt else None,
                rtt_p95_ms=rtt[int((len(rtt) - 1) * .95)] if rtt else None,
                rtt_max_ms=rtt[-1] if rtt else None, per_flow=pairs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', default='/private/tmp/civ6-relay-ssh-six')
    parser.add_argument('--known-hosts', default='/private/tmp/civ6-relay-known-hosts')
    parser.add_argument('--output', default=str(ROOT / '.build/six-player-wan.json'))
    parser.add_argument('--smoke', action='store_true', help='Warm up and measure light load only')
    args = parser.parse_args()
    endpoint = os.environ['MESH_TEST_ENDPOINT']
    ssh = ['ssh', '-S', args.socket, '-o', 'UserKnownHostsFile=' + args.known_hosts,
           '-o', 'StrictHostKeyChecking=yes', 'root@' + endpoint, 'PYTHONIOENCODING=utf-8 python3 -']

    def remote(code):
        return command(ssh, code)

    prefix = 'six' + uuid.uuid4().hex[:6]
    names = [prefix + str(i) for i in range(1, 7)]
    containers = []
    folder = Path(tempfile.mkdtemp(prefix=prefix + '-', dir=ROOT / '.build/wan-private'))
    folder.chmod(0o700)
    report = dict(kind='real deployed server; six containers sharing one WAN; P2P disabled',
                  payload='synthetic UDP echo, not a Civ6 packet trace', phases=[])
    samples_dir = Path(args.output).with_name(Path(args.output).stem + '-samples')
    samples_dir.mkdir(parents=True, exist_ok=True)
    setup = '''
import contextlib,fcntl,importlib.util,io,json
s=importlib.util.spec_from_file_location('relayctl','/opt/civ6-relay/relayctl.py')
r=importlib.util.module_from_spec(s);s.loader.exec_module(r)
relay=r.Relay();profiles=[]
with open('/run/civ6-relay.lock','a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 with contextlib.redirect_stdout(io.StringIO()):
  for name in NAMES:profiles.append(relay.add(name,1))
print(json.dumps(profiles))
'''.replace('NAMES', repr(names))
    sample_code = '''
import json,os,subprocess,time
from pathlib import Path
pid=int(subprocess.check_output(['systemctl','show','civ6-relay','-p','MainPID']).decode().split('=')[1])
stat=Path('/proc/%d/stat'%pid).read_text().split()
value={x:int(Path('/sys/class/net/eth0/statistics/'+x).read_text()) for x in ['tx_bytes','rx_bytes']}
value.update(at=time.monotonic(),cpu_ticks=int(stat[13])+int(stat[14]),rss_kib=int(stat[23])*os.sysconf('SC_PAGE_SIZE')//1024,hz=os.sysconf('SC_CLK_TCK'))
print(json.dumps(value))
'''

    def sample():
        return json.loads(remote(sample_code))

    def delta(before, after):
        elapsed = after['at'] - before['at']
        return dict(tx_kbps=round((after['tx_bytes'] - before['tx_bytes']) * 8 / elapsed / 1000, 2),
                    rx_kbps=round((after['rx_bytes'] - before['rx_bytes']) * 8 / elapsed / 1000, 2),
                    cpu_pct_one_core=round((after['cpu_ticks'] - before['cpu_ticks']) / after['hz'] / elapsed * 100, 2),
                    rss_mib=round(after['rss_kib'] / 1024, 2), measurement_seconds=round(elapsed, 2))

    def routes(container):
        return json.loads(command([DOCKER, 'exec', container, 'python3', '/workspace/tests/wan_integration.py', 'routes']))

    try:
        before = sample()
        time.sleep(5)
        report['idle_without_clients'] = delta(before, sample())
        profiles = json.loads(remote(setup))
        for i, profile in enumerate(profiles, 1):
            path = folder / ('player%d.json' % i)
            path.write_text(json.dumps(profile))
            path.chmod(0o600)
            container = 'civ6-' + names[i - 1]
            command([DOCKER, 'run', '--detach', '--rm', '--name', container,
                     '--cap-add', 'NET_ADMIN', '--device', '/dev/net/tun', '--platform', 'linux/amd64',
                     '-v', str(ROOT) + ':/workspace:ro', '-v', str(folder) + ':/results',
                     '-e', 'MESH_TEST_ENDPOINT=' + endpoint, '-e', 'MESH_TEST_PORT=' + os.environ.get('MESH_TEST_PORT', '9527'),
                     '-e', 'MESH_TEST_BIN=' + os.environ.get('MESH_TEST_BIN', '/workspace/vendor/easytier/linux-x86_64'),
                     'civ6-mesh-test:local', 'python3', '-u', '/workspace/tests/wan_integration.py',
                     'node', '/results/' + path.name])
            containers.append(container)
        until = time.monotonic() + 60
        while time.monotonic() < until:
            with ThreadPoolExecutor(max_workers=6) as pool:
                matrices = list(pool.map(routes, containers))
            expected = [[row for row in matrix if row.get('hostname') in names and row.get('path_len', 0) > 0] for matrix in matrices]
            if all(len(matrix) == 5 and all(row['path_len'] == 2 and row['next_hop_hostname'] == 'Civ6Coordinator' for row in matrix) for matrix in expected):
                report['all_30_directions_via_server'] = True
                report['client_engine_versions'] = sorted({row.get('version') for matrix in matrices for row in matrix if row.get('hostname') in names})
                report['coordinator_engine_versions'] = sorted({row.get('version') for matrix in matrices for row in matrix if row.get('hostname') == 'Civ6Coordinator'})
                print('PASS actual WAN: six clients, all 15 pairs / 30 directions via server', flush=True)
                break
            time.sleep(2)
        else:
            report['failure_routes'] = matrices
            print('ROUTES ' + json.dumps([[dict(hostname=row.get('hostname'), hops=row.get('path_len'), version=row.get('version')) for row in matrix] for matrix in matrices]), flush=True)
            for container in containers:
                result = subprocess.run([DOCKER, 'logs', '--tail', '18', container], capture_output=True, text=True)
                print('DIAGNOSTIC ' + result.stdout.replace(endpoint, '[server]'), flush=True)
            raise AssertionError('Six real relay clients did not converge')
        before = sample()
        time.sleep(8)
        report['connected_idle'] = delta(before, sample())

        scenarios = [('cold_start', 1, 128, 6), ('relay_light', 2, 256, 12)] if args.smoke else [
            ('cold_start', 1, 128, 6), ('relay_light', 2, 256, 20),
            ('relay_overload', 4, 494, 20), ('relay_recovered', 2, 256, 20)]
        for label, pps, payload, duration in scenarios:
            start = float(command([DOCKER, 'exec', containers[0], 'python3', '-c', 'import time;print(time.monotonic()+3)']).strip())
            jobs = []
            for i, (container, profile) in enumerate(zip(containers, profiles), 1):
                peers = ','.join(p['client_ip'] for p in profiles if p['client_ip'] != profile['client_ip'])
                args_ = [DOCKER, 'exec', container, 'python3', '/workspace/tests/mesh_traffic.py', 'bench',
                         '--node', i, '--bind', profile['client_ip'], '--peers', peers, '--start', str(start),
                         '--duration', str(duration), '--pps', str(pps), '--payload', str(payload),
                         '--output', '/results/%s-%d.json' % (label, i)]
                jobs.append(subprocess.Popen(list(map(str, args_)), stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            now = float(command([DOCKER, 'exec', containers[0], 'python3', '-c', 'import time;print(time.monotonic())']).strip())
            time.sleep(max(0, start - now))
            before = sample()
            time.sleep(duration)
            after = sample()
            for job in jobs:
                _, err = job.communicate(timeout=duration + 12)
                if job.returncode:
                    raise RuntimeError('WAN UDP benchmark failed: ' + err.decode()[-200:])
            nodes = [json.loads((folder / ('%s-%d.json' % (label, i))).read_text()) for i in range(1, 7)]
            for i in range(1, 7):
                filename = '%s-%d.json' % (label, i)
                shutil.copyfile(folder / filename, samples_dir / filename)
            result = dict(name=label, duration=duration, pps_per_directed_flow=pps, payload_bytes=payload,
                          total=summarize(nodes), server=delta(before, after))
            report['phases'].append(result)
            print('PHASE ' + json.dumps(dict(result, total={k: v for k, v in result['total'].items() if k != 'per_flow'})), flush=True)
        report['passed'] = True
    finally:
        for container in containers:
            subprocess.run([DOCKER, 'stop', '--timeout', '10', container], capture_output=True, timeout=20)
        cleanup = '''
import contextlib,fcntl,importlib.util,io,json,subprocess
s=importlib.util.spec_from_file_location('relayctl','/opt/civ6-relay/relayctl.py')
r=importlib.util.module_from_spec(s);s.loader.exec_module(r);relay=r.Relay()
with open('/run/civ6-relay.lock','a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 with contextlib.redirect_stdout(io.StringIO()):
  for name in NAMES:
   if name in relay.load()['clients']:relay.revoke(name)
print(json.dumps({'remaining_players':sorted(relay.load()['clients']), 'services':subprocess.check_output(['systemctl','is-active','civ6-relay','firewalld','auditd','sshd']).decode().split()}))
'''.replace('NAMES', repr(names))
        report['cleanup'] = json.loads(remote(cleanup))
        shutil.rmtree(folder)
        Path(args.output).write_text(json.dumps(report, indent=2))
        print('CLEANUP ' + json.dumps(report['cleanup']), flush=True)


if __name__ == '__main__':
    main()
