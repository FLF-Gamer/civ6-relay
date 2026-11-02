#!/usr/bin/env python3
"""Exercise real server-issued access in an isolated, privileged Linux container."""
import http.client
import ipaddress
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path('/workspace')
sys.path.insert(0, str(ROOT))
import keyservice


def command(*args, ns=None, check=True, **kwargs):
    prefix = ['ip', 'netns', 'exec', ns] if ns else []
    return subprocess.run(prefix+list(map(str,args)), text=True, capture_output=True,
                          timeout=8, check=check, **kwargs)


def wait_for(label, predicate, timeout=20):
    deadline = time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            if predicate():
                print('PASS '+label,flush=True)
                return
        except (subprocess.SubprocessError, ValueError):
            pass
        time.sleep(.2)
    raise AssertionError(label+' timed out')


def routes(name):
    return json.loads(command(ROOT/'vendor/easytier/linux-x86_64/easytier-cli',
        '-p','127.0.0.1:15887','-o','json','route',ns=name).stdout)


def peer(name, other):
    return next((row for row in routes(name) if row.get('hostname')==other),None)


ECHO = '''import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('0.0.0.0',62056))
while True:
 data,peer=s.recvfrom(2048);s.sendto(data,peer)
'''
PROBE = '''import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(.5)
if sys.argv[1].endswith('.255'):
 s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
 s.setsockopt(socket.SOL_SOCKET,socket.SO_BINDTODEVICE,b'civ6mesh\\x00')
for n in range(10):
 data=b'Civ6-test-'+bytes([n]);s.sendto(data,(sys.argv[1],62056))
 reply,peer=s.recvfrom(2048);assert reply==data
'''
STUN = '''import select,socket,struct
sockets={}
for ip in ['192.0.2.1','192.0.2.2']:
 for port in [3478,3479]:
  s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((ip,port));sockets[(ip,port)]=s
def address(kind,ip,port,xor=False):
 raw=struct.unpack('!I',socket.inet_aton(ip))[0]
 if xor:port^=0x2112;raw^=0x2112a442
 return struct.pack('!HHBBHI',kind,8,0,1,port,raw)
while True:
 for s in select.select(list(sockets.values()),[],[],1)[0]:
  data,peer=s.recvfrom(4096)
  if len(data)<20 or data[:2]!=b'\\x00\\x01':continue
  change=0;offset=20
  while offset+4<=len(data):
   kind,size=struct.unpack('!HH',data[offset:offset+4])
   if kind==3 and size==4:change=struct.unpack('!I',data[offset+4:offset+8])[0]
   offset+=4+((size+3)//4)*4
  ip,port=s.getsockname();alt=('192.0.2.2' if ip=='192.0.2.1' else '192.0.2.1',3479 if port==3478 else 3478)
  target=(alt[0] if change&4 else ip,alt[1] if change&2 else port)
  body=address(0x20,*peer,True)+address(1,*peer)+address(0x802b,*target)+address(0x802c,*alt)
  sockets[target].sendto(struct.pack('!HH',0x101,len(body))+data[4:20]+body,peer)
'''


