#!/usr/bin/env python3
"""Server Key access and isolated mesh rooms (Python 3.6+).

Only connection management uses HTTP; game packets stay in EasyTier.
"""
import argparse
import base64
from collections import defaultdict, deque
import fcntl
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import ipaddress
import json
import os
from pathlib import Path
import secrets
import signal
import socketserver
import sqlite3
import subprocess
import threading
import time
import uuid

import relayctl as relay


class AccessError(Exception):
    def __init__(self, code, message, status=400):
        self.code, self.message, self.status = code, message, status
        super().__init__(message)


def digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def normalized_key(value):
    return str(value or '').replace('-', '').replace(' ', '').upper()


def device_id(value):
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        raise AccessError('INVALID_DEVICE', '客户端身份无效，请重新启动客户端。')


class MeshRooms:
    """Manage isolated network instances in one core process."""
    def __init__(self, config, root, runner=None):
        self.config, self.root = config, Path(root)
        self.runner = runner or relay.Runner()
        self.process = None
        self.instances = set()
        self.shared_id = None
        self.bin = Path(config['bin_dir'])

    def paths(self, room):
        return self.root / 'rooms' / room['id']

    def state(self, room):
        path = self.paths(room) / 'state.json'
        if path.is_file():
            return json.loads(path.read_text(encoding='utf-8'))
        private = self.runner.run([self.bin / 'wg', 'genkey']).stdout.strip()
        public = self.runner.run([self.bin / 'wg', 'pubkey'], data=private+'\n').stdout.strip()
        state = dict(instance_id=room['id'], network_name='civ6-'+room['id'],
            network_secret=secrets.token_urlsafe(32), private_key=private, public_key=public,
            port=room['port'], network=room['network'], mtu=1360)
        relay.atomic_write(path, json.dumps(state))
        return state

    def cli(self, room, *args):
        result = self.runner.run([self.bin / 'easytier-cli', '-p',
            '127.0.0.1:'+str(relay.RPC_PORT), '-i', room['id'], '-o', 'json']+list(args))
        return json.loads(result.stdout)

    def manage(self, *args):
        result = self.runner.run([self.bin / 'easytier-cli', '-p',
            '127.0.0.1:'+str(relay.RPC_PORT), '-o', 'json', 'instance']+list(args))
        return json.loads(result.stdout)

    def ensure(self, room):
        self.start()
        identifier = uuid.UUID(room['id']).hex
        if identifier in self.instances:
            return
        state = self.state(room)
        folder = self.paths(room)
        config = relay.server_config(state).replace(
            relay.toml_string('/etc/civ6-relay/credentials.json'),
            relay.toml_string(str(folder / 'credentials.json')))
        relay.atomic_write(folder / 'server.toml', config)
        self.instances.add(identifier)
        try:
            self.manage('start', '--config', str(folder/'server.toml'))
            self.wait_ready(room)
        except Exception:
            self.stop(room)
            raise

    def start(self, config=None):
        if self.process is not None and self.process.poll() is None:
            return
        self.instances.clear()
        command = [str(self.bin / 'easytier-core'), '--daemon', '--disable-env-parsing',
            '--rpc-portal', '127.0.0.1:'+str(relay.RPC_PORT), '--console-log-level', 'off']
        if config is not None:
            command += ['-c', str(config)]
        self.process = subprocess.Popen(command,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                break
            try:
                self.instances.update(uuid.UUID(value).hex for value in self.manage('list')['instances'])
                return
            except (relay.RelayError, ValueError):
                time.sleep(.1)
        self.close()
        raise AccessError('ROOM_START_FAILED', '组网服务暂时无法启动，请稍后重试。', 503)

    def wait_ready(self, room):
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                break
            try:
                self.cli(room, 'route')
                return
            except (relay.RelayError, ValueError):
                time.sleep(.1)
        raise AccessError('ROOM_START_FAILED', '组网服务暂时无法启动，请稍后重试。', 503)

    def ensure_shared(self):
        if self.shared_id is not None and self.process is not None and self.process.poll() is None:
            return
        folder = Path(self.config['shared_config']).parent
        state = json.loads((folder/'state.json').read_text(encoding='utf-8'))
        room = dict(id=state['instance_id'], rpc_port=relay.RPC_PORT)
        self.start(Path(self.config['shared_config']))
        paths = relay.Paths(state_dir=folder, program=self.bin.parent)
        try:
            self.wait_ready(room)
            relay.Relay(paths, self.runner).common_profile()
            self.shared_id = room['id']
        except Exception:
            self.close()
            raise

    def grant(self, room, remaining):
        self.ensure(room)
        identifier = str(uuid.uuid4())
        credential = self.cli(room, 'credential', 'generate', '--ttl', str(remaining),
            '--credential-id', identifier, '--reusable', 'false')
        secret = relay.valid_key(credential['credential_secret'])
        public = self.runner.run([self.bin/'wg', 'pubkey'], data=secret+'\n').stdout.strip()
        state = self.state(room)
        profile = dict(schema=4, version=relay.VERSION, backend='easytier', routing_mode='lan-mesh',
            engine_version=relay.ENGINE_VERSION, access_mode='shared', network_name=state['network_name'],
            network=room['network'], mtu=1360, server_public_key=state['public_key'],
            credential_id=identifier, credential_secret=secret, client_public_key=public,
            expires_at=room['expires_at'])
        return profile

    def revoke(self, room, credential):
        self.ensure(room)
        self.cli(room, 'credential', 'revoke', credential)

    def stop(self, room):
        identifier = uuid.UUID(room['id']).hex
        if self.process is not None and self.process.poll() is None and identifier in self.instances:
            self.manage('stop', '--id', room['id'])
        self.instances.discard(identifier)

    def close(self):
        process = self.process
        if process is not None and process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        self.process = None
        self.instances.clear()
        self.shared_id = None


class KeyService:
    def __init__(self, config, root, backend=None, clock=time.time):
        self.config, self.root, self.clock = config, Path(root), clock
        relay.private_dir(self.root)
        self.instance_lock = (self.root/'service.lock').open('a')
        try:
            fcntl.flock(self.instance_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            self.instance_lock.close()
            raise AccessError('ALREADY_RUNNING','此配置的接入服务已经在运行。',503)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(self.root/'access.sqlite'), check_same_thread=False,
                                  isolation_level=None)
        os.chmod(str(self.root/'access.sqlite'), 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS rooms (
                id TEXT PRIMARY KEY, key_hash TEXT UNIQUE NOT NULL, created_at INTEGER NOT NULL,
                activated_at INTEGER, expires_at INTEGER, port INTEGER UNIQUE, rpc_port INTEGER,
                network TEXT);
            CREATE TABLE IF NOT EXISTS sessions (
                room_id TEXT NOT NULL REFERENCES rooms(id), device_id TEXT NOT NULL,
                token_hash TEXT UNIQUE NOT NULL, profile TEXT NOT NULL, lease_until INTEGER NOT NULL,
                PRIMARY KEY (room_id, device_id));
            CREATE INDEX IF NOT EXISTS session_deadline ON sessions(lease_until);
        ''')
        self.backend = backend or MeshRooms(config, self.root)
        self.issuance = defaultdict(deque)

    def now(self):
        return int(self.clock())

    def generate(self, ip, device):
        device_id(device)
        if not self.config.get('key_required',False):
            return dict(key=None, message='此服务器无需 Key。')
        if not self.config.get('allow_generate', True):
            raise AccessError('GENERATION_DISABLED', '此服务器暂不开放获取 Key，请联系服务器提供者。', 403)
        with self.lock:
            now = self.now()
            self.maintain()
            # Bound issuance state and the number of stored pending keys.
            for address in list(self.issuance):
                queue = self.issuance[address]
                while queue and queue[0] <= now-60:
                    queue.popleft()
                if not queue:
                    del self.issuance[address]
            queue = self.issuance[ip]
            if len(queue) >= self.config.get('keys_per_minute', 3):
                raise AccessError('RATE_LIMITED', '获取过于频繁，请稍后再试。', 429)
            pending = self.db.execute('SELECT count(*) FROM rooms WHERE activated_at IS NULL').fetchone()[0]
            if pending >= self.config.get('max_pending_keys', 512):
                raise AccessError('KEY_LIMIT', '暂时无法获取新 Key，请稍后再试。', 503)
            raw = base64.b32encode(secrets.token_bytes(20)).decode('ascii')
            key = 'C6-'+'-'.join(raw[i:i+8] for i in range(0,32,8))
            self.db.execute('INSERT INTO rooms(id,key_hash,created_at) VALUES(?,?,?)',
                            (uuid.uuid4().hex, digest(normalized_key(key)), now))
            queue.append(now)
            return dict(key=key, duration_hours=self.config.get('hours',48),
                        max_players=self.config.get('max_players',6), activated_at=None, expires_at=None)

    def room(self, identifier):
        row = self.db.execute('SELECT * FROM rooms WHERE id=?',(identifier,)).fetchone()
        return dict(row) if row else None

    def allocate(self, room):
        if room['port'] is not None:
            self.backend.ensure(room)
            return room
        used = {row[0] for row in self.db.execute('SELECT port FROM rooms WHERE port IS NOT NULL')}
        start = self.config.get('port_start',20000)
        slot = next((i for i in range(self.config.get('max_rooms',4)) if start+i not in used),None)
        if slot is None:
            raise AccessError('SERVER_FULL', '服务器当前房间已满，请稍后连接。', 503)
        now = self.now()
        pool = ipaddress.ip_network(self.config.get('subnet','10.231.0.0/16'))
        network = ipaddress.IPv4Network((int(pool.network_address)+slot*256,24))
        room.update(activated_at=now, expires_at=now+int(self.config.get('hours',48)*3600),
                    port=start+slot, rpc_port=relay.RPC_PORT, network=str(network))
        self.backend.ensure(room)
        self.db.execute('UPDATE rooms SET activated_at=?,expires_at=?,port=?,rpc_port=?,network=? WHERE id=?',
            (now,room['expires_at'],room['port'],room['rpc_port'],room['network'],room['id']))
        return room

    def join(self, key, device):
        device = device_id(device)
        if not self.config.get('key_required',False):
            profile = json.loads(Path(self.config.get('free_profile',str(self.root/'free-profile.json'))).read_text(encoding='utf-8'))
            if profile['expires_at'] <= self.now():
                raise AccessError('SERVER_CONFIGURATION', '服务器接入配置已过期，请联系服务器提供者。',503)
            return dict(profile=profile, endpoint=self.config['endpoint'], port=self.config['free_mesh_port'],
                        server_time=self.now())
        if not normalized_key(key):
            raise AccessError('KEY_REQUIRED', '请填写 Key。',401)
        if len(str(key)) > 80:
            raise AccessError('INVALID_KEY', 'Key 无效，请检查后重新填写。',403)
        with self.lock:
            self.maintain()
            row = self.db.execute('SELECT * FROM rooms WHERE key_hash=?',
                                  (digest(normalized_key(key)),)).fetchone()
            if not row:
                raise AccessError('INVALID_KEY','Key 无效，请检查后重新填写。',403)
            room = dict(row)
            now = self.now()
            if room['expires_at'] is not None and room['expires_at'] <= now:
                raise AccessError('KEY_EXPIRED','Key 已过期，请使用新的 Key。',403)
            existing = self.db.execute('SELECT * FROM sessions WHERE room_id=? AND device_id=?',
                                      (room['id'],device)).fetchone()
            count = self.db.execute('SELECT count(*) FROM sessions WHERE room_id=?',(room['id'],)).fetchone()[0]
            if existing is None and count >= self.config.get('max_players',6):
                raise AccessError('ROOM_FULL','这个 Key 的同时在线人数已满，请等待朋友退出后再连接。',409)
            newly_activated = room['activated_at'] is None
            room = self.allocate(room)
            try:
                profile = json.loads(existing['profile']) if existing else self.backend.grant(room,room['expires_at']-self.now())
            except Exception:
                if newly_activated:
                    self.backend.stop(room)
                    self.db.execute('UPDATE rooms SET activated_at=NULL,expires_at=NULL,port=NULL,rpc_port=NULL,network=NULL WHERE id=?',(room['id'],))
                raise
            token = secrets.token_urlsafe(32)
            lease = min(room['expires_at']-now,self.config.get('lease_seconds',180))
            self.db.execute('INSERT OR REPLACE INTO sessions VALUES(?,?,?,?,?)',
                            (room['id'],device,digest(token),json.dumps(profile),now+lease))
            return dict(profile=profile, endpoint=self.config['endpoint'], port=room['port'],
                        session_token=token, server_time=now, expires_at=room['expires_at'],
                        lease_seconds=lease, renew_seconds=self.config.get('renew_seconds',30))

    def session(self, token):
        if not token or len(token)>128:
            raise AccessError('SESSION_EXPIRED','连接授权已失效，请重新连接。',401)
        row = self.db.execute('SELECT * FROM sessions WHERE token_hash=?',(digest(token),)).fetchone()
        if row is None:
            raise AccessError('SESSION_EXPIRED','连接授权已失效，请重新连接。',401)
        return dict(row)

    def renew(self, token):
        with self.lock:
            self.maintain()
            session = self.session(token)
            room = self.room(session['room_id'])
            now = self.now()
            lease = min(room['expires_at']-now,self.config.get('lease_seconds',180))
            self.db.execute('UPDATE sessions SET lease_until=? WHERE token_hash=?',(now+lease,digest(token)))
            return dict(server_time=now,expires_at=room['expires_at'],lease_seconds=lease,
                        renew_seconds=self.config.get('renew_seconds',30))

    def release(self, token):
        with self.lock:
            try:
                session = self.session(token)
            except AccessError:
                return {'released': True}
            room = self.room(session['room_id'])
            if room['expires_at']>self.now():
                self.backend.revoke(room,json.loads(session['profile'])['credential_id'])
            self.db.execute('DELETE FROM sessions WHERE token_hash=?',(digest(token),))
            return {'released':True}

    def maintain(self):
        with self.lock:
            if not self.config.get('key_required',False):
                if self.config.get('shared_config'):
                    self.backend.ensure_shared()
                return
            now = self.now()
            for row in self.db.execute('SELECT * FROM rooms WHERE port IS NOT NULL AND expires_at<=?',(now,)).fetchall():
                room = dict(row)
                self.backend.stop(room)
                self.db.execute('DELETE FROM sessions WHERE room_id=?',(room['id'],))
                self.db.execute('UPDATE rooms SET port=NULL,rpc_port=NULL WHERE id=?',(room['id'],))
            for row in self.db.execute('SELECT * FROM sessions WHERE lease_until<=?',(now,)).fetchall():
                session = dict(row)
                room = self.room(session['room_id'])
                self.backend.revoke(room,json.loads(session['profile'])['credential_id'])
                self.db.execute('DELETE FROM sessions WHERE token_hash=?',(session['token_hash'],))
            # Discard unactivated Keys after seven days.
            self.db.execute('DELETE FROM rooms WHERE activated_at IS NULL AND created_at<?',(now-7*86400,))
            for row in self.db.execute('SELECT * FROM rooms WHERE port IS NOT NULL AND expires_at>?',(now,)).fetchall():
                self.backend.ensure(dict(row))

    def recover(self):
        self.maintain()

    def close(self):
        with self.lock:
            self.backend.close()
            self.db.close()
            self.instance_lock.close()


class ApiServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = False
    request_queue_size = 16
    def __init__(self, address, service):
        self.service = service
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(address,ApiHandler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request,client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request,client_address)
        finally:
            self.slots.release()


class ApiHandler(BaseHTTPRequestHandler):
    server_version = 'Civ6Access/1'
    sys_version = ''
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, format, *args):
        pass  # Access logging is disabled to keep Keys and bearer tokens private.

    def reply(self, status, body):
        encoded = json.dumps(body,ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Content-Length',str(len(encoded)))
        self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff')
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == '/v1/version':
            self.reply(200,dict(server_version=relay.VERSION,
                                engine_version=relay.ENGINE_VERSION,api_version=1))
        else:
            self.reply(404,dict(error='NOT_FOUND',message='接口不存在。'))

    def do_POST(self):
        try:
            if self.path not in ('/v1/keys','/v1/connect','/v1/renew','/v1/release'):
                raise AccessError('NOT_FOUND','接口不存在。',404)
            length = int(self.headers.get('Content-Length','0'))
            if not 0<length<=4096 or self.headers.get('Transfer-Encoding'):
                raise AccessError('INVALID_REQUEST','请求格式无效。')
            data = json.loads(self.rfile.read(length).decode('utf-8'))
            if not isinstance(data,dict):
                raise AccessError('INVALID_REQUEST','请求格式无效。')
            service = self.server.service
            authorization = self.headers.get('Authorization','')
            token = authorization[7:] if authorization.startswith('Bearer ') else ''
            if self.path=='/v1/keys':
                address = self.client_address[0]
                if ipaddress.ip_address(address).is_loopback and self.headers.get('X-Real-IP'):
                    address = str(ipaddress.ip_address(self.headers['X-Real-IP']))
                result = service.generate(address,data.get('device_id'))
            elif self.path=='/v1/connect':
                result = service.join(data.get('key',''),data.get('device_id'))
            elif self.path=='/v1/renew':
                result = service.renew(token)
            else:
                result = service.release(token)
            self.reply(200,result)
        except AccessError as error:
            self.reply(error.status,dict(error=error.code,message=error.message))
        except (ValueError,UnicodeError):
            self.reply(400,dict(error='INVALID_REQUEST',message='请求格式无效。'))
        except Exception:
            self.reply(503,dict(error='SERVICE_UNAVAILABLE',message='服务器暂时不可用，请稍后重试。'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir',type=Path,default=Path('/etc/civ6-relay'))
    sub = parser.add_subparsers(dest='action')
    init = sub.add_parser('init')
    init.add_argument('--endpoint',required=True)
    init.add_argument('--bin-dir',type=Path,default=Path('/opt/civ6-relay/bin'))
    init.add_argument('--port-start',type=int,default=20000)
    init.add_argument('--max-rooms',type=int,default=4)
    init.add_argument('--max-players',type=int,default=6)
    init.add_argument('--enable-key',action='store_true',help='显式开启 Key 模式；默认关闭')
    init.add_argument('--free-profile',type=Path)
    init.add_argument('--free-mesh-port',type=int,default=9527)
    serve = sub.add_parser('serve')
    serve.add_argument('--listen')
    serve.add_argument('--port',type=int)
    args = parser.parse_args()
    os.umask(0o077)
    relay.private_dir(args.state_dir)
    path = args.state_dir/'service.json'
    if args.action=='init':
        if path.exists():
            parser.error('已有服务配置，不会覆盖。')
        relay.public_ipv4(args.endpoint)
        if (not 1<=args.max_rooms<=32 or not 1<=args.max_players<=16 or
            not 1024<=args.port_start<=65536-args.max_rooms or
            relay.RPC_PORT in range(args.port_start,args.port_start+args.max_rooms)):
            parser.error('房间数量、人数或端口范围无效。')
        free_profile=args.free_profile or Path('/etc/civ6-relay/common-profile.json')
        if args.free_profile and not free_profile.is_file():
            parser.error('指定的免费服务器共享配置不存在。')
        if not args.enable_key and not free_profile.is_file():
            parser.error('Key 模式默认关闭，请先部署免费服务器，或用 --free-profile 指定其共享配置。')
        config=dict(endpoint=args.endpoint,bin_dir=str(args.bin_dir.resolve()),key_required=args.enable_key,
                    allow_generate=True,hours=48,max_players=args.max_players,max_rooms=args.max_rooms,
                    port_start=args.port_start,free_mesh_port=args.free_mesh_port)
        if free_profile.is_file():
            profile=json.loads(free_profile.read_text(encoding='utf-8'))
            if profile.get('schema')!=4 or profile.get('access_mode')!='shared':
                parser.error('免费直连模式需要自建服务器导出的通用配置。')
            relay.atomic_write(args.state_dir/'free-profile.json',json.dumps(profile))
        relay.atomic_write(path,json.dumps(config,indent=2)+'\n')
        print('接入服务配置已创建。')
        return
    if args.action!='serve':
        parser.error('需要 init 或 serve')
    config=json.loads(path.read_text(encoding='utf-8'))
    service=KeyService(config,args.state_dir)
    server=None
    maintainer=None
    stop=threading.Event()
    def maintenance():
        while not stop.wait(1):
            try:
                service.maintain()
            except Exception:
                print('会话维护失败，将在下次重试。',flush=True)
    def shutdown(signum,frame):
        stop.set()
        if server is None:
            raise SystemExit(0)
        threading.Thread(target=server.shutdown,daemon=True).start()
    signal.signal(signal.SIGTERM,shutdown)
    signal.signal(signal.SIGINT,shutdown)
    try:
        service.recover()
        server=ApiServer((args.listen or config.get('listen','0.0.0.0'),
                          args.port if args.port is not None else config.get('api_port',15888)),service)
        maintainer=threading.Thread(target=maintenance,daemon=True)
        maintainer.start()
        server.serve_forever(poll_interval=.2)
    finally:
        stop.set()
        if server is not None:
            server.server_close()
        if maintainer is not None:
            maintainer.join()
        service.close()


if __name__=='__main__':
    main()
