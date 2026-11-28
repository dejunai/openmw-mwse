#!/usr/bin/env python3
"""dry-run survey driver (dej (dejunai)): omw2mwse convert --dry-run + scan --json per repo."""
import subprocess, sys, json, time, os, glob
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
BIN = sys.argv[1]; SRC = Path(sys.argv[2]); OUT = Path(sys.argv[3])
(OUT/'results').mkdir(parents=True, exist_ok=True); (OUT/'scan').mkdir(exist_ok=True)
def one(d):
    ident = d.parent.name + '__' + d.name
    res = OUT/'results'/(ident+'.json'); sc = OUT/'scan'/(ident+'.json')
    rec = {'id': ident, 'dir': str(d)}
    t=time.time()
    try:
        p = subprocess.run([BIN,'--staged-root',str(d),'--result-json',str(res),'--dry-run'],capture_output=True,text=True,timeout=600)
        rec.update(exit=p.returncode, stderr=p.stderr[-3000:], stdout=p.stdout[-500:])
    except subprocess.TimeoutExpired:
        rec.update(exit='timeout')
    try:
        p = subprocess.run([BIN,'scan','--json','--no-installs','--no-openmw',str(d)],capture_output=True,text=True,timeout=600)
        rec.update(scan_exit=p.returncode, scan_stderr=p.stderr[-3000:])
        sc.write_text(p.stdout)
    except subprocess.TimeoutExpired:
        rec.update(scan_exit='timeout')
    rec['secs']=round(time.time()-t,1)
    return rec
dirs = sorted(d for s in SRC.glob('*') for d in s.glob('*') if d.is_dir())
with ThreadPoolExecutor(4) as ex: recs = list(ex.map(one, dirs))
json.dump(recs, open(OUT/'runs.json','w'), indent=1)
print(len(recs))
