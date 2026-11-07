"""Deterministic ZIP reconstruction from exact per-file inventory; no external dependencies."""
import argparse,json,hashlib,zipfile
from pathlib import Path
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--root',required=True);ap.add_argument('--output',required=True);ap.add_argument('--manifest',default='package_files_v033.json');a=ap.parse_args();root=Path(a.root).resolve();output=Path(a.output).resolve();m=json.loads((root/a.manifest).read_text())
 with zipfile.ZipFile(output,'w',allowZip64=True) as z:
  for f in m['files']:
   p=(root/f['path']).resolve()
   if not p.is_relative_to(root) or p.stat().st_size!=f['size'] or digest(p)!=f['sha256']:raise ValueError('PACKAGE_FILE_MISMATCH:'+f['path'])
   i=zipfile.ZipInfo(f['path'],date_time=(2026,11,1,0,0,0));i.create_system=3;i.external_attr=(0o100755 if f['path'].endswith('.sh') else 0o100644)<<16;i.compress_type=zipfile.ZIP_STORED
   with p.open('rb') as src,z.open(i,'w',force_zip64=True) as dst:
    while True:
     b=src.read(1024*1024)
     if not b:break
     dst.write(b)
  i=zipfile.ZipInfo(a.manifest,date_time=(2026,11,1,0,0,0));i.create_system=3;i.external_attr=0o100644<<16;z.writestr(i,(root/a.manifest).read_bytes())
 print(json.dumps({'archive':str(output),'size':output.stat().st_size,'sha256':digest(output)}))
if __name__=='__main__':main()