def start_client(folder, name, access, processes):
    profile=access['profile']
    trust=folder/(name+'-trust.json')
    trust.write_text(json.dumps({'coordinator':dict(pubkey=profile['server_public_key'],secret='',
        groups=[],allow_relay=True,allowed_proxy_cidrs=[],reusable=True,
        expiry_unix=profile['expires_at'],created_at_unix=int(time.time()))}))
    q=keyservice.relay.toml_string
    # Match the production client's secure-mode and automatic subnet settings.
    lines=['instance_id = '+q(str(uuid.uuid4())), 'hostname = '+q(name),
        'dhcp = true','dhcp_subnet = '+q(profile['network']),
        'listeners = []','routes = ['+q(profile['network'])+']',
        'stun_servers = ["192.0.2.1:3478", "192.0.2.2:3478"]',
        'stun_servers_v6 = []','credential_file = '+q(str(trust))]
    for protocol in ('udp','tcp'):
        lines+=['[[peer]]','uri = '+q(protocol+'://192.0.2.1:'+str(access['port'])),
                'peer_public_key = '+q(profile['server_public_key'])]
    lines+=['[network_identity]','network_name = '+q(profile['network_name']),
        '[secure_mode]','enabled = true','local_private_key = '+q(profile['credential_secret']),
        'local_public_key = '+q(profile['client_public_key']), '[flags]',
        'dev_name = "civ6mesh"','enable_ipv6 = false','enable_exit_node = false',
        'accept_dns = false','enable_encryption = true','private_mode = true',
        'default_protocol = "udp"','no_tun = false','disable_p2p = false','p2p_only = false',
        'disable_upnp = true','disable_relay_data = true','enable_udp_broadcast_relay = true',
        '[console_logger]','level = "off"']
    path=folder/(name+'.toml');path.write_text('\n'.join(lines)+'\n')
    env={k:v for k,v in os.environ.items() if not k.startswith('ET_')}
    env['ET_CREDENTIAL']=profile['credential_secret']
    process=subprocess.Popen(['ip','netns','exec',name,
        str(ROOT/'vendor/easytier/linux-x86_64/easytier-core'),'-c',str(path),
        '--disable-env-parsing','--rpc-portal','127.0.0.1:15887'],
        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=env)
    processes.append(process)
    wait_for(name+' joins server',lambda:peer(name,'Civ6Coordinator'))
    return process


