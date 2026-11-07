"""Explicit release step. NEVER invoked by normal START."""
from pathlib import Path
from common import *
def create(root):
    root=Path(root)
    files=[{'path':p.relative_to(root).as_posix(),'size':p.stat().st_size,'sha256':digest(p)} for p in sorted((root/'CORE').rglob('*')) if p.is_file() and '__pycache__' not in p.parts]
    for name in ['START_QA.cmd','BOOTSTRAP.ps1','tool_manifest.json','python_manifest.json','capability_contract.json','git_runtime_manifest.json','START_VALIDATION.sh','acceptance_manifest.json','START_FUNCTIONAL.cmd','START_LOGIC.cmd','START_PLAYABLE.cmd','START_LONG_SOAK.cmd','START_SOAK_24H.cmd','START_SELFTEST.cmd']:
        p=root/name
        if p.is_file():files.append({'path':name,'size':p.stat().st_size,'sha256':digest(p)})
    write_json(root/'core_manifest.json',{'core_version':VERSION,'schema_version':SCHEMA,'profile_schema':1,'result_schema':1,'capabilities':CAPABILITIES,'files':files,'integrity_scope':'accidental corruption / out-of-process modifications; not cryptographic publisher authentication'})
if __name__=='__main__':create(Path(__file__).resolve().parents[1])
