import base64
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import socket
from pathlib import Path
import sys
import subprocess
import tempfile
import threading
import time
import unittest
import uuid

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import keyservice as access


class FakeMesh:
    def __init__(self):
        self.started, self.revoked, self.stopped = [], [], []
        self.fail_grant = False

    def ensure(self,room):
        self.started.append(dict(room))

    def grant(self,room,remaining):
        if self.fail_grant:
            raise RuntimeError('fixture provisioning failure')
        return dict(schema=4,version=access.relay.VERSION,backend='easytier',routing_mode='lan-mesh',
            engine_version=access.relay.ENGINE_VERSION,access_mode='shared',network_name='civ6-'+room['id'],
            network=room['network'],mtu=1360,server_public_key=base64.b64encode(bytes(range(32))).decode(),
            credential_id=str(uuid.uuid4()),credential_secret=base64.b64encode(bytes(range(32))).decode(),
            client_public_key=base64.b64encode(bytes(range(32))).decode(),expires_at=room['expires_at'])

    def revoke(self,room,credential):
        self.revoked.append((room['id'],credential))

    def stop(self,room):
        self.stopped.append(room['id'])

    def close(self):
        pass


class KeyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.time = 2000000000
        self.backend = FakeMesh()
        self.config = dict(key_required=True,endpoint='8.8.8.8',hours=48,max_rooms=2,max_players=2,
                           keys_per_minute=10,lease_seconds=180,renew_seconds=30)
        self.service = access.KeyService(self.config,self.root,self.backend,lambda:self.time)

    def tearDown(self):
        self.service.close()
        self.temp.cleanup()

    def key(self):
        return self.service.generate('192.0.2.1',str(uuid.uuid4()))['key']

    def join(self,key,device=None):
        return self.service.join(key,device or str(uuid.uuid4()))

    def assert_code(self,code,call):
        with self.assertRaises(access.AccessError) as error:
            call()
        self.assertEqual(error.exception.code,code)

    def test_key_comes_from_server_and_does_not_activate_or_start_a_mesh(self):
        result=self.service.generate('192.0.2.1',str(uuid.uuid4()))
        self.assertTrue(result['key'].startswith('C6-'))
        self.assertIsNone(result['expires_at'])
        self.assertEqual(self.backend.started,[])
        self.assertNotIn(result['key'].encode(),(self.root/'access.sqlite').read_bytes())
        self.assertEqual((self.root/'access.sqlite').stat().st_mode & 0o777,0o600)

    def test_shared_key_same_room_independent_keys_and_other_groups_are_isolated(self):
        key=self.key()
        a=self.join(key)
        b=self.join(key.lower().replace('-',' '))
        other=self.join(self.key())
        self.assertEqual(a['profile']['network_name'],b['profile']['network_name'])
        self.assertEqual(a['expires_at'],b['expires_at'])
        self.assertNotEqual(a['profile']['credential_id'],b['profile']['credential_id'])
        self.assertNotEqual(a['profile']['network_name'],other['profile']['network_name'])
        self.assertNotEqual(a['port'],other['port'])
        self.assertNotEqual(a['profile']['network'],other['profile']['network'])

    def test_first_use_starts_48_hours_and_reconnect_does_not_extend_it(self):
        key=self.key()
        self.time+=300
        device=str(uuid.uuid4())
        first=self.join(key,device)
        self.assertEqual(first['expires_at'],self.time+48*3600)
        self.time+=60
        again=self.join(key,device)
        self.assertEqual(first['expires_at'],again['expires_at'])
        self.assertEqual(first['profile']['credential_id'],again['profile']['credential_id'])
        self.assert_code('SESSION_EXPIRED',lambda:self.service.renew(first['session_token']))
        self.assertEqual(self.service.renew(again['session_token'])['expires_at'],first['expires_at'])

    def test_missing_invalid_and_expired_keys_do_not_allow_connection(self):
        self.assert_code('KEY_REQUIRED',lambda:self.join(''))
        self.assert_code('INVALID_KEY',lambda:self.join('not-issued'))
        key=self.key()
        session=self.join(key)
        self.time=session['expires_at']
        self.assert_code('KEY_EXPIRED',lambda:self.join(key))
        self.assert_code('SESSION_EXPIRED',lambda:self.service.renew(session['session_token']))
        self.assertEqual(len(self.backend.stopped),1)
        self.assertEqual(self.service.db.execute('SELECT count(*) FROM sessions').fetchone()[0],0)

    def test_concurrent_shared_key_enforces_online_limit_and_release_frees_a_place(self):
        key=self.key()
        def connect(_):
            try:return self.join(key)
            except access.AccessError as error:return error.code
        with ThreadPoolExecutor(max_workers=6) as executor:
            results=list(executor.map(connect,range(6)))
        admitted=[x for x in results if isinstance(x,dict)]
        self.assertEqual(len(admitted),2)
        self.assertEqual(results.count('ROOM_FULL'),4)
        self.service.release(admitted[0]['session_token'])
        self.join(key)
        self.assertEqual(len(self.backend.revoked),1)

    def test_lost_client_lease_releases_seat_and_revokes_the_mesh_credential(self):
        key=self.key()
        first=self.join(key)
        deadline=first['expires_at']
        self.time+=181
        self.service.maintain()
        self.assertEqual(self.backend.revoked[0][1],first['profile']['credential_id'])
        self.assert_code('SESSION_EXPIRED',lambda:self.service.renew(first['session_token']))
        self.assertEqual(self.join(key)['expires_at'],deadline)

    def test_full_server_does_not_activate_another_key_and_reuses_expired_capacity(self):
        self.join(self.key())
        old=self.join(self.key())
        next_key=self.key()
        self.assert_code('SERVER_FULL',lambda:self.join(next_key))
        self.assertEqual(self.service.db.execute('SELECT count(*) FROM rooms WHERE activated_at IS NULL').fetchone()[0],1)
        self.time=old['expires_at']
        self.assertEqual(self.join(next_key)['port'],20000)

    def test_failed_first_grant_keeps_key_unactivated(self):
        key=self.key()
        self.backend.fail_grant=True
        with self.assertRaises(RuntimeError):self.join(key)
        row=self.service.db.execute('SELECT activated_at,port FROM rooms').fetchone()
        self.assertEqual(tuple(row),(None,None))
        self.backend.fail_grant=False
        self.time+=600
        self.assertEqual(self.join(key)['expires_at'],self.time+48*3600)

    def test_restart_retains_key_deadline_and_session_and_recovers_room(self):
        key=self.key()
        session=self.join(key)
        self.service.close()
        self.service=access.KeyService(self.config,self.root,self.backend,lambda:self.time)
        self.service.recover()
        renewed=self.service.renew(session['session_token'])
        self.assertEqual(renewed['expires_at'],session['expires_at'])
        self.assertTrue(self.backend.started)

    def test_another_daemon_cannot_share_the_same_database_and_room_ports(self):
        self.assert_code('ALREADY_RUNNING',lambda:access.KeyService(self.config,self.root,self.backend))

    def test_self_hosted_free_mode_connects_with_no_key_or_key_mode_message(self):
        room=dict(id=uuid.uuid4().hex,network='10.77.77.0/24',expires_at=self.time+365*86400)
        profile=self.backend.grant(room,365*86400)
        (self.root/'free-profile.json').write_text(json.dumps(profile))
        self.config.update(key_required=False,free_mesh_port=9527)
        result=self.join('')
        self.assertEqual(result['profile'],profile)
        self.assertEqual(result['port'],9527)
        self.assertNotIn('key_required',result)
        self.assertNotIn('session_token',result)
        self.assertEqual(self.backend.started,[])
        issued=self.service.generate('192.0.2.1',str(uuid.uuid4()))
        self.assertIsNone(issued['key'])
        self.assertEqual(issued['message'],'此服务器无需 Key。')
        self.config.pop('key_required')
        self.assertEqual(self.join('')['profile'],profile)
        self.assertIsNone(self.service.generate('192.0.2.1',str(uuid.uuid4()))['key'])

    def test_generation_rate_limit_and_disabled_generation(self):
        self.config['keys_per_minute']=1
        self.key()
        self.assert_code('RATE_LIMITED',lambda:self.key())
        self.time+=61
        self.key()
        self.config['allow_generate']=False
        self.assert_code('GENERATION_DISABLED',lambda:self.key())

    def test_actual_http_generate_and_connect_require_only_one_connect_request(self):
        server=access.ApiServer(('127.0.0.1',0),self.service)
        worker=threading.Thread(target=lambda:server.serve_forever(poll_interval=.01),daemon=True)
        worker.start()
        def post(path,body):
            conn=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            conn.request('POST',path,json.dumps(body),{'Content-Type':'application/json'})
            response=conn.getresponse()
            value=json.loads(response.read().decode())
            conn.close()
            return response.status,value
        try:
            status,missing=post('/v1/connect',dict(device_id=str(uuid.uuid4())))
            self.assertEqual((status,missing['error']),(401,'KEY_REQUIRED'))
            status,issued=post('/v1/keys',dict(device_id=str(uuid.uuid4())))
            self.assertEqual(status,200)
            status,connected=post('/v1/connect',dict(device_id=str(uuid.uuid4()),key=issued['key']))
            self.assertEqual(status,200)
            self.assertIn('profile',connected)
            self.assertNotIn('key_required',connected)
        finally:
            server.shutdown();server.server_close();worker.join(timeout=3)

    def test_room_counts_include_only_activated_unexpired_rooms_without_mutating_them(self):
        keys = [self.key() for _ in range(3)]
        self.assertEqual(self.service.room_counts()['active_rooms'],0)
        self.join(keys[0])
        self.join(keys[1])
        counts = self.service.room_counts()
        self.assertEqual((counts['active_rooms'],counts['max_rooms'],counts['available_rooms']),(2,2,0))
        self.config['max_rooms'] = 1
        self.assertEqual(self.service.room_counts()['available_rooms'],0)
        events = len(self.backend.started), len(self.backend.stopped)
        self.time += 48*3600
        self.assertEqual(self.service.room_counts()['active_rooms'],0)
        self.assertEqual((len(self.backend.started),len(self.backend.stopped)),events)
        self.config['key_required'] = False
        counts = self.service.room_counts()
        self.assertEqual((counts['active_rooms'],counts['max_rooms'],counts['available_rooms']),(1,1,0))

    def test_version_http_is_public_in_free_and_key_modes_without_creating_access(self):
        server=access.ApiServer(('127.0.0.1',0),self.service)
        worker=threading.Thread(target=lambda:server.serve_forever(poll_interval=.01),daemon=True)
        worker.start()
        def get(path):
            conn=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            try:
                conn.request('GET',path)
                response=conn.getresponse()
                return response.status,json.loads(response.read().decode()),response.getheader('Cache-Control')
            finally:
                conn.close()
        try:
            for enabled in (True,False):
                self.config['key_required']=enabled
                status,result,cache=get('/v1/version')
                self.assertEqual(status,200)
                self.assertEqual(result,dict(server_version=access.relay.VERSION,
                    engine_version=access.relay.ENGINE_VERSION,api_version=1))
                self.assertEqual(cache,'no-store')
                status,counts,_=get('/v1/rooms')
                self.assertEqual(status,200)
                self.assertEqual(counts,dict(active_rooms=0 if enabled else 1,
                    max_rooms=2 if enabled else 1,available_rooms=2 if enabled else 0,
                    sampled_at=self.time,refresh_after_seconds=10))
                status,load,_=get('/v1/load')
                self.assertEqual(status,200)
                self.assertEqual(set(load),{'sampled_at','refresh_after_seconds','sample_seconds',
                    'cpu_percent','memory_total_bytes','memory_used_bytes','memory_percent',
                    'network_interface','network_rx_bps','network_tx_bps'})
                self.assertEqual(load['refresh_after_seconds'],10)
            status,result,_=get('/v2/version')
            self.assertEqual((status,result['error']),(404,'NOT_FOUND'))
            self.assertEqual(self.service.db.execute('SELECT count(*) FROM rooms').fetchone()[0],0)
            self.assertEqual(self.service.db.execute('SELECT count(*) FROM sessions').fetchone()[0],0)
            self.assertEqual(self.backend.started,[])
        finally:
            server.shutdown();server.server_close();worker.join(timeout=3)


