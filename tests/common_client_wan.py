#!/usr/bin/env python3
"""Six clients using one unmodified common profile, automatic IPs and real UDP relay.

Only the endpoint comes from MESH_TEST_ENDPOINT. No credentials are printed.
Uses the existing authorized common access; only disposable containers are removed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('wan',ROOT/'tests/six_player_wan.py');w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
cmd=w.command;DOCKER=w.DOCKER

def main():
 p=argparse.ArgumentParser();p.add_argument('--profile',required=True);p.add_argument('--output',required=True);args=p.parse_args()
 profile_path=Path(args.profile).resolve();profile=json.loads(profile_path.read_text())
 assert profile['schema']==4 and profile['access_mode']=='shared'
 names=['common'+uuid.uuid4().hex[:6]+str(i) for i in range(1,7)]
 containers=[];report=dict(kind='six containers, same common profile, automatic IP, real server UDP relay',phases=[])
 results=Path(tempfile.mkdtemp(prefix='common-wan-',dir=ROOT/'.build'));results.chmod(0o700)
 def routes(c):return json.loads(cmd([DOCKER,'exec',c,'python3','/workspace/tests/wan_integration.py','routes']))
 try:
  for name in names:
   c='civ6-'+name
   cmd([DOCKER,'run','--detach','--rm','--name',c,'--platform','linux/amd64','--cap-add','NET_ADMIN','--device','/dev/net/tun',
        '-v',str(ROOT)+':/workspace:ro','-v',str(results)+':/results','-e','MESH_TEST_ENDPOINT='+os.environ['MESH_TEST_ENDPOINT'],
        '-e','MESH_TEST_PORT='+os.environ.get('MESH_TEST_PORT','9527'),'-e','MESH_TEST_NODE_NAME='+name,
        'civ6-mesh-test:local','python3','-u','/workspace/tests/wan_integration.py','node','/workspace/'+str(profile_path.relative_to(ROOT))])
   containers.append(c)
  until=time.monotonic()+90
  while time.monotonic()<until:
   with ThreadPoolExecutor(max_workers=6) as pool:matrices=list(pool.map(routes,containers))
   addresses={}
   for name,matrix in zip(names,matrices):
    own=next((x for x in matrix if x.get('hostname')==name and x.get('path_len')==0),{})
    ip=own.get('ipv4','').split('/')[0]
    if ip:addresses[name]=ip
   peers=[[r for r in matrix if r.get('hostname') in names and r.get('path_len',0)>0] for matrix in matrices]
   if len(addresses)==6 and len(set(addresses.values()))==6 and all(len(rows)==5 and all(r['path_len']==2 and r['next_hop_hostname']=='Civ6Coordinator' for r in rows) for rows in peers):break
   time.sleep(2)
  else:raise AssertionError('common clients did not obtain six distinct addresses and all relay routes')
  report.update(common_profile_identical_sha256=hashlib.sha256(profile_path.read_bytes()).hexdigest(),automatic_addresses=addresses,
                all_30_directions_relay=True,engine_versions=sorted({r.get('version') for m in matrices for r in m if r.get('hostname') in names or r.get('hostname')=='Civ6Coordinator'}))
  print('PASS common profile: six distinct automatic IPs, all 30 directions via deployed server',flush=True)
  for label,duration,pps,payload in [('warmup',6,1,128),('relay',12,2,256)]:
   start=float(cmd([DOCKER,'exec',containers[0],'python3','-c','import time;print(time.monotonic()+3)']))
   jobs=[]
   for i,(c,name) in enumerate(zip(containers,names),1):
    argv=[DOCKER,'exec',c,'python3','/workspace/tests/mesh_traffic.py','bench','--node',str(i),'--bind',addresses[name],
          '--peers',','.join(ip for n,ip in addresses.items() if n!=name),'--start',str(start),'--duration',str(duration),
          '--pps',str(pps),'--payload',str(payload),'--output','/results/'+label+'-'+str(i)+'.json']
    jobs.append(subprocess.Popen(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
   for job in jobs:
    _,err=job.communicate(timeout=duration+20)
    if job.returncode:raise RuntimeError('UDP benchmark failed')
   nodes=[json.loads((results/(label+'-'+str(i)+'.json')).read_text()) for i in range(1,7)]
   summary=w.summarize(nodes);report['phases'].append(dict(name=label,total=summary))
   print('PHASE '+json.dumps({k:v for k,v in summary.items() if k!='per_flow'}),flush=True)
   if label=='relay':assert summary['loss_pct']<1,'common client relay data failed'
  report['passed']=True
 finally:
  for c in containers:subprocess.run([DOCKER,'stop','--timeout','8',c],capture_output=True,timeout=20)
  shutil.rmtree(results)
  report['temporary_containers_removed']=True
  Path(args.output).write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