def main():
    processes=[];namespaces=[];service=None;api=None;worker=None
    with tempfile.TemporaryDirectory(prefix='civ6-key-network-') as temp:
        folder=Path(temp)
        try:
            command('ip','link','add','keybr','type','bridge')
            command('ip','addr','add','192.0.2.1/24','dev','keybr')
            command('ip','addr','add','192.0.2.2/24','dev','keybr')
            command('ip','link','set','keybr','up')
            for index,name in enumerate(('key-a','key-b','key-other'),10):
                command('ip','netns','add',name);namespaces.append(name)
                command('ip','link','set','lo','up',ns=name)
                host='kh'+str(index);guest='kg'+str(index)
                command('ip','link','add',host,'type','veth','peer','name',guest)
                command('ip','link','set',guest,'netns',name)
                command('ip','link','set',host,'master','keybr')
                command('ip','link','set',host,'up')
                command('ip','addr','add','192.0.2.'+str(index)+'/24','dev',guest,ns=name)
                command('ip','link','set',guest,'up',ns=name)
            processes.append(subprocess.Popen(['python3','-u','-c',STUN],
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
            binaries=folder/'bin';binaries.mkdir()
            for name in ('easytier-core','easytier-cli'):
                shutil.copy(ROOT/'vendor/easytier/linux-x86_64'/name,binaries/name)
            shutil.copy(ROOT/'vendor/linux-amd64/wg',binaries/'wg')
            # Native credentials use real time. A short test duration exercises actual expiry.
            config=dict(key_required=True,endpoint='192.0.2.1',bin_dir=str(binaries),hours=90/3600,
                        max_rooms=2,max_players=2,lease_seconds=180,renew_seconds=30)
            service=keyservice.KeyService(config,folder/'state')
            api=keyservice.ApiServer(('127.0.0.1',0),service)
            worker=threading.Thread(target=lambda:api.serve_forever(poll_interval=.01),daemon=True)
            worker.start()
            def post(path,body,token=''):
                conn=http.client.HTTPConnection('127.0.0.1',api.server_port,timeout=12)
                headers={'Content-Type':'application/json'}
                if token:headers['Authorization']='Bearer '+token
                conn.request('POST',path,json.dumps(body),headers)
                result=conn.getresponse();value=json.loads(result.read());conn.close()
                return result.status,value
            device=lambda:str(uuid.uuid4())
            key=post('/v1/keys',dict(device_id=device()))[1]['key']
            assert post('/v1/connect',dict(device_id=device()))[1]['error']=='KEY_REQUIRED'
            a=post('/v1/connect',dict(device_id=device(),key=key))[1]
            assert 'profile' in a,'real core could not issue access'
            b=post('/v1/connect',dict(device_id=device(),key=key))[1]
            assert post('/v1/connect',dict(device_id=device(),key=key))[1]['error']=='ROOM_FULL'
            other_key=post('/v1/keys',dict(device_id=device()))[1]['key']
            other=post('/v1/connect',dict(device_id=device(),key=other_key))[1]
            clients={name:start_client(folder,name,access,processes)
                     for name,access in (('key-a',a),('key-b',b),('key-other',other))}
            wait_for('same Key discovers peer',lambda:peer('key-a','key-b'))
            wait_for('same Key establishes P2P',lambda:peer('key-a','key-b')['path_len']==1,45)
            wait_for('automatic IP allocation',lambda:peer('key-a','key-b').get('ipv4'))
            assert not peer('key-a','key-other') and not peer('key-other','key-a')
            print('PASS different Keys have isolated player lists',flush=True)
            echo=subprocess.Popen(['ip','netns','exec','key-b','python3','-u','-c',ECHO],
                                  stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            processes.append(echo)
            ip=peer('key-a','key-b')['ipv4'].split('/')[0]
            wait_for('same Key game UDP',lambda:command('python3','-c',PROBE,ip,ns='key-a').returncode==0)
            broadcast=str(ipaddress.ip_network(a['profile']['network']).broadcast_address)
            command('python3','-c',PROBE,broadcast,ns='key-a')
            print('PASS same Key discovery broadcast and UDP replies',flush=True)
            post('/v1/release',{},b['session_token'])
            wait_for('release revokes an established P2P peer',lambda:not peer('key-a','key-b'),30)
            denied=command('python3','-c',PROBE,ip,ns='key-a',check=False)
            assert denied.returncode!=0,'released credential still passes game data'
            print('PASS released credential cannot send game UDP',flush=True)
            clients['key-b'].send_signal(signal.SIGINT)
            clients['key-b'].wait(timeout=8)
            b=post('/v1/connect',dict(device_id=device(),key=key))[1]
            start_client(folder,'key-b',b,processes)
            wait_for('released seat can rejoin over P2P',lambda:peer('key-a','key-b') and peer('key-a','key-b')['path_len']==1,30)
            ip=peer('key-a','key-b')['ipv4'].split('/')[0]
            command('python3','-c',PROBE,ip,ns='key-a')
            # Keep both P2P clients and the unrelated group online until real expiry.
            while time.time()<a['expires_at']+1:
                for access in (a,b,other):
                    post('/v1/renew',{},access['session_token'])
                service.maintain()
                time.sleep(.5)
            service.maintain()
            assert post('/v1/connect',dict(device_id=device(),key=key))[1]['error']=='KEY_EXPIRED'
            wait_for('native credential expiry removes server access',lambda:not peer('key-a','Civ6Coordinator'),15)
            wait_for('native credential expiry removes an existing P2P path',lambda:not peer('key-a','key-b'),65)
            assert command('python3','-c',PROBE,ip,ns='key-a',check=False).returncode!=0
            print('PASS actual expiry, reconnect denial, room cleanup',flush=True)
        finally:
            if api:
                api.shutdown();api.server_close()
            if worker:worker.join(timeout=3)
            for process in reversed(processes):
                if process.poll() is None:process.send_signal(signal.SIGINT)
            for process in reversed(processes):
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()
            if service:service.close()
            for name in reversed(namespaces):command('ip','netns','del',name)
            subprocess.run(['ip','link','del','keybr'],capture_output=True)


if __name__=='__main__':
    main()
