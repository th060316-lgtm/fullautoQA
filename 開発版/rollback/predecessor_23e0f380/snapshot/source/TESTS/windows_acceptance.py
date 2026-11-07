"""Windows desktop reacceptance for the packaged Profile/qa_plan contracts.
Usage: python TESTS/windows_acceptance.py --zip PACKAGE.zip --dest NEW_PREFIX
Non-Windows execution is NOT_RUN and never creates acceptance evidence.
"""
import argparse,base64,hashlib,json,os,subprocess,sys,traceback,zipfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from common import extract_zip,inside,read_json,write_json,validate_result_zip,digest
from contracts import profile_plan

def ps_literal(value):return "'"+str(value).replace("'","''")+"'"

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--zip',required=True);ap.add_argument('--dest',required=True);ap.add_argument('--profile',action='append');ap.add_argument('--seed',type=int,default=12345);ap.add_argument('--timeout',type=int,default=7200);args=ap.parse_args()
    if os.name!='nt':raise SystemExit('NOT_RUN: Windows interactive desktop required')
    archive=Path(args.zip).resolve();base=Path(args.dest).resolve();roots=[base.with_name(base.name+suffix) for suffix in ('_A','_B','_corrupt')]
    if base.exists() or any(root.exists() for root in roots):raise SystemExit('Destination prefix and _A/_B/_corrupt must be NEW paths; no existing content will be deleted')
    gates=[];runs={};summary_path=base.with_name(base.name+'_acceptance.json')
    def gate(name,callback):
        try:
            record=callback();gates.append({'gate':name,'status':'PASS',**(record or {})})
        except Exception as ex:gates.append({'gate':name,'status':'FAIL','error':repr(ex),'traceback':traceback.format_exc()})
    def profiles(root,selected=None):
        settings=read_json(root/'acceptance_manifest.json');directory=inside(root,settings.get('paths',{}).get('profiles','PROFILES'))
        paths=selected or [p.relative_to(root).as_posix() for p in sorted(directory.glob('*.json'))]
        metadata=[(rel,read_json(inside(root,rel))) for rel in paths]
        if not metadata or len({p['game_id'] for _,p in metadata})!=len(metadata):raise ValueError('EMPTY_OR_DUPLICATE_PROFILE_SELECTION')
        for _,p in metadata:profile_plan(p,{'faults':True})
        return metadata
    def execute(root,label,selection=None,prototype=None,start=False,expected='PASS'):
        settings=read_json(root/'acceptance_manifest.json');results=inside(root,settings.get('paths',{}).get('results','RESULTS'));latest=results/'latest.json'
        before=read_json(latest).get('run_id') if latest.exists() else None
        old_zips=set(results.glob('*/RESULT_FOR_CHATGPT.zip')) if results.exists() else set()
        picked=profiles(root,selection)
        if prototype:picked=[item for item in picked if item[1]['prototype_type']==prototype]
        if not picked:raise ValueError('NO_PROFILE_FOR_PROTOTYPE:'+str(prototype))
        # -File cannot bind a string[] reliably through CMD. Fresh-start gates use
        # START_QA.cmd; ordered selection gates use the same BOOTSTRAP via a PS array.
        if start:script='& '+ps_literal(root/'START_SELFTEST.cmd')+' -Seed '+str(args.seed)
        else:
            script='& '+ps_literal(root/'BOOTSTRAP.ps1')+' -Seed '+str(args.seed)+' -Profile @('+','.join(ps_literal(rel) for rel,_ in picked)+')'
            if prototype:script+=' -Prototype '+ps_literal(prototype)
        script+='; exit $LASTEXITCODE'
        encoded=base64.b64encode(script.encode('utf-16-le')).decode('ascii')
        shell=Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
        log=root/('acceptance_'+label+'.log')
        with log.open('wb') as stream:proc=subprocess.run([str(shell),'-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',encoded],cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=args.timeout)
        published=read_json(latest) if latest.exists() else None
        if published and published.get('run_id')!=before:
            path=Path(published['result_zip']).resolve();run=published['run_id']
            if not path.is_relative_to(results.resolve()):raise ValueError('RESULT_ZIP_OUTSIDE_RESULTS')
        elif expected=='HARNESS_ERROR':
            candidates=set(results.glob('*/RESULT_FOR_CHATGPT.zip'))-old_zips
            if len(candidates)!=1:raise ValueError('NO_UNIQUE_NEW_FAILURE_ZIP')
            path=candidates.pop();run=path.parent.name
        else:raise ValueError('NO_NEW_LATEST_RUN')
        validation=validate_result_zip(path,require_manifest=True)
        with zipfile.ZipFile(path) as z:
            data=json.loads(z.read('result.json').decode('utf-8-sig'))
            if data.get('run_id')!=run or data.get('overall')!=expected:raise ValueError('RUN_ID_OR_VERDICT_MISMATCH:'+str(data.get('overall')))
            if expected=='PASS':
                if proc.returncode!=0:raise ValueError('PASS_WITH_NONZERO_EXIT')
                for _,p in picked:
                    plan=profile_plan(p,{'faults':True})
                    for obligation in plan:
                        if obligation['gate']!='REQUIRED':continue
                        rows=[r for r in data['results'] if r['test_case']==obligation['test_case'] and not r.get('expected_fault')]
                        if len(rows)!=1 or rows[0]['status']!='PASS' or rows[0].get('gate')!='REQUIRED':raise ValueError('REQUIRED_CASE_NOT_PASS:'+obligation['test_case'])
                    for fault in p.get('qa_plan',{}).get('faults',[]):
                        detector=next(r for r in data['results'] if r['test_case']==p['game_id']+'.detector.'+fault['id'])
                        proofs=[json.loads(z.read(ref).decode('utf-8-sig')) for ref in detector['evidence'] if ref.endswith('.json')]
                        expected_fault=fault['expected']
                        if not any(proof.get('detected') is True and any(row['status']==expected_fault['status'] and row['reason_code']==expected_fault['reason'] for row in proof.get('raw_verdicts',[])) for proof in proofs):raise ValueError('RAW_FAULT_PROOF_MISSING:'+fault['id'])
                actual=set(data.get('versions',{}))
                if actual!={p['game_id'] for _,p in picked}:raise ValueError('PROFILE_SELECTION_MISMATCH')
            elif proc.returncode==0:raise ValueError('HARNESS_ERROR_WITH_ZERO_EXIT')
        signature=sorted((r['test_case'],r['status'],r['reason_code'],r.get('gate')) for r in data['results'] if r.get('gate')=='REQUIRED')
        runs[label]={'signature':signature,'result_zip':str(path)}
        return {'result_zip':str(path),'zip_sha256':digest(path),'run_id':run,'overall':data['overall'],'exit_code':proc.returncode,'entrypoint':'START_SELFTEST.cmd' if start else 'BOOTSTRAP.ps1 via PowerShell array','profiles':[rel for rel,_ in picked],'zip_validation':validation,'log':str(log)}
    try:
        for root in roots:extract_zip(archive,root)
        a,b,c=roots;selected=profiles(a,args.profile);selection=[rel for rel,_ in selected]
        # Fresh package qualification deliberately exercises bundled self-test fixtures, not target-game certification.
        gate('fresh_extract_A_START',lambda:execute(a,'fresh_A',start=True))
        gate('fresh_extract_B_START',lambda:execute(b,'fresh_B',start=True))
        for kind in ('logic','playable'):
            if any(p['prototype_type']==kind for _,p in selected):gate(kind+'_only',lambda kind=kind:execute(a,kind,selection,kind))
            else:gates.append({'gate':kind+'_only','status':'NOT_RUN','reason':'NO_SELECTED_PROFILE_OF_TYPE'})
        gate('selected_order',lambda:execute(a,'ordered',selection))
        gate('reversed_order',lambda:execute(b,'reversed',list(reversed(selection))))
        def reproducible():
            if runs['ordered']['signature']!=runs['reversed']['signature']:raise ValueError('REQUIRED_VERDICTS_DIFFER_BY_ORDER')
        gate('same_seed_required_reproducibility',reproducible)
        bad=c/'CORE/agents.py';bad.write_bytes(bad.read_bytes()+b'\n# acceptance-only deliberate core corruption\n')
        gate('isolated_core_corruption',lambda:execute(c,'core_corrupt',start=True,expected='HARNESS_ERROR'))
    except Exception as ex:gates.append({'gate':'acceptance_driver','status':'FAIL','error':repr(ex),'traceback':traceback.format_exc()})
    success=bool(gates) and all(g['status']=='PASS' for g in gates)
    write_json(summary_path,{'schema_version':2,'overall':'PASS' if success else 'FAIL','windows_executed':True,'completion_certified':False,'scope':'Packaged native Windows self-test/Profile campaigns; target-game certification is separate and requires QA_TARGETS.json. Missing prototype selections remain NOT_RUN.','package':str(archive),'package_sha256':digest(archive),'seed':args.seed,'selected_profiles':args.profile or 'manifest profiles directory','gates':gates})
    print(str(summary_path));return 0 if success else 2
if __name__=='__main__':raise SystemExit(main())
