import os,subprocess,sys,shutil,time
from pathlib import Path
from common import read_json,write_json,digest,inside,extract_zip

class Tools:
    def __init__(self,root,evidence):self.root=Path(root);self.e=evidence;self.manifest=read_json(self.root/'tool_manifest.json');self.paths={};self.results=[]
    def prepare(self):
        for t in self.manifest:
            key=t['id'];src=inside(self.root,'PAYLOAD/'+t['file']);dst=self.root/'RUNTIME'/key
            try:
                if not src.is_file() or src.stat().st_size!=t['size'] or digest(src)!=t['sha256']:raise ValueError('PAYLOAD_HASH_MISMATCH')
                dst.mkdir(parents=True,exist_ok=True)
                marker=dst/'extracted.json'
                if key=='python':exe=self.root/'RUNTIME/python/python.exe'
                elif key=='oculix':exe=src
                else:
                    if src.suffix=='.zip' and not marker.exists():extract_zip(src,dst);write_json(marker,{'sha256':t['sha256']})
                    if key=='c' and not marker.exists() and os.name=='nt':
                        # The supplied 7-Zip SFX writes only to its specified destination.
                        r=subprocess.run([str(src),'-y','-o'+str(dst)],cwd=dst,capture_output=True,timeout=180)
                        (self.e.root/'c_extract.log').write_bytes(r.stdout+r.stderr)
                        if r.returncode:raise OSError('C_SFX_EXTRACTION_FAILED')
                        write_json(marker,{'sha256':t['sha256']})
                    if key=='git' and (self.root/'git_runtime_manifest.json').exists():
                        for entry in read_json(self.root/'git_runtime_manifest.json')['files']:
                            f=inside(self.root,entry['path'])
                            if not f.is_file() or digest(f)!=entry['sha256']:raise OSError('GIT_RUNTIME_HASH_MISMATCH')
                    if key=='git' and not any(dst.rglob('git.exe')):
                        # Inno installation is intentionally NEVER invoked. A verified extracted tree is required.
                        raise OSError('GIT_PORTABLE_EXTRACTION_UNAVAILABLE')
                    matches=sorted(dst.rglob(t['executable']))
                    if not matches:raise OSError('TOOL_EXECUTABLE_MISSING')
                    exe=matches[0]
                if not exe.exists():raise OSError('TOOL_EXECUTABLE_MISSING')
                self.paths[key]=str(exe.resolve())
                evidence_path=f'tool_{key}.json';write_json(self.e.root/evidence_path,{'payload_hash':t['sha256'],'executable':str(exe),'runtime_executed':False})
                if os.name!='nt':self.results.append(self.e.result('tool.'+key,'NOT_RUN','WINDOWS_RUNTIME_REQUIRED',[evidence_path]));continue
                if key in ('obs','ahk','oculix'):
                    self.results.append(self.e.result('tool.'+key,'NOT_RUN','FUNCTIONAL_PROBE_REQUIRED',[evidence_path]));continue
                args={'java':['-version'],'node':['--version'],'git':['--version'],'c':['--version'],'godot':['--headless','--version'],'python':['-I','-c','import sys,tkinter;print(sys.version)'],'ffmpeg':['-version']}[key]
                r=subprocess.run([str(exe),*args],capture_output=True,timeout=30,cwd=self.root)
                log=f'tool_{key}.log';(self.e.root/log).write_bytes(r.stdout+r.stderr)
                self.results.append(self.e.result('tool.'+key,'PASS' if r.returncode==0 else 'HARNESS_ERROR','TOOL_EXECUTED' if r.returncode==0 else 'TOOL_PROBE_FAILED',[evidence_path,log]))
                if key=='git' and r.returncode==0:
                    probe_dir=self.e.root/'git_functional_probe';probe_dir.mkdir();env=os.environ.copy();env.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=os.devnull,GIT_EXEC_PATH=str(exe.parent),GIT_TEMPLATE_DIR=str(exe.parent/'templates'))
                    probe=subprocess.run([str(exe),'init','--bare',str(probe_dir/'repo.git')],capture_output=True,timeout=30,env=env)
                    (self.e.root/'git_init.log').write_bytes(probe.stdout+probe.stderr)
                    self.results.append(self.e.result('tool.git.functional','PASS' if probe.returncode==0 and (probe_dir/'repo.git/HEAD').exists() else 'HARNESS_ERROR','GIT_ISOLATED_INIT' if probe.returncode==0 else 'GIT_INIT_FAILED',['git_init.log']))
            except Exception as ex:
                name=f'tool_{key}_error.json';write_json(self.e.root/name,{'exception':repr(ex)})
                self.results.append(self.e.result('tool.'+key,'HARNESS_ERROR','TOOL_PREPARATION_FAILED',[name],detail=str(ex)))
        write_json(self.e.root/'resolved_tools.json',self.paths);return self.results
    def get(self,key):
        if key not in self.paths:raise OSError('TOOL_UNAVAILABLE:'+key)
        return self.paths[key]
    def expand(self,argv,work,profile=None):
        values={k:self.get(k) for k in self.paths};values['python']=self.get('python');values['work']=str(work);values['root']=str(self.root);values['seed']='{seed}'
        if profile:
            observations=profile.get('observations',{});bridge=profile.get('bridge') or (observations.get('bridge') if isinstance(observations,dict) else None)
            values['state']=str(Path(work)/bridge) if bridge else ''
            values['endpoint']=str(Path(work)/profile.get('display',{}).get('endpoint',''))
            values['save']=str(Path(work)/profile.get('save',{}).get('file',''))
        return [str(v).format_map(values) for v in argv]
