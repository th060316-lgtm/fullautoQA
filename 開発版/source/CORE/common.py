"""Offline QA primitives. Python standard library only."""
from __future__ import annotations
import hashlib, json, os, time, uuid, zipfile, html, shutil
from urllib.parse import quote
from pathlib import Path
try:
    import hq_report
except Exception:
    hq_report=None
VERSION = '0.3.3-candidate'
SCHEMA = 1
STATUSES = ('PASS','FAIL','INCONCLUSIVE','NOT_RUN','HARNESS_ERROR')
CAPABILITIES = ['one_click','bundled_game','core_integrity','bundled_python','toolchains','technical_qa','game_launch','autoplay','four_agents','stall_detection','crash_detection','verdicts','screenshots','video','state_log','action_log','save_load','soak','regression','evidence_zip','not_run','play_instructions','replace_game_without_core','target_binding','selftest_separation','target_requirements','player_review_packet','historical_regression_scope']

def stamp(): return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
def digest(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()
def write_json(p,v):
    p=Path(p); p.parent.mkdir(parents=True,exist_ok=True)
    tmp=p.with_name(p.name+'.tmp'); tmp.write_text(json.dumps(v,ensure_ascii=False,indent=2),encoding='utf-8'); os.replace(tmp,p)
def read_json(p): return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def inside(root,rel):
    p=(Path(root)/rel).resolve(); root=Path(root).resolve()
    if not p.is_relative_to(root): raise ValueError('PATH_ESCAPE: '+str(rel))
    return p

def extract_zip(src,dst):
    dst=Path(dst); dst.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(src) as z:
        total=sum(i.file_size for i in z.infolist())
        if total>shutil.disk_usage(dst).free-256*1024*1024: raise OSError('DISK_GUARD')
        for i in z.infolist():
            # Reject Windows drives, traversal and symlinks even on a non-Windows build host.
            n=i.filename.replace('\\','/')
            if n.startswith('/') or ':' in n or '..' in Path(n).parts or (i.external_attr>>16)&0o170000==0o120000: raise ValueError('UNSAFE_ARCHIVE')
            inside(dst,n)
        z.extractall(dst)

def verify_core(root):
    root=Path(root); m=read_json(root/'core_manifest.json'); errors=[]
    if m.get('schema_version')!=SCHEMA: errors.append('CORE_SCHEMA_INCOMPATIBLE')
    if m.get('core_version')!=VERSION: errors.append('CORE_VERSION_MISMATCH')
    contract=root/'capability_contract.json'
    if contract.exists():
        declared={v['id'] for v in read_json(contract).get('mandatory_capabilities',[]) if v.get('required')}
        if set(CAPABILITIES)-declared:errors.append('CAPABILITY_CONTRACT_REGRESSION')
    if set(CAPABILITIES)-set(m.get('capabilities',[])): errors.append('CAPABILITY_REGRESSION')
    actual={p.relative_to(root).as_posix() for p in (root/'CORE').rglob('*') if p.is_file() and '__pycache__' not in p.parts}
    expected={f['path'] for f in m['files'] if f['path'].startswith('CORE/')}
    if actual!=expected: errors.append('CORE_FILE_SET_CHANGED')
    for f in m['files']:
        p=inside(root,f['path'])
        if not p.is_file() or p.stat().st_size!=f['size'] or digest(p)!=f['sha256']: errors.append('CORE_HASH_MISMATCH:'+f['path'])
    return errors

class Evidence:
    def __init__(self,root,run_id):
        self.root=Path(root); self.root.mkdir(parents=True,exist_ok=True); self.run_id=run_id; self.seq=0
    def event(self,kind,case='run',**data):
        self.seq+=1; event={'run_id':self.run_id,'event_id':f'E{self.seq:07d}','timestamp':stamp(),'monotonic':time.monotonic(),'test_case':case,'type':kind,**data}
        with (self.root/'events.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(event,ensure_ascii=False)+'\n')
        if kind in ('action','state','process'):
            with (self.root/(kind+'.jsonl')).open('a',encoding='utf-8') as f:f.write(json.dumps(event,ensure_ascii=False)+'\n')
        return event
    def result(self,case,status,reason,evidence=(),severity='INFO',**data):
        if status not in STATUSES: raise ValueError(status)
        gate=data.pop('gate',None) or ('OPTIONAL' if status=='NOT_RUN' else 'REQUIRED')
        if gate not in ('REQUIRED','OPTIONAL','UNSUPPORTED_FOR_PROFILE','INFORMATIONAL'):raise ValueError('INVALID_GATE')
        data['gate']=gate
        files=list(evidence)
        if status=='PASS' and (not files or any(not inside(self.root,p).is_file() for p in files)):
            status='HARNESS_ERROR'; reason='PASS_EVIDENCE_MISSING'
        e=self.event('verdict',case,status=status,reason_code=reason,severity=severity,evidence=files,**data)
        return e
    def manifest(self):
        events=[]
        if (self.root/'events.jsonl').exists():
            for line in (self.root/'events.jsonl').read_text(encoding='utf-8',errors='replace').splitlines():
                try:events.append(json.loads(line))
                except (ValueError,TypeError):pass # retain the original log as evidence
        excluded=[]
        for p in sorted(self.root.rglob('*')):
            if p.is_file() and not archive_eligible(p.relative_to(self.root)):
                excluded.append({'file':p.relative_to(self.root).as_posix(),'size':p.stat().st_size,'sha256':digest(p),'reason':'TRANSIENT_WORK_NOT_EVIDENCE'})
        write_json(self.root/'excluded_work_inventory.json',excluded)
        out=[]
        for p in sorted(self.root.rglob('*')):
            rel=p.relative_to(self.root)
            if not p.is_file() or not archive_eligible(rel) or rel.as_posix()=='evidence_manifest.json':continue
            rel=rel.as_posix();refs=[e for e in events if rel in e.get('evidence',[]) or rel==e.get('file')]
            out.append({'file':rel,'type':p.suffix,'size':p.stat().st_size,'sha256':digest(p),'timestamp':stamp(),'run_id':self.run_id,'event_ids':[e.get('event_id') for e in refs],'test_cases':sorted({e.get('test_case','run') for e in refs})})
        write_json(self.root/'evidence_manifest.json',out);return out

def overall(results):
    required=[r for r in results if r.get('gate','REQUIRED')=='REQUIRED']
    states={r['status'] for r in required}
    if not required:return 'NOT_RUN'
    for status in ('HARNESS_ERROR','FAIL','INCONCLUSIVE'):
        if status in states:return status
    if 'NOT_RUN' in states:return 'HARNESS_ERROR'
    return 'PASS'

def certify(results, required_cases, version, target_satisfied):
    indexed={c:[r for r in results if r['test_case']==c and not r.get('expected_fault')] for c in required_cases}
    return bool(version and target_satisfied and required_cases) and all(len(rows)==1 and rows[0]['status']=='PASS' and rows[0].get('evidence') for rows in indexed.values())

def report(root,data):
    root=Path(root); write_json(root/'result.json',data)
    def cell(r,k):
        if k=='evidence':return '<td>'+', '.join('<a href="'+html.escape(quote(f,safe='/'))+'">'+html.escape(f)+'</a>' for f in r.get('evidence',[]))+'</td>'
        return '<td>'+html.escape(str(r.get(k,'')))+'</td>'
    rows=''.join('<tr>'+''.join(cell(r,k) for k in ('test_case','status','reason_code','severity','evidence'))+'</tr>' for r in data['results'])
    page='<!doctype html><meta charset="utf-8"><title>QA Result</title><style>body{font:16px system-ui;margin:2em;background:#101827;color:#eee}td,th{padding:.5em;border:1px solid #667}table{border-collapse:collapse}a{color:#9cf}</style>'
    page+='<h1>'+html.escape(data['overall'])+'</h1><p>Automated proxy evaluation; no human satisfaction claim.</p><p>Run '+html.escape(data['run_id'])+'</p><table><tr><th>Test</th><th>Status</th><th>Reason</th><th>Severity</th><th>Evidence</th></tr>'+rows+'</table><p><a href="result.json">JSON</a> · <a href="evidence_manifest.json">Evidence manifest</a></p>'
    acceptance=[]
    if 'headquarters' in data:
        hq=data['headquarters']
        acceptance=['QA COMPLETE means processing finished.',
                    'Headquarters Overall: '+str(hq.get('overall','NOT_RUN'))]
        acceptance += [str(domain.get('name'))+': '+str(domain.get('status','NOT_RUN')) for domain in hq.get('domains',[])]
        acceptance += ['Target QA certified: '+str(bool(data.get('target_qa_certified'))),
                       'Completion certified: '+str(bool(data.get('completion_certified'))),
                       'Product Acceptance: HOLD', 'Stable: HOLD']
        page+='<h2>Acceptance status</h2>'+''.join('<p>'+html.escape(line)+'</p>' for line in acceptance)
    for kind,summary in data.get('prototype_results',{}).items():page+='<p>'+html.escape(kind)+': '+html.escape(summary['status'])+'</p>'
    if hq_report is not None:page+=hq_report.readback_html(data)
    if (root/'video.mp4').exists():page+='<h2>Recorded virtual display</h2><video controls width="720" src="video.mp4"></video>'
    (root/'report.html').write_text(page,encoding='utf-8')
    summary_text=f"QA COMPLETE\nOverall Result: {data['overall']}\nRun: {data['run_id']}\nAutomated results only. See report.html and result.json.\n"+'\n'.join(acceptance)+ ('\n' if acceptance else '')
    if hq_report is not None:
        readback=hq_report.readback_text(data)
        if readback:summary_text+=readback+'\n'
    (root/'SUMMARY.txt').write_text(summary_text,encoding='utf-8')

def archive_eligible(rel):
    rel=Path(rel)
    return rel.name!='RESULT_FOR_CHATGPT.zip' and 'WORK' not in rel.parts and 'video_frames' not in rel.parts

def validate_result_zip(path,require_manifest=False,expected_run_id=None):
    with zipfile.ZipFile(path) as z:
        names=z.namelist()
        if len(names)!=len(set(names)):raise OSError('DUPLICATE_ZIP_ENTRY')
        if z.testzip() is not None:raise OSError('RESULT_ZIP_CRC_FAILURE')
        if 'result.json' not in names:raise OSError('RESULT_JSON_MISSING')
        data=json.loads(z.read('result.json').decode('utf-8-sig'))
        if expected_run_id is not None and str(data.get('run_id'))!=str(expected_run_id):raise OSError('RESULT_RUN_ID_MISMATCH')
        manifest=None
        if 'evidence_manifest.json' in names:
            manifest=json.loads(z.read('evidence_manifest.json').decode('utf-8-sig'))
            indexed=[r['file'] for r in manifest]
            if len(indexed)!=len(set(indexed)):raise OSError('MANIFEST_DUPLICATE')
            if set(indexed)!=set(names)-{'evidence_manifest.json'}:raise OSError('MANIFEST_FILE_SET_MISMATCH')
            for row in manifest:
                content=z.read(row['file'])
                if len(content)!=row['size'] or hashlib.sha256(content).hexdigest()!=row['sha256']:raise OSError('EVIDENCE_HASH_MISMATCH:'+row['file'])
        elif require_manifest:raise OSError('EVIDENCE_MANIFEST_MISSING')
        refs=[]
        for row in data.get('results',[]):refs+=row.get('evidence',[])
        if 'events.jsonl' in names:
            for line in z.read('events.jsonl').decode('utf-8',errors='replace').splitlines():
                try:event=json.loads(line)
                except ValueError:continue
                refs+=event.get('evidence',[])
                if event.get('file'):refs.append(event['file'])
        for ref in refs:
            if ref not in names:raise OSError('REFERENCED_EVIDENCE_MISSING:'+ref)
        return {'entries':len(names),'manifest_entries':len(manifest or []),'overall':data.get('overall')}

def result_zip(root,require_manifest=False):
    root=Path(root);temporary=root.parent/(root.name+'_result_'+uuid.uuid4().hex+'.tmp.zip')
    try:
        with zipfile.ZipFile(temporary,'w',zipfile.ZIP_DEFLATED,compresslevel=3) as z:
            for p in sorted(root.rglob('*')):
                if not p.is_file() or p.resolve()==temporary.resolve() or not archive_eligible(p.relative_to(root)):continue
                z.write(p,p.relative_to(root))
        validate_result_zip(temporary,require_manifest)
        os.replace(temporary,root/'RESULT_FOR_CHATGPT.zip')
        return root/'RESULT_FOR_CHATGPT.zip'
    finally:temporary.unlink(missing_ok=True)
