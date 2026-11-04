"""Execute fixture fault isolation with the bundled Godot; no real-game claim."""
import argparse,hashlib,json,pathlib,shutil,subprocess,sys,tempfile
ap=argparse.ArgumentParser()
ap.add_argument('--root',required=True);ap.add_argument('--evidence',required=True)
args=ap.parse_args()
root=pathlib.Path(args.root).resolve();evidence=pathlib.Path(args.evidence).resolve()
evidence.mkdir(parents=True,exist_ok=False)
sys.path.insert(0,str(root/'CORE'))
from common import Evidence,write_json
from tools import Tools
tools=Tools(root,Evidence(evidence/'tools','native-fixture-regression'))
tools.prepare(required={'godot'})
assert not tools.required_failures(), 'BUNDLED_RUNTIME_UNAVAILABLE'
script=pathlib.Path(__file__).with_suffix('.gd')
current=(root/'GAME/fixtures/fixture.gd').read_text(encoding='utf-8-sig')
guard='fault!="stall" and fault!="loop" and s.scene=="play"'
assert current.count(guard)==1, 'CURRENT_NATIVE_FIXTURE_GUARD_MISSING'
legacy=current.replace(guard,'fault!="stall" and s.scene=="play"')
assert hashlib.sha256(legacy.encode('utf-8')).hexdigest()=='a30bf5c69e9e0d9ba12ff1f2756250d5b5da96c3e9fd12a31ee282dc33dc0bb5', 'LEGACY_CONTROL_IDENTITY'
reports={}
for name,text in [('legacy_negative_control',legacy),('current',current)]:
    with tempfile.TemporaryDirectory(prefix='fullautoqa_native_fixture_') as tmp:
        work=pathlib.Path(tmp)
        for file in ('project.godot','main.tscn'):shutil.copy2(root/'GAME/fixtures'/file,work/file)
        (work/'fixture.gd').write_text(text,encoding='utf-8',newline='\n')
        shutil.copy2(script,work/'probe.gd')
        result=subprocess.run([tools.get('godot'),'--headless','--path',str(work),'--script','res://probe.gd'],capture_output=True,text=True,timeout=60)
        (evidence/(name+'.log')).write_text(result.stdout+'\n'+result.stderr,encoding='utf-8')
        lines=[l for l in result.stdout.splitlines() if l.startswith('NATIVE_FIXTURE_PROBE=')]
        assert len(lines)==1, 'NATIVE_FIXTURE_PROBE_OUTPUT:'+name
        report=json.loads(lines[0].split('=',1)[1]);report['exit_code']=result.returncode;reports[name]=report
        if name=='legacy_negative_control':
            assert result.returncode==2 and [r['fault'] for r in report['rows'] if r['status']=='FAIL']==['loop'], 'LEGACY_LOOP_BUG_NOT_REPRODUCED'
        else:assert result.returncode==0 and all(r['status']=='PASS' for r in report['rows']), 'FIXTURE_FAULT_REGRESSION'
write_json(evidence/'NATIVE_FIXTURE_REGRESSION.json',{'status':'PASS','scope':'fixture unit regression, not real-game E2E','fixture_sha256':hashlib.sha256(current.encode('utf-8')).hexdigest(),'reports':reports})
print('NATIVE_FIXTURE_REGRESSION='+json.dumps(reports))
