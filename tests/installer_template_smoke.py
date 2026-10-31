#!/usr/bin/env python3
"""Run the real installer only inside a disposable, offline Linux container.

Example (from the repository root, using an already cached amd64 image):
docker run --rm --platform linux/amd64 --network none -v "$PWD:/workspace:ro" \
  civ6-mesh-test:local python3 /workspace/tests/installer_template_smoke.py --isolated-container

System commands and CLI replies are fixtures. The installer, component hashes,
file copies, template compression, relay initialization and bundle export are real.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
PROGRAM = Path('/opt/civ6-relay')
CONFIG = Path('/etc/civ6-relay')
FIXTURE = Path('/tmp/civ6-installer-smoke')

CLI_STUB = '''#!/usr/bin/python3
import base64, json, sys
args = sys.argv[1:]
if 'generate' in args:
    print(json.dumps({'credential_id': args[args.index('--credential-id') + 1],
        'credential_secret': base64.b64encode(bytes(range(32))).decode('ascii')}))
elif args[-1:] == ['route']:
    print('[]')
else:
    print('{}')
'''

COMMAND_STUB = '''#!/usr/bin/python3
import hashlib, json, os, shutil, sys
from pathlib import Path
root = Path('/tmp/civ6-installer-smoke')
name = Path(sys.argv[0]).name
args = sys.argv[1:]
calls = root / 'calls.json'
history = json.loads(calls.read_text()) if calls.exists() else []
history.append([name] + args)
calls.write_text(json.dumps(history))
if name == 'ip':
    if args != ['-4', 'route', 'get', '1.1.1.1']: sys.exit(2)
    print('1.1.1.1 via 192.0.2.1 dev smoke0 src 192.0.2.2')
elif name == 'firewall-cmd':
    state = root / 'ports.json'
    ports = set(json.loads(state.read_text()))
    if args == ['--state']: print('running')
    elif args == ['--get-default-zone'] or args == ['--get-zone-of-interface=smoke0']: print('smoke')
    else:
        action = next((x for x in args if x.startswith(('--query-port=', '--add-port=', '--remove-port='))), None)
        if action is None or '--zone=smoke' not in args: sys.exit(2)
        key = ('permanent:' if '--permanent' in args else 'runtime:') + action.split('=', 1)[1]
        if action.startswith('--query-port='): sys.exit(0 if key in ports else 1)
        if action.startswith('--add-port='): ports.add(key)
        else: ports.discard(key)
        state.write_text(json.dumps(sorted(ports)))
elif name == 'systemctl':
    state = root / 'service-state'
    if args == ['daemon-reload']:
        cli = Path('/opt/civ6-relay/bin/easytier-cli')
        if not (root / 'copied-cli.sha256').exists():
            (root / 'copied-cli.sha256').write_text(hashlib.sha256(cli.read_bytes()).hexdigest())
            shutil.copyfile(str(root / 'cli'), str(cli))
            cli.chmod(0o755)
    elif args == ['enable', '--now', 'civ6-relay.service']: state.write_text('active')
    elif args == ['is-active', 'civ6-relay.service']:
        active = state.read_text() if state.exists() else 'inactive'
        print(active)
        sys.exit(0 if active == 'active' else 3)
    else: sys.exit(2)
else:
    sys.exit(2)
'''


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def command(args, expected_success=True):
    result = subprocess.run(list(map(str, args)), stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, universal_newlines=True, timeout=90)
    if expected_success:
        require(result.returncode == 0, 'Fixture command failed: ' + Path(str(args[0])).name)
    else:
        require(result.returncode != 0, 'Expected installer rejection')
    return result


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    # Never run this filesystem-writing test on a normal host or a networked container.
    require(sys.argv[1:] == ['--isolated-container'], 'Use --isolated-container in a disposable Docker container')
    require(sys.platform == 'linux' and os.geteuid() == 0 and Path('/.dockerenv').is_file(),
        'This smoke test requires a disposable root Linux Docker container')
    # Some kernels expose dormant tunnel devices even in a --network none namespace.
    interfaces = [p for p in Path('/sys/class/net').iterdir() if p.name != 'lo' and (p / 'operstate').is_file()]
    require(all((p / 'operstate').read_text().strip() == 'down' for p in interfaces) and
            len(Path('/proc/net/route').read_text().splitlines()) == 1,
        'This smoke test requires Docker --network none')
    for path in (PROGRAM, CONFIG, Path('/etc/systemd/system/civ6-relay.service'),
                 Path('/usr/local/sbin/civ6-relay'), FIXTURE):
        require(not path.exists() and not path.is_symlink(), 'Container is not clean: ' + str(path))
    require(os.uname().machine == 'x86_64', 'Use an amd64 test image')

    FIXTURE.mkdir(mode=0o700)
    (FIXTURE / 'cli').write_text(CLI_STUB)
    (FIXTURE / 'ports.json').write_text(json.dumps(['permanent:22/tcp', 'runtime:22/tcp']))
    Path('/run/systemd/system').mkdir(parents=True, exist_ok=True)
    Path('/etc/systemd/system').mkdir(parents=True, exist_ok=True)
    Path('/usr/local/sbin').mkdir(parents=True, exist_ok=True)
    if not Path('/usr/bin/python3').exists():
        Path('/usr/bin/python3').symlink_to(sys.executable)
    for name in ('ip', 'firewall-cmd', 'systemctl'):
        path = Path('/usr/local/sbin') / name
        require(not path.exists() and not path.is_symlink(), 'Refusing to overwrite an existing command fixture')
        path.write_text(COMMAND_STUB)
        path.chmod(0o755)

    # A missing runtime must fail before the installer creates an installation.
    with tempfile.TemporaryDirectory(prefix='civ6-missing-runtime-') as temporary:
        source = Path(temporary)
        shutil.copyfile(str(ROOT / 'install.sh'), str(source / 'install.sh'))
        shutil.copyfile(str(ROOT / 'relayctl.py'), str(source / 'relayctl.py'))
        (source / 'vendor').symlink_to(ROOT / 'vendor', target_is_directory=True)
        client = source / 'client/windows'
        client.mkdir(parents=True)
        for name in ('Start.cmd', 'Civ6Relay.ps1', 'README.txt'):
            shutil.copyfile(str(ROOT / 'client/windows' / name), str(client / name))
        missing = command(['bash', source / 'install.sh', '--endpoint', '8.8.8.8', '--port', '29527'], False)
        require('LiveMonitor.cs' in missing.stderr, 'Missing runtime was not identified')
        require(not PROGRAM.exists() and not CONFIG.exists(), 'Missing runtime mutated installation paths')
    print('PASS missing LiveMonitor.cs is rejected before installation')

    command(['bash', ROOT / 'install.sh', '--endpoint', '8.8.8.8', '--port', '29527'])
    require((PROGRAM / '.civ6-relay-managed').read_text().strip() == 'civ6-relay/v3', 'Installation marker missing')
    require((FIXTURE / 'service-state').read_text() == 'active', 'Initialization did not enable the fixture service')
    require((FIXTURE / 'copied-cli.sha256').read_text() == digest(ROOT / 'vendor/easytier/linux-x86_64/easytier-cli'),
        'Installer did not copy the actual CLI before fixture replacement')
    for name, source in (('easytier-core', 'vendor/easytier/linux-x86_64/easytier-core'),
                         ('wg', 'vendor/linux-amd64/wg')):
        require(digest(PROGRAM / 'bin' / name) == digest(ROOT / source), 'Installed component differs: ' + name)
    with zipfile.ZipFile(str(PROGRAM / 'client/windows-template.zip')) as archive:
        require('profile.json' not in archive.namelist(), 'Public Windows template contains access information')
        require('bin/Packet.dll' not in archive.namelist(), 'Windows template contains the retired Npcap DLL')
        for path in sorted((ROOT / 'client/windows').rglob('*')):
            if path.is_file():
                name = str(path.relative_to(ROOT / 'client/windows'))
                require(archive.read(name) == path.read_bytes(), 'Template source differs or is missing: ' + name)
        require(archive.read('LiveMonitor.cs') == (ROOT / 'client/windows/LiveMonitor.cs').read_bytes(),
            'Template runtime differs from source')
    print('PASS actual installer hashes/copies components and includes the exact live runtime in the template')

    command(['/usr/local/sbin/civ6-relay', 'status'])
    command(['/usr/local/sbin/civ6-relay', 'bundle'])
    exported = CONFIG / 'exports/windows.zip'
    require(exported.stat().st_mode & 0o777 == 0o600, 'Shared Windows export is not private')
    with zipfile.ZipFile(str(exported)) as archive:
        require('bin/Packet.dll' not in archive.namelist(), 'Shared Windows export contains the retired Npcap DLL')
        require(archive.read('LiveMonitor.cs') == (ROOT / 'client/windows/LiveMonitor.cs').read_bytes(),
            'Shared Windows export omitted or changed the live runtime')
        profile = json.loads(archive.read('profile.json').decode('utf-8'))
        require(profile.get('schema') == 4 and profile.get('access_mode') == 'shared', 'Shared profile shape differs')
        require(not any(name in profile for name in ('instance_id', 'player', 'client_ip', 'endpoint', 'port', 'network_secret')),
            'Shared profile unexpectedly contains a device identity or endpoint')
    ports = set(json.loads((FIXTURE / 'ports.json').read_text()))
    require(ports == {'permanent:22/tcp', 'runtime:22/tcp', 'permanent:29527/tcp', 'runtime:29527/tcp',
                      'permanent:29527/udp', 'runtime:29527/udp'}, 'Installer changed unrelated fixture firewall state')
    print('PASS actual initialization/bundle export preserves runtime, private profile shape and existing firewall rules')

    before = {path: digest(path) for path in (CONFIG / 'state.json', CONFIG / 'common-profile.json', exported)}
    rejected = command(['bash', ROOT / 'install.sh', '--endpoint', '8.8.8.8', '--port', '29527'], False)
    require('已有配置' in rejected.stderr, 'Repeat installation did not explain existing state')
    require(all(digest(path) == value for path, value in before.items()), 'Repeat installation reset existing state')
    print('PASS repeat installation rejects existing configuration without resetting it')


if __name__ == '__main__':
    main()
