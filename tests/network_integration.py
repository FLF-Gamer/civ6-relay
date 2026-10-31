#!/usr/bin/env python3
"""Real EasyTier binaries in disposable Linux namespaces; run only in test Docker.

Two clients are behind separate port-restricted NATs. An isolated RFC5389 STUN
fixture supplies mapped addresses. No internet, host firewall or host routes.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path('/workspace')
BIN = Path(os.environ.get('MESH_TEST_BIN', str(ROOT / 'vendor/easytier/linux-x86_64')))
spec = importlib.util.spec_from_file_location('relayctl', ROOT / 'relayctl.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
processes = []
namespaces = []

def cmd(*args, ns=None, data=None, check=True):
    prefix = ['ip', 'netns', 'exec', ns] if ns else []
    return subprocess.run(prefix + list(map(str, args)), input=data, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check, timeout=12)

def spawn(args, ns, **kwargs):
    p = subprocess.Popen(['ip', 'netns', 'exec', ns] + list(map(str, args)), **kwargs)
    processes.append(p)
    return p

def cli(ns, *args, port=15887):
    value = cmd(BIN / 'easytier-cli', '-p', '127.0.0.1:'+str(port), '-o', 'json', *args, ns=ns)
    return json.loads(value.stdout)

def wait_for(label, predicate, seconds=60):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        try:
            value = predicate()
            if value:
                print('PASS ' + label, flush=True)
                return value
        except (subprocess.SubprocessError, ValueError):
            pass
        time.sleep(.5)
    raise AssertionError(label + ' timed out')

def ns(name):
    cmd('ip', 'netns', 'add', name)
    namespaces.append(name)
    cmd('ip', 'link', 'set', 'lo', 'up', ns=name)

def link(a, dev_a, ip_a, b, dev_b, ip_b):
    cmd('ip', 'link', 'add', dev_a, 'type', 'veth', 'peer', 'name', dev_b)
    cmd('ip', 'link', 'set', dev_a, 'netns', a)
    cmd('ip', 'link', 'set', dev_b, 'netns', b)
    for namespace, dev, ip in ((a, dev_a, ip_a), (b, dev_b, ip_b)):
        cmd('ip', 'addr', 'add', ip, 'dev', dev, ns=namespace)
        cmd('ip', 'link', 'set', dev, 'up', ns=namespace)

STUN = r'''
import select,socket,struct
ips=['192.0.2.1','192.0.2.2']; ports=[3478,3479]; sockets={}
for ip in ips:
 for port in ports:
  s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((ip,port));sockets[(ip,port)]=s
def address(kind,ip,port,xor=False):
 raw=struct.unpack('!I',socket.inet_aton(ip))[0]
 if xor: port^=0x2112; raw^=0x2112a442
 return struct.pack('!HHBBHI',kind,8,0,1,port,raw)
while True:
 for s in select.select(list(sockets.values()),[],[],1)[0]:
  data,peer=s.recvfrom(4096)
  if len(data)<20 or data[:2]!=b'\x00\x01':continue
  change=0; offset=20
  while offset+4<=len(data):
   kind,size=struct.unpack('!HH',data[offset:offset+4])
   if kind==3 and size==4:change=struct.unpack('!I',data[offset+4:offset+8])[0]
   offset+=4+((size+3)//4)*4
  ip,port=s.getsockname(); alt=(ips[1-ips.index(ip)],ports[1-ports.index(port)])
  target=(alt[0] if change&4 else ip,alt[1] if change&2 else port)
  body=address(0x20,*peer,True)+address(1,*peer)+address(0x802b,*target)+address(0x802c,*alt)
  sockets[target].sendto(struct.pack('!HH',0x101,len(body))+data[4:20]+body,peer)
'''
ECHO = r'''
import socket,select
sockets=[]
for port in [62056,62900]:
 s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('0.0.0.0',port));sockets.append(s)
while True:
 for s in select.select(sockets,[],[],1)[0]:
  data,peer=s.recvfrom(2048);s.sendto(data,peer)
'''
UDP = r'''
import socket,sys,time,json
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(3)
if sys.argv[1].endswith('.255') or sys.argv[1]=='255.255.255.255':
 s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1);s.setsockopt(socket.SOL_SOCKET,socket.SO_BINDTODEVICE,b'civ6mesh\x00')
else: s.bind(('10.77.77.2',0))
count=int(sys.argv[3]);begin=time.monotonic()
for i in range(count):
 data=i.to_bytes(4,'big')+b'Civ6LAN'*70;s.sendto(data,(sys.argv[1],int(sys.argv[2])));reply,peer=s.recvfrom(2048)
 assert reply==data and peer[0]=='10.77.77.3'
print(json.dumps({'packets':count,'seconds':round(time.monotonic()-begin,3)}))
'''

def route_hops():
    rows = cli('client1', 'route')
    return next((x['path_len'] for x in rows if x.get('hostname') == 'player2'), None)

def relay_ready():
    other=next((x['path_len'] for x in cli('client2','route') if x.get('hostname')=='player1'),None)
    return route_hops()==2 and other==2

def udp_ready():
    return cmd('python3','-c',UDP,'10.77.77.3','62056','1',ns='client1',check=False).returncode==0

def udp(label, ip='10.77.77.3', port=62056, count=10):
    result = cmd('python3', '-c', UDP, ip, str(port), str(count), ns='client1',check=False)
    if result.returncode: raise AssertionError(label+': '+result.stderr[-160:])
    print('PASS ' + label + ' ' + result.stdout.strip(), flush=True)

def start_core(path, nsname, credential=None, rpc=15887):
    env = {k:v for k,v in os.environ.items() if not k.startswith('ET_')}
    if credential:
        env['ET_CREDENTIAL'] = credential
    with path.with_suffix('.log').open('wb') as log:
        p = spawn([BIN / 'easytier-core', '-c', path, '--disable-env-parsing', '--rpc-portal', '127.0.0.1:'+str(rpc)],
                  nsname, stdout=log, stderr=log, env=env)
    wait_for(nsname + ' core ready', lambda: p.poll() is None and cli(nsname, 'node', 'info',port=rpc), 15)

with tempfile.TemporaryDirectory(prefix='civ6-mesh-') as td:
    folder = Path(td)
    try:
        for name in ('public', 'nat1', 'nat2', 'client1', 'client2'):
            ns(name)
        cmd('ip', 'link', 'add', 'publicbr', 'type', 'bridge', ns='public')
        cmd('ip', 'addr', 'add', '192.0.2.1/24', 'dev', 'publicbr', ns='public')
        cmd('ip', 'addr', 'add', '192.0.2.2/24', 'dev', 'publicbr', ns='public')
        cmd('ip', 'link', 'set', 'publicbr', 'up', ns='public')
        for i in (1,2):
            nat, client = 'nat%d' % i, 'client%d' % i
            link('public', 'pub%d'%i, '192.0.2.%d/32'%(20+i), nat, 'wan%d'%i, '192.0.2.%d/24'%(10+i))
            cmd('ip', 'addr', 'flush', 'dev', 'pub%d'%i, ns='public')
            cmd('ip', 'link', 'set', 'pub%d'%i, 'master', 'publicbr', ns='public')
            link(nat, 'lan%d'%i, '10.20%d.0.1/24'%i, client, 'eth%d'%i, '10.20%d.0.2/24'%i)
            cmd('ip', 'route', 'add', 'default', 'via', '10.20%d.0.1'%i, ns=client)
            cmd('python3', '-c', "open('/proc/sys/net/ipv4/ip_forward','w').write('1')", ns=nat)
            cmd('iptables', '-P', 'FORWARD', 'DROP', ns=nat)
            cmd('iptables', '-A', 'FORWARD', '-m', 'conntrack', '--ctstate', 'ESTABLISHED,RELATED', '-j', 'ACCEPT', ns=nat)
            cmd('iptables', '-A', 'FORWARD', '-i', 'lan%d'%i, '-o', 'wan%d'%i, '-j', 'ACCEPT', ns=nat)
            # Stable endpoint-independent UDP mapping; inbound remains restricted
            # by conntrack until this client sends to that exact remote endpoint.
            cmd('iptables', '-t', 'nat', '-A', 'PREROUTING', '-i', 'wan%d'%i, '-p', 'udp', '-j', 'DNAT', '--to-destination', '10.20%d.0.2'%i, ns=nat)
            cmd('iptables', '-t', 'nat', '-A', 'POSTROUTING', '-o', 'wan%d'%i, '-j', 'MASQUERADE', ns=nat)
        baseline = {n:cmd('ip', 'route', 'show', 'default', ns=n).stdout for n in ('client1','client2')}
        nat_probe = """import socket,time,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(.15);s.bind(('0.0.0.0',int(sys.argv[1])))
