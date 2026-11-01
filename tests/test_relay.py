import base64
import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid
import zipfile
import relayctl as r
from scripts import package as packaging

KEY=base64.b64encode(bytes(range(32))).decode()
class FakeRunner:
    def __init__(self):
        self.calls=[]; self.ports=set(); self.fail_add=False; self.revoked=[]
    def run(self, args, data=None, check=True):
        args=list(map(str,args));self.calls.append(args)
        out='';code=0
        if 'firewall-cmd' in args:
            if '--state' in args:out='running'
            elif any(x.startswith('--query-port=') for x in args):
                key=('--permanent' in args,next(x for x in args if x.startswith('--query-port=')).split('=',1)[1]);code=0 if key in self.ports else 1
            elif any(x.startswith('--add-port=') for x in args):
                key=('--permanent' in args,next(x for x in args if x.startswith('--add-port=')).split('=',1)[1]);code=1 if self.fail_add else 0
                if not code:self.ports.add(key)
            elif any(x.startswith('--remove-port=') for x in args):
                key=('--permanent' in args,next(x for x in args if x.startswith('--remove-port=')).split('=',1)[1]);self.ports.discard(key)
            else:out='public'
        elif args[:4]==['ip','-4','route','get']:out='1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.2'
        elif 'is-active' in args:out='inactive'
        elif args[0].endswith('/wg'):out=KEY
        elif 'easytier-cli' in args[0]:
            if 'generate' in args:out=json.dumps(dict(credential_id=args[args.index('--credential-id')+1],credential_secret=KEY))
            elif 'revoke' in args:self.revoked.append(args[-1]);out='{}'
            else:out='{}'
        result=subprocess.CompletedProcess(args,code,out,'')
        if code and check:raise r.RelayError('fixture command failed')
        return result

class RelayTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.p=r.Paths(Path(self.temp.name));self.runner=FakeRunner();self.relay=r.Relay(self.p,self.runner)
        self.state=r.settings('8.8.8.8');self.state.update(instance_id=str(uuid.uuid4()),network_name='civ6-test',network_secret='master-secret',private_key=KEY,public_key=KEY,phase='ready',wan_zone='public')
        self.relay.save(self.state)
    def tearDown(self):self.temp.cleanup()
    def test_routes_and_relay_have_no_exit(self):
        config=r.server_config(self.state)
        self.assertIn('no_tun = true',config);self.assertIn('enable_exit_node = false',config);self.assertIn('accept_dns = false',config)
        self.assertIn('routes = []',config);self.assertNotIn('0.0.0.0/0',config)
        with self.assertRaises(r.RelayError):r.settings('8.8.8.8',network='0.0.0.0/0')
    def test_independent_profiles_and_zip_have_no_server_or_master_secret(self):
        a=self.relay.add('alice');b=self.relay.add('bob')
        self.assertEqual((a['client_ip'],b['client_ip']),('10.77.77.2','10.77.77.3'))
        self.assertNotEqual(a['credential_id'],b['credential_id'])
        for profile in (a,b):
            self.assertNotIn('endpoint',profile);self.assertNotIn('port',profile);self.assertNotIn('network_secret',profile)
        folder=self.p.program/'client/windows';folder.mkdir(parents=True);(folder/'README.txt').write_text('Instructions')
        with zipfile.ZipFile(str(self.p.program/'client/windows-template.zip'),'w') as z:z.writestr('README.txt','Instructions')
        self.p.exports.mkdir()
        archive=self.relay.bundle('alice')
        self.assertEqual(archive.stat().st_mode&0o777,0o600)
        with zipfile.ZipFile(str(archive)) as z:
            self.assertIn('README.txt',z.namelist());self.assertEqual(json.loads(z.read('profile.json'))['player'],'alice')
        with self.assertRaises(r.RelayError):self.relay.bundle('alice')
    def test_common_bundle_reuses_one_access_key_and_contains_no_device_identity(self):
        self.p.exports.mkdir()
        (self.p.program/'client').mkdir(parents=True)
        with zipfile.ZipFile(str(self.p.program/'client/windows-template.zip'),'w') as z:
            z.writestr('README.txt','Common client')
        first=self.relay.common_profile();second=self.relay.common_profile()
        self.assertEqual(first,second)
        self.assertEqual(first['schema'],4)
        self.assertEqual(first['access_mode'],'shared')
        for field in ('instance_id','client_ip','player','endpoint','port','network_secret'):
            self.assertNotIn(field,first)
        calls=[c for c in self.runner.calls if 'generate' in c]
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0][calls[0].index('--reusable')+1],'true')
        archive=self.relay.bundle()
        with zipfile.ZipFile(str(archive)) as z:
            self.assertEqual(json.loads(z.read('profile.json')),first)
        self.assertEqual(archive.name,'windows.zip')
        self.assertEqual(archive.stat().st_mode&0o777,0o600)
    def test_live_revoke_preserves_other_credential(self):
        a=self.relay.add('alice');self.relay.add('bob');self.relay.revoke('alice')
        state=self.relay.load();self.assertNotIn('alice',state['clients']);self.assertIn('bob',state['clients'])
        self.assertEqual(self.runner.revoked,[a['credential_id']]);self.assertFalse((self.p.clients/'alice.json').exists())
    def test_firewall_ownership_preserves_existing_security(self):
        self.runner.ports={(True,'22/tcp'),(False,'22/tcp'),(True,'51820/udp')}
        original=self.runner.ports.copy()
        self.relay.setup_firewall(self.state)
        self.assertEqual(len(self.state['firewall_owned']),3)
        self.relay.uninstall(self.state)
        self.assertEqual(self.runner.ports,original)
        calls=' '.join(' '.join(c) for c in self.runner.calls)
        for forbidden in ('--reload','--panic','sysctl','iptables','auditd','sshd'):
            self.assertNotIn(forbidden,calls)
    def test_failed_firewall_add_remains_recoverable(self):
        self.runner.fail_add=True
        with self.assertRaises(r.RelayError):self.relay.setup_firewall(self.state)
        self.assertEqual(len(self.relay.load()['firewall_owned']),1)
    def test_invalid_legacy_state_and_exhaustion(self):
        self.state['marker']='civ6-relay/v2';self.relay.save(self.state)
        with self.assertRaises(r.RelayError):self.relay.load()
        self.state['clients']={str(i):{'ip':'10.77.77.'+str(i)} for i in range(2,255)}
        with self.assertRaises(r.RelayError):r.next_address(self.state)
    def test_add_failure_revokes_created_credential(self):
        with patch.object(r,'atomic_write',side_effect=OSError('disk full')):
            with self.assertRaises(OSError):self.relay.add('alice')
        self.assertEqual(len(self.runner.revoked),1)
        self.assertNotIn('alice',self.relay.load()['clients'])

