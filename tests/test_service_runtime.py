import http.client
import json
import os
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

import relayctl as relay

ROOT=Path(__file__).resolve().parents[1]
CORE=ROOT/'vendor/easytier/linux-x86_64/easytier-core'


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1',0))
        return probe.getsockname()[1]


def core_children(pid):
    tasks=Path('/proc')/str(pid)/'task'
    result=[]
    children=set()
    if tasks.exists():
        for task in tasks.iterdir():
            try:
                children.update((task/'children').read_text().split())
            except OSError:
                pass
    for child in children:
        try:
            arguments=(Path('/proc')/child/'cmdline').read_bytes().split(b'\0')
            if any(Path(os.fsdecode(value)).name=='easytier-core' for value in arguments if value):
                result.append(int(child))
        except OSError:
            pass
    return result


@unittest.skipUnless(sys.platform=='linux' and CORE.is_file(),'Requires bundled Linux core')
class ServiceRuntimeTests(unittest.TestCase):
    def run_service(self, required):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);binary=folder/'bin';binary.mkdir()
            for name,source in (('easytier-core',CORE),('easytier-cli',CORE.with_name('easytier-cli')),
                                ('wg',ROOT/'vendor/linux-amd64/wg')):
                (binary/name).symlink_to(source)
            mesh_port=free_port();api_port=free_port()
            state=relay.settings('8.8.8.8',port=mesh_port,api_port=api_port,key_required=required,max_rooms=2)
            private=subprocess.check_output([str(binary/'wg'),'genkey'],text=True).strip()
            public=subprocess.check_output([str(binary/'wg'),'pubkey'],input=private+'\n',text=True).strip()
            state.update(instance_id=str(uuid.uuid4()),network_name='runtime-'+uuid.uuid4().hex,
                network_secret=uuid.uuid4().hex,private_key=private,public_key=public,phase='ready')
            (folder/'state.json').write_text(json.dumps(state))
            config=relay.server_config(state).replace('/etc/civ6-relay/credentials.json',str(folder/'credentials.json'))
            (folder/'server.toml').write_text(config)
            (folder/'service.json').write_text(json.dumps(dict(endpoint='8.8.8.8',bin_dir=str(binary),
                listen='0.0.0.0',api_port=api_port,key_required=required,max_rooms=2,keys_per_minute=10,
                free_mesh_port=mesh_port,free_profile=str(folder/'common-profile.json'),shared_config=str(folder/'server.toml'))))
            process=subprocess.Popen([sys.executable,str(ROOT/'keyservice.py'),'--state-dir',str(folder),'serve'],
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            children=[]
            def request(path,body=None,token='',status=200):
                connection=http.client.HTTPConnection('127.0.0.1',api_port,timeout=3)
                try:
                    headers={'Content-Type':'application/json'}
                    if token:headers['Authorization']='Bearer '+token
                    connection.request('GET' if body is None else 'POST',path,
                        None if body is None else json.dumps(body),headers)
                    response=connection.getresponse()
                    value=json.loads(response.read().decode())
                    self.assertEqual(response.status,status,value.get('error'))
                    return value
                finally:connection.close()
            def post(path,**fields):
                body=dict(device_id=str(uuid.uuid4()));body.update(fields)
                return request(path,body)
            def instances():
                value=subprocess.check_output([str(binary/'easytier-cli'),'-p',
                    '127.0.0.1:'+str(relay.RPC_PORT),'-o','json','instance','list'],
                    text=True,stderr=subprocess.DEVNULL,timeout=3)
                return {uuid.UUID(value).hex for value in json.loads(value)['instances']}
            try:
                for attempt in range(100):
                    self.assertIsNone(process.poll(),'Unified service exited during startup')
                    try:
                        version=request('/v1/version');break
                    except OSError:time.sleep(.1)
                else:self.fail('Unified HTTP service did not become ready')
                self.assertEqual(version['server_version'],relay.VERSION)
                if required:
                    self.assertEqual(core_children(process.pid),[])
                    a=post('/v1/keys')['key'];b=post('/v1/keys')['key']
                    self.assertEqual(core_children(process.pid),[])
                    first_device=str(uuid.uuid4())
                    first=post('/v1/connect',key=a,device_id=first_device)
                    children=core_children(process.pid)
                    self.assertEqual(len(children),1)
                    original=children[0]
                    friend=post('/v1/connect',key=a)
                    other=post('/v1/connect',key=b)
                    self.assertEqual(first['port'],friend['port'])
                    self.assertEqual(first['profile']['network_name'],friend['profile']['network_name'])
                    self.assertNotEqual(first['port'],other['port'])
                    self.assertNotEqual(first['profile']['server_public_key'],other['profile']['server_public_key'])
                    children=core_children(process.pid)
                    self.assertEqual(children,[original])
                    self.assertEqual(len(instances()),2)
                    os.kill(original,signal.SIGKILL)
                    for attempt in range(100):
                        children=core_children(process.pid)
                        try:
                            if len(children)==1 and children[0]!=original and len(instances())==2:break
                        except (subprocess.SubprocessError,OSError):pass
                        time.sleep(.1)
                    else:self.fail('Single core did not restore both rooms')
                    recovered=children[0]
                    again=post('/v1/connect',key=a,device_id=first_device)
                    self.assertEqual(again['profile']['credential_id'],first['profile']['credential_id'])
                    first_id=first['profile']['network_name'][len('civ6-'):]
                    other_id=other['profile']['network_name'][len('civ6-'):]
                    with sqlite3.connect(str(folder/'access.sqlite')) as database:
                        database.execute('UPDATE rooms SET expires_at=? WHERE id=?',(int(time.time())-1,first_id))
                    request('/v1/renew',{},other['session_token'])
                    self.assertEqual(instances(),{other_id})
                    self.assertEqual(core_children(process.pid),[recovered])
                    self.assertEqual(request('/v1/connect',{'key':a,'device_id':first_device},status=403)['error'],'KEY_EXPIRED')
                    replacement=post('/v1/connect',key=post('/v1/keys')['key'])
                    self.assertEqual(replacement['port'],first['port'])
                    self.assertNotEqual(replacement['profile']['network_name'],first['profile']['network_name'])
                    self.assertEqual(len(instances()),2)
                    self.assertEqual(core_children(process.pid),[recovered])
                    with sqlite3.connect(str(folder/'access.sqlite')) as database:
                        database.execute('UPDATE rooms SET expires_at=? WHERE port IS NOT NULL',(int(time.time())-1,))
                    fresh=post('/v1/keys')['key']
                    self.assertEqual(instances(),set())
                    self.assertEqual(core_children(process.pid),[recovered])
                    post('/v1/connect',key=fresh)
                    self.assertEqual(len(instances()),1)
                    self.assertEqual(core_children(process.pid),[recovered])
                else:
                    self.assertIsNone(post('/v1/keys')['key'])
                    first=post('/v1/connect')
                    self.assertEqual(first['port'],mesh_port)
                    children=core_children(process.pid)
                    self.assertEqual(len(children),1)
                    previous=children[0]
                    os.kill(previous,signal.SIGKILL)
                    for attempt in range(80):
                        children=core_children(process.pid)
                        if len(children)==1 and children[0]!=previous:break
                        time.sleep(.1)
                    else:self.fail('Shared core did not restart')
                    self.assertEqual(post('/v1/connect')['profile']['credential_id'],first['profile']['credential_id'])
            finally:
                process.send_signal(signal.SIGINT)
                try:process.wait(timeout=15)
                except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
                for pid in children:
                    self.assertFalse(Path('/proc',str(pid)).exists(),'Managed core survived the parent shutdown')

    def test_free_http_service_owns_and_recovers_shared_core(self):
        self.run_service(False)

    def test_key_rooms_share_one_core_with_independent_lifecycle_and_recovery(self):
        self.run_service(True)