class CliDefaultsTests(unittest.TestCase):
    def test_public_http_entrypoint_serves_free_and_key_modes_without_certificates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            profile=root/'common-profile.json'
            profile.write_text(json.dumps(dict(schema=4,access_mode='shared',expires_at=int(time.time())+3600)))
            for enabled in (False,True):
                state=root/('key' if enabled else 'free')
                command=[sys.executable,str(Path(access.__file__)),'--state-dir',str(state)]
                args=command+['init','--endpoint','8.8.8.8','--free-profile',str(profile)]
                if enabled:args.append('--enable-key')
                subprocess.run(args,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=5)
                with socket.socket() as probe:
                    probe.bind(('127.0.0.1',0));port=probe.getsockname()[1]
                process=subprocess.Popen(command+['serve','--listen','0.0.0.0','--port',str(port)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
                def request(path,body=None):
                    connection=http.client.HTTPConnection('127.0.0.1',port,timeout=1)
                    try:
                        connection.request('GET' if body is None else 'POST',path,
                            None if body is None else json.dumps(body),{'Content-Type':'application/json'})
                        response=connection.getresponse()
                        return response.status,json.loads(response.read().decode())
                    finally:connection.close()
                try:
                    for attempt in range(50):
                        self.assertIsNone(process.poll(),'HTTP service exited before listening')
                        try:
                            status,result=request('/v1/version');break
                        except OSError:time.sleep(.05)
                    else:self.fail('HTTP service did not start')
                    self.assertEqual((status,result['server_version']),(200,access.relay.VERSION))
                    status,result=request('/v1/keys',dict(device_id=str(uuid.uuid4())))
                    self.assertEqual(status,200)
                    self.assertEqual(bool(result['key']),enabled)
                    if not enabled:
                        status,result=request('/v1/connect',dict(device_id=str(uuid.uuid4())))
                        self.assertEqual((status,result['port']),(200,9527))
                        self.assertNotIn('session_token',result)
                finally:
                    process.terminate()
                    try:process.wait(timeout=5)
                    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
                    process.stderr.close()

    def test_init_defaults_to_free_and_requires_explicit_key_enable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            profile=root/'common-profile.json'
            profile.write_text(json.dumps(dict(schema=4,access_mode='shared')))
            for enabled in (False,True):
                state=root/('key' if enabled else 'free')
                args=[sys.executable,str(Path(access.__file__)),'--state-dir',str(state),
                      'init','--endpoint','8.8.8.8','--free-profile',str(profile)]
                if enabled:args.append('--enable-key')
                result=subprocess.run(args,capture_output=True,text=True,timeout=5)
                self.assertEqual(result.returncode,0,result.stderr)
                config=json.loads((state/'service.json').read_text())
                self.assertEqual(config['key_required'],enabled)
                self.assertEqual(config['allow_generate'],True)
                self.assertEqual(json.loads((state/'free-profile.json').read_text())['schema'],4)


if __name__=='__main__':
    unittest.main()