class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        for directory,names in [
                ('vendor/easytier/linux-x86_64',['easytier-core','easytier-cli']),
                ('vendor/easytier/windows-x86_64',['easytier-core.exe','easytier-cli.exe','wintun.dll','WinDivert64.sys']),
                ('vendor/linux-amd64',['wg'])]:
            folder=self.root/directory;folder.mkdir(parents=True)
            hashes={}
            for name in names:
                data=('public-fixture-'+name).encode();(folder/name).write_bytes(data)
                hashes[name]=hashlib.sha256(data).hexdigest()
            (folder/'checksums.json').write_text(json.dumps(hashes))
        for name in ('relayctl.py','install.sh','README.md','client/windows/Start.cmd',
                'client/windows/Civ6Relay.ps1','client/windows/LiveMonitor.cs','client/windows/README.txt',
                'client/launcher/src/main.rs',
                'vendor/easytier/licenses/LICENSE.txt','vendor/linux-amd64/licenses/LICENSE.txt',
                'vendor/sources/wireguard-tools.tar.xz','build/source.txt','scripts/source.py',
                'tests/source.py','docs/guide.md'):
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('public source fixture')
        self.launcher=b'MZ\x00\x80\xffpublic-launcher-fixture'
        (self.root/'client/windows/Civ6Relay.exe').write_bytes(self.launcher)
        self.desktop={
            'Desktop.ps1':b'\xef\xbb\xbf# desktop script fixture\r\n',
            'Desktop.xaml':'<Window Title="联机助手" />\r\n'.encode('utf-8'),
            'DesktopModel.cs':b'// desktop model fixture\r\n',
        }
        for name,data in self.desktop.items():(self.root/'client/windows'/name).write_bytes(data)
        self.marker='dummy-private-package-marker'
        for name in ('.git/private.txt','.build/common-profile.json'):
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(self.marker)

    def tearDown(self):self.temp.cleanup()

    def package(self,*arguments):
        output=io.StringIO()
        with patch.object(packaging,'ROOT',self.root),patch.object(sys,'argv',['package.py']+list(arguments)),contextlib.redirect_stdout(output):
            packaging.main()
        self.assertNotIn(self.marker,output.getvalue())
        return output.getvalue()

    def test_public_release_has_template_and_fresh_checksums_without_touching_private_dist(self):
        private=self.root/'dist'/('civ6-relay-client-'+packaging.VERSION+'-windows.zip')
        private.parent.mkdir();private.write_text(self.marker)
        output=self.root/'release-public'
        output.mkdir();(output/'SHA256SUMS.json').write_text('{"stale-private.zip":"old"}')
        self.package('--output-dir',str(output))
        server=output/('civ6-relay-server-'+packaging.VERSION+'-linux-amd64.tar.gz')
        template=output/('civ6-relay-client-'+packaging.VERSION+'-windows-template.zip')
        hashes=json.loads((output/'SHA256SUMS.json').read_text())
        self.assertEqual(set(hashes),{server.name,template.name})
        for path in (server,template):self.assertEqual(hashes[path.name],hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(private.read_text(),self.marker)
        with zipfile.ZipFile(template) as archive:
            self.assertIn('LiveMonitor.cs',archive.namelist());self.assertIn('bin/easytier-core.exe',archive.namelist())
            self.assertEqual(archive.read('Civ6Relay.exe'),self.launcher)
            for name,data in self.desktop.items():self.assertEqual(archive.read(name),data)
            self.assertNotIn('profile.json',archive.namelist())
            self.assertNotIn(self.marker.encode(),b''.join(archive.read(name) for name in archive.namelist()))
        with tarfile.open(server) as archive:
            self.assertIn('civ6-relay/client/windows/LiveMonitor.cs',archive.getnames())
            self.assertIn('civ6-relay/client/launcher/src/main.rs',archive.getnames())
            self.assertEqual(archive.extractfile('civ6-relay/client/windows/Civ6Relay.exe').read(),self.launcher)
            for name,data in self.desktop.items():
                self.assertEqual(archive.extractfile('civ6-relay/client/windows/'+name).read(),data)
            for name in archive.getnames():
                self.assertFalse(any(part in ('.git','.build','profile.json','state.json','preferences.json') for part in Path(name).parts))

    def test_profile_mode_preserves_private_name_and_permissions(self):
        self.package()
        template=self.root/'dist'/('civ6-relay-client-'+packaging.VERSION+'-windows-template.zip')
        original_template=template.read_bytes()
        profile=self.root/'common-profile.json'
        profile.write_text(json.dumps(dict(schema=4,access_mode='shared',credential_secret=self.marker)))
        self.package('--profile',str(profile))
        output=self.root/'dist'
        common=output/('civ6-relay-client-'+packaging.VERSION+'-windows.zip')
        self.assertEqual(common.stat().st_mode&0o777,0o600)
        self.assertEqual(template.read_bytes(),original_template)
        with zipfile.ZipFile(common) as archive:
            saved=json.loads(archive.read('profile.json'))
            self.assertEqual(saved['credential_secret'],self.marker);self.assertEqual(saved['version'],packaging.VERSION)
            self.assertIn('LiveMonitor.cs',archive.namelist())
            self.assertEqual(archive.read('Civ6Relay.exe'),self.launcher)
            for name,data in self.desktop.items():self.assertEqual(archive.read(name),data)
        base=self.root/'.build'/('civ6-relay-client-'+packaging.VERSION+'-windows-base.zip')
        with zipfile.ZipFile(base) as archive:
            self.assertNotIn('profile.json',archive.namelist())
            self.assertEqual(archive.read('Civ6Relay.exe'),self.launcher)
            for name,data in self.desktop.items():self.assertEqual(archive.read(name),data)
        self.assertEqual(set(json.loads((output/'SHA256SUMS.json').read_text())),{
            common.name,'civ6-relay-server-'+packaging.VERSION+'-linux-amd64.tar.gz'})

    def test_private_source_files_are_rejected_before_archiving(self):
        for name in ('profile.json','common-profile.json','state.json','preferences.json'):
            with self.subTest(name=name):
                path=self.root/'client/windows'/name;path.write_text(self.marker)
                try:
                    with self.assertRaisesRegex(SystemExit,'Unexpected private/generated file'):
                        self.package('--output-dir',str(self.root/'public'))
                    self.assertEqual(list((self.root/'public').iterdir()),[])
                finally:path.unlink()

    def test_missing_launcher_is_rejected_before_archiving(self):
        (self.root/'client/windows/Civ6Relay.exe').unlink()
        output=self.root/'public'
        with self.assertRaisesRegex(SystemExit,'Windows launcher missing'):
            self.package('--output-dir',str(output))
        self.assertFalse(output.exists())

    def test_missing_desktop_runtime_is_rejected_before_archiving(self):
        output=self.root/'public'
        for name,data in self.desktop.items():
            with self.subTest(name=name):
                path=self.root/'client/windows'/name;path.unlink()
                try:
                    with self.assertRaisesRegex(SystemExit,'Windows desktop runtime missing: '+name):
                        self.package('--output-dir',str(output))
                    self.assertFalse(output.exists())
                finally:path.write_bytes(data)

    def test_packet_dependency_is_rejected_before_archiving(self):
        (self.root/'vendor/easytier/windows-x86_64/Packet.dll').write_text('excluded dependency fixture')
        with self.assertRaisesRegex(SystemExit,'Unsupported bundled dependency: Packet.dll'):
            self.package('--output-dir',str(self.root/'public'))
        self.assertEqual(list((self.root/'public').iterdir()),[])

    def test_output_cannot_be_recursively_packaged_as_source(self):
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit) as error:
            self.package('--output-dir',str(self.root/'client/windows/releases'))
        self.assertEqual(error.exception.code,2)
        self.assertFalse((self.root/'client/windows/releases').exists())

if __name__=='__main__':unittest.main()
