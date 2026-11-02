"""Dispatch by explicit backend or every selected profile's display capability."""
import os,sys,json
from pathlib import Path
from windows_runner import Session

def route(argv,root,platform):
    backend='auto';kinds=set()
    for i,arg in enumerate(argv):
        if arg=='--backend':backend=argv[i+1]
        if arg=='--profile':kinds.add(json.loads((root/argv[i+1]).read_text(encoding='utf-8')).get('display',{}).get('kind','windows'))
    if backend not in ('auto','rfb','windows'):raise ValueError('UNKNOWN_BACKEND:'+backend)
    if len(kinds)>1:raise ValueError('MIXED_DISPLAY_BACKENDS_REQUIRE_SEPARATE_RUNS')
    if backend!='auto':
        if kinds and kinds!={backend}:raise ValueError('PROFILE_BACKEND_MISMATCH')
        return backend
    if kinds:return next(iter(kinds))
    return 'rfb' if platform!='nt' and (root/'VALIDATION_PROFILES').is_dir() else 'windows'

def main():
    root=Path(__file__).resolve().parents[1];backend=route(sys.argv[1:],root,os.name)
    if backend=='rfb':
        from host_runner import main as run
    else:
        if '--backend' in sys.argv:
            i=sys.argv.index('--backend');del sys.argv[i:i+2]
        from windows_runner import main as run
    return run()
if __name__=='__main__':raise SystemExit(main())