for n in range(30):
 s.sendto(b'nat-test',(sys.argv[2],int(sys.argv[3])))
 try:
  data,addr=s.recvfrom(100)
  if data==b'nat-test':
   s.sendto(data,addr);print('reachable');sys.exit(0)
 except socket.timeout:pass
sys.exit(1)
"""
        a=spawn(['python3','-c',nat_probe,'41000','192.0.2.12','42000'],'client1',stdout=subprocess.PIPE)
        b=spawn(['python3','-c',nat_probe,'42000','192.0.2.11','41000'],'client2',stdout=subprocess.PIPE)
        a.communicate(timeout=8);b.communicate(timeout=8)
        if a.returncode or b.returncode:
            for n in ('public','nat1','nat2'):
                for args in (('ip','route'),('iptables','-nvL','FORWARD'),('iptables','-t','nat','-nvL','POSTROUTING')):
                    print(n+' '+str(args)+' '+cmd(*args,ns=n).stdout,flush=True)
            print(cmd('ping','-c','1','-W','1','192.0.2.12',ns='nat1',check=False).stdout,flush=True)
            raise AssertionError('isolated NAT fixture cannot pass independent UDP hole punch')
        print('PASS independent UDP hole punch through NAT fixture',flush=True)
        spawn(['python3','-u','-c',STUN], 'public', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        private = cmd(ROOT / 'vendor/linux-amd64/wg', 'genkey').stdout.strip()
        public = cmd(ROOT / 'vendor/linux-amd64/wg', 'pubkey', data=private+'\n').stdout.strip()
        state = r.settings('8.8.8.8', port=51820)
        state.update(instance_id=str(uuid.uuid4()), network_name='civ6-test',network_secret=uuid.uuid4().hex,private_key=private,public_key=public)
        path = folder/'server.toml'
        path.write_text(r.server_config(state).replace('/etc/civ6-relay/credentials.json',str(folder/'credentials.json')))
        start_core(path, 'public')
        credentials=[]
        template=(ROOT/'.build/client-test.toml').read_text()
        for i in (1,2):
            credential = cli('public','credential','generate','--ttl','3600','--credential-id',str(uuid.uuid4()),'--reusable','false')
            credentials.append(credential)
            client_public=cmd(ROOT/'vendor/linux-amd64/wg','pubkey',data=credential['credential_secret']+'\n').stdout.strip()
            trust=folder/('trusted%d.json'%i)
            trust.write_text(json.dumps({'coordinator':dict(pubkey=public,secret='',groups=[],allow_relay=True,allowed_proxy_cidrs=[],reusable=True,expiry_unix=int(time.time())+3600,created_at_unix=int(time.time()))}))
            config=template
            for name,value in dict(instance_id=str(uuid.uuid4()),hostname='player%d'%i,ipv4='10.77.77.%d/24'%(i+1),credential_file=str(trust),local_private_key=credential['credential_secret'],local_public_key=client_public).items():
                config=re.sub(r'^'+name+r' = .*$',name+' = '+json.dumps(value),config,flags=re.M)
            config=re.sub(r'^peer_public_key = .*$', 'peer_public_key = '+json.dumps(public),config,flags=re.M)
            config=config.replace('8.8.8.8:51820','192.0.2.1:51820').replace('enable_ipv6 = true','enable_ipv6 = false')
            config='stun_servers = ["192.0.2.1:3478", "192.0.2.2:3478"]\nstun_servers_v6 = []\n'+config
            path=folder/('client%d.toml'%i);path.write_text(config)
            start_core(path,'client%d'%i,credential['credential_secret'])
        spawn(['python3','-u','-c',ECHO],'client2',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        wait_for('players discover each other',lambda:route_hops() is not None,15)
        time.sleep(.5)
        udp('initial reachable UDP path',count=1)
        wait_for('separate NATs: actual P2P path = 1 hop',lambda:route_hops()==1,60)
        print('NAT info: '+json.dumps(cli('client1','node','info').get('stun_info',{})),flush=True)
        udp('direct game UDP round trips',count=200)
        spawn(['python3','-c',"import socket,time; s=socket.socket();s.bind(('10.77.77.3',62056));s.listen();time.sleep(300)"],'client2',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        wait_for('TCP probe listener ready',lambda:':62056' in cmd('ss','-lnt',ns='client2').stdout,5)
        tcp=cmd('python3','-c',"import socket; s=socket.socket();s.settimeout(1);print(s.connect_ex(('10.77.77.3',62056)))",ns='client1')
        assert tcp.stdout.strip()!='0','unexpected TCP exposure'
        print('PASS game subnet TCP blocked; UDP remains reachable',flush=True)
        udp('direct subnet discovery broadcast',ip='10.77.77.255',port=62900,count=1)
        udp('direct limited discovery broadcast',ip='255.255.255.255',port=62900,count=1)
        cmd('iptables','-I','FORWARD','1','-s','192.0.2.11','-d','192.0.2.12','-j','DROP',ns='public')
        cmd('iptables','-I','FORWARD','1','-s','192.0.2.12','-d','192.0.2.11','-j','DROP',ns='public')
        # Bridge traffic traverses bridge filter only when bridge-nf is enabled.
        # Filter both gateways instead; these rules affect only this test namespace.
        for i,other in ((1,12),(2,11)):
            cmd('iptables','-I','FORWARD','1','-d','192.0.2.%d'%other,'-j','DROP',ns='nat%d'%i)
            cmd('iptables','-I','FORWARD','1','-s','192.0.2.%d'%other,'-j','DROP',ns='nat%d'%i)
        failed_at=time.monotonic()
        wait_for('blocked P2P: both fallback paths = 2 hops',relay_ready,45)
        wait_for('relay UDP becomes reachable after path change',udp_ready,30)
        print('Observed failover recovery seconds: '+str(round(time.monotonic()-failed_at,2)),flush=True)
        udp('fallback relay game UDP round trips',count=100)
        udp('fallback relay discovery broadcast',ip='10.77.77.255',port=62900,count=1)
        for i in (1,2):
            cmd('iptables','-D','FORWARD','1',ns='nat%d'%i)
            cmd('iptables','-D','FORWARD','1',ns='nat%d'%i)
        cmd('iptables','-D','FORWARD','1',ns='public');cmd('iptables','-D','FORWARD','1',ns='public')
        wait_for('unblocked P2P: direct path restored',lambda:route_hops()==1,90)
        udp('restored direct UDP',count=10)
        for name in baseline:
            assert cmd('ip','route','show','default',ns=name).stdout==baseline[name], 'default route changed'
        print('PASS default routes unchanged',flush=True)
        cli('public','credential','revoke',credentials[1]['credential_id'])
        wait_for('revoked player loses mesh path',lambda:route_hops() is None,30)
        udp_denied=cmd('python3','-c',UDP,'10.77.77.3','62056','1',ns='client1',check=False)
        assert udp_denied.returncode!=0,'revoked credential still passes game data'
        assert any(x.get('hostname')=='Civ6Coordinator' for x in cli('client1','route'))
        print('PASS revocation stops game data; other player stays connected',flush=True)
        bad_private=cmd(ROOT/'vendor/linux-amd64/wg','genkey').stdout.strip()
        bad_public=cmd(ROOT/'vendor/linux-amd64/wg','pubkey',data=bad_private+'\n').stdout.strip()
        bad=(folder/'client1.toml').read_text().replace('no_tun = false','no_tun = true')
        for name,value in dict(instance_id=str(uuid.uuid4()),hostname='untrusted',local_private_key=bad_private,local_public_key=bad_public).items():
            bad=re.sub(r'^'+name+r' = .*$',name+' = '+json.dumps(value),bad,flags=re.M)
        bad_path=folder/'untrusted.toml';bad_path.write_text(bad)
        start_core(bad_path,'client1',bad_private,rpc=15888)
        time.sleep(3)
        assert not any(x.get('path_len',0)>0 for x in cli('client1','route',port=15888)), 'untrusted key joined the network'
        print('PASS unissued credential cannot join',flush=True)
    except Exception as error:
        print('FAIL '+type(error).__name__+': '+str(error),flush=True)
        for path in folder.glob('*.log'):
            lines=[line for line in path.read_text(errors='replace').splitlines() if any(term in line for term in ('hole punch','hole_punch','ERROR',' WARN '))][-6:]
            safe=re.sub(r'[A-Za-z0-9+/]{40,}={0,2}','[REDACTED]','\n'.join(lines))
            print(path.name+': '+safe,flush=True)
        for name in ('public','client1','client2'):
            try:
                print(name+' routes: '+json.dumps(cli(name,'route')),flush=True)
            except Exception: pass
        raise
    finally:
        for p in reversed(processes):
            if p.poll() is None:
                p.send_signal(signal.SIGINT)
                try:p.wait(timeout=3)
                except subprocess.TimeoutExpired:p.kill();p.wait()
        for name in reversed(namespaces):
            cmd('ip','netns','del',name,check=False)
