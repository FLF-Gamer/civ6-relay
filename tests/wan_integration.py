#!/usr/bin/env python3
"""Optional real-server relay probe. Run each node in its own disposable container.
Use short-lived issued credentials, revoke them and remove containers afterwards.
Endpoint is supplied with MESH_TEST_ENDPOINT; never embedded in a client archive.
"""
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

BIN=Path(os.environ.get('MESH_TEST_BIN','/workspace/vendor/easytier/linux-x86_64'))
def cli():
    p=subprocess.run([str(BIN/'easytier-cli'),'-p','127.0.0.1:15887','-o','json','route'],capture_output=True,text=True,timeout=8)
    if p.returncode:return []
    return json.loads(p.stdout)

def node(profile_file):
    profile=json.loads(Path(profile_file).read_text())
    shared=profile.get('schema')==4
    if shared:profile.update(instance_id=str(uuid.uuid4()),player=os.environ['MESH_TEST_NODE_NAME'],client_ip='')
    with tempfile.TemporaryDirectory() as temp:
        folder=Path(temp);trust=folder/'trusted.json'
        trust.write_text(json.dumps({'coordinator':dict(pubkey=profile['server_public_key'],secret='',groups=[],allow_relay=True,allowed_proxy_cidrs=[],reusable=True,expiry_unix=profile['expires_at'],created_at_unix=int(time.time()))}))
        config=Path('/workspace/.build/common-client-test.toml' if shared else '/workspace/.build/client-test.toml').read_text()
        updates=dict(instance_id=profile['instance_id'],network_name=profile['network_name'],hostname=profile['player'],ipv4=profile['client_ip']+'/24',credential_file=str(trust),local_private_key=profile['credential_secret'],local_public_key=profile['client_public_key'])
        for key,value in updates.items():config=re.sub(r'^'+key+r' = .*$',key+' = '+json.dumps(value),config,flags=re.M)
        config=re.sub(r'^peer_public_key = .*$','peer_public_key = '+json.dumps(profile['server_public_key']),config,flags=re.M)
        # Force one outer transport; the game packets remain UDP inside it.
        protocol=os.environ.get('MESH_TEST_PROTOCOL','udp')
        discard='tcp' if protocol=='udp' else 'udp'
        config=re.sub(r'\[\[peer\]\]\nuri = "'+discard+r'://[^\n]+\npeer_public_key = [^\n]+\n','',config)
        endpoint=os.environ['MESH_TEST_ENDPOINT']+':'+os.environ.get('MESH_TEST_PORT','51820')
        config=config.replace('8.8.8.8:51820',endpoint).replace('disable_p2p = false','disable_p2p = true')
        config=config.replace('10.77.77.0/24',profile['network'])
        config='stun_servers = []\nstun_servers_v6 = []\n'+config
        path=folder/'network.toml';path.write_text(config)
        env={k:v for k,v in os.environ.items() if not k.startswith('ET_')};env['ET_CREDENTIAL']=profile['credential_secret']
        p=subprocess.Popen([str(BIN/'easytier-core'),'-c',str(path),'--disable-env-parsing','--rpc-portal','127.0.0.1:15887'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        def diagnostics():
            remaining=0
            for line in p.stdout:
                if 'CORE::INSTANCE::CONNECTION' in line and 'error' in line:
                    print(re.sub(r'[A-Za-z0-9+/]{40,}={0,2}','[REDACTED]',line.strip()),flush=True)
                    remaining=8
                elif remaining and line[:1].isspace():
                    print(re.sub(r'[A-Za-z0-9+/]{40,}={0,2}','[REDACTED]',line.strip()),flush=True)
                    remaining-=1
                else:remaining=0
        threading.Thread(target=diagnostics,daemon=True).start()
        active=True
        def stop(*_):
            nonlocal active
            active=False
        signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
        sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.settimeout(.5)
        sock.bind(('0.0.0.0',62056))
        try:
            print('node started: '+profile['player'],flush=True)
            while active and p.poll() is None:
                try:
                    data,peer=sock.recvfrom(2048);sock.sendto(data,peer)
                except socket.timeout:pass
        finally:
            sock.close()
            if p.poll() is None:
                p.send_signal(signal.SIGINT)
                try:p.wait(timeout=8)
                except subprocess.TimeoutExpired:p.kill();p.wait()

def probe(peer,count):
    routes=cli();row=next((x for x in routes if x.get('ipv4','').split('/')[0]==peer),None)
    if not row or row['path_len']!=2:raise RuntimeError('Expected actual two-hop relay path')
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(4)
    began=time.monotonic()
    for i in range(count):
        packet=i.to_bytes(4,'big')+b'Civ6LAN'*70
        s.sendto(packet,(peer,62056));reply,address=s.recvfrom(2048)
        assert reply==packet and address[0]==peer
    print(json.dumps(dict(mode='server relay',packets=count,payload_bytes=len(packet),seconds=round(time.monotonic()-began,3))),flush=True)

if __name__=='__main__':
    if sys.argv[1]=='node':node(sys.argv[2])
    elif sys.argv[1]=='probe':probe(sys.argv[2],int(sys.argv[3]))
    elif sys.argv[1]=='routes':print(json.dumps(cli()))
