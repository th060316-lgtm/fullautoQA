"""Run a declared frozen target sequence from identical Candidate bytes.

Every test starts through START_QA.cmd in a distinct empty extraction. The
technical series result is separate from independent HQ and product acceptance.
"""
import argparse,ctypes,hashlib,json,os,shutil,subprocess,sys,time,uuid,zipfile
from pathlib import Path
OPERATION_LOG=[]

def read(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def write(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2),encoding='utf-8')
def digest(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def persistent_path_snapshot():
    if os.name!='nt':return {'status':'NOT_MEASURED','reason':'WINDOWS_REQUIRED'}
    import winreg
    values={}
    try:
        for label,hive,key in [('user',winreg.HKEY_CURRENT_USER,'Environment'),('machine',winreg.HKEY_LOCAL_MACHINE,r'SYSTEM\CurrentControlSet\Control\Session Manager\Environment')]:
            with winreg.OpenKey(hive,key,0,winreg.KEY_READ) as handle:
                try:value,kind=winreg.QueryValueEx(handle,'Path')
                except FileNotFoundError:value,kind=None,None
            values[label]={'present':value is not None,'registry_type':kind,'sha256':hashlib.sha256(json.dumps(value,ensure_ascii=False).encode('utf-8')).hexdigest()}
        return {'status':'MEASURED','values':values}
    except OSError as ex:return {'status':'NOT_MEASURED','reason':repr(ex)}
def child(root,relative):
    relative=str(relative).replace('\\','/')
    if not relative or relative.startswith('/') or ':' in relative or '..' in Path(relative).parts:raise ValueError('PATH_ESCAPE:'+relative)
    path=(Path(root)/relative).resolve()
    if not path.is_relative_to(Path(root).resolve()):raise ValueError('PATH_ESCAPE:'+relative)
    return path
def extract(archive,destination):
    destination=Path(destination)
    if destination.exists():raise ValueError('EXTRACTION_DESTINATION_NOT_EMPTY')
    destination.mkdir(parents=True)
    with zipfile.ZipFile(archive) as z:
        seen=set()
        for row in z.infolist():
            path=child(destination,row.filename)
            key=str(path).casefold()
            if key in seen or (row.external_attr>>16)&0o170000==0o120000:raise ValueError('UNSAFE_ARCHIVE_ENTRY')
            seen.add(key)
            if row.is_dir():path.mkdir(parents=True,exist_ok=True);continue
            path.parent.mkdir(parents=True,exist_ok=True)
            with z.open(row) as src,path.open('wb') as dst:shutil.copyfileobj(src,dst,1024*1024)

def origin_record(proof):
    origin=proof['origin']
    return {'repository':origin['repository'],'commit':origin['commit'],
            'source_tree':origin.get('source_tree',origin.get('source_tree_sha')),
            'selected_path':origin.get('selected_path',origin.get('source_path'))}

def target_record(root):
    from target_identity import identity_components,sha256_value
    manifest=read(Path(root)/'QA_TARGETS.json')
    if len(manifest['targets'])!=1:raise ValueError('EXPECTED_ONE_SELECTED_TARGET')
    entry=manifest['targets'][0];profile=read(child(root,entry['profile']))
    return {'target_id':entry['id'],'game_id':profile['game_id'],
            'profile_version':profile['profile_version'],'profile_sha256':digest(child(root,entry['profile'])),
            'fingerprint':sha256_value(identity_components(root,entry,profile)),
            'origin':origin_record(read(Path(root)/'TARGET_PREPARATION.json'))}

def compare_records(records,plan,frozen,candidate_sha):
    failures=[]
    if len(records)!=len(plan['series']):failures.append('SERIES_INCOMPLETE')
    for index,row in enumerate(records):
        label=plan['series'][index] if index<len(plan['series']) else None
        expected=frozen.get(label)
        if row.get('target_key')!=label or not expected:failures.append('TARGET_ORDER_MISMATCH');continue
        for key in ('target_id','game_id','profile_version','profile_sha256','fingerprint','origin'):
            if row.get('target',{}).get(key)!=expected[key]:failures.append('TARGET_BINDING_MISMATCH:'+str(index)+':'+key)
        if row.get('candidate_sha256')!=candidate_sha:failures.append('CANDIDATE_IDENTITY_MISMATCH')
        if row.get('required_nonpass') or row.get('start_qa_exit_code')!=0:failures.append('REQUIRED_NONPASS:'+str(index))
        if row.get('archive_integrity')!='PASS' or row.get('diagnostic_archive'):failures.append('EVIDENCE_ARCHIVE_INVALID')
        if row.get('foreign_target_evidence'):failures.append('FOREIGN_TARGET_EVIDENCE')
        if row.get('run_id') in plan.get('historical_run_ids',[]):failures.append('HISTORICAL_RUN_REUSED')
    for key in ('run_id','fresh_extraction_id','evidence_root','execution_root'):
        values=[r.get(key) for r in records]
        if any(not v for v in values) or len(values)!=len(set(values)):failures.append('NON_UNIQUE_'+key.upper())
    return {'technical_series_status':'FAIL' if failures else 'PASS','failures':sorted(set(failures)),
            'final_runs_completed':len(records),'expected_runs':len(plan['series']),
            'independent_hq_final_verdict':'PENDING','human_test':'NOT_RUN',
            'product_acceptance':'HOLD','stable':'HOLD','qa_complete':False}

def summarize_execution_environment(records,plan,base):
    data=dict(base)
    observations=[row.get('environment_observation') or {} for row in records]
    complete=(len(records)==len(plan.get('series',[])) and bool(records))
    data['local_windows_offline']='NOT_VERIFIED'
    data['non_admin_series']='NOT_VERIFIED'
    data['controller_only_series']='NOT_VERIFIED'
    if complete and all(
        (obs.get('network_observation') or {}).get('status')=='MEASURED'
        and (obs.get('network_observation') or {}).get('up_adapter_count')==0
        for obs in observations
    ):
        data['local_windows_offline']='NO_UP_NON_LOOPBACK_INTERFACES_OBSERVED'
    if complete and all(obs.get('admin_status')=='STANDARD_USER' for obs in observations):
        data['non_admin_series']='STANDARD_USER_ALL_RUNS'
    if complete and all(obs.get('automated_controller_marker') is True for obs in observations):
        data['controller_only_series']='AUTOMATED_CONTROLLER_ALL_RUNS'
    data['run_observations']=observations
    return data

def run_logged(argv,cwd,log,timeout=1800,env=None):
    started=time.monotonic();row={'argv':[str(x) for x in argv],'cwd':str(cwd),'log':str(log),'timeout_seconds':timeout}
    row['automated_controller']=bool(env and env.get('FULLAUTOQA_AUTOMATED_CONTROLLER')=='1')
    OPERATION_LOG.append(row)
    with Path(log).open('wb') as stream:
        process=subprocess.Popen([str(x) for x in argv],cwd=cwd,stdout=stream,stderr=subprocess.STDOUT,env=env)
        job=None
        try:
            if os.name=='nt':
                from windows import Job
                job=Job();job.add(process)
            row['exit_code']=process.wait(timeout=timeout)
            return row['exit_code']
        except Exception as ex:
            row['error']=repr(ex)
            raise
        finally:
            if job:job.close()
            if process.poll() is None:process.kill();process.wait(timeout=10)
            row['elapsed_seconds']=time.monotonic()-started

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--candidate',required=True);ap.add_argument('--expected-sha',required=True)
    ap.add_argument('--output',required=True);ap.add_argument('--plan',default=str(Path(__file__).with_name('FINAL_SERIES_PLAN.json')))
    args=ap.parse_args();archive=Path(args.candidate).resolve();output=Path(args.output).resolve()
    if output.exists():raise ValueError('SERIES_OUTPUT_ALREADY_EXISTS')
    output.mkdir(parents=True);bundle=Path(__file__).resolve().parent;controller=bundle.parent
    plan=read(args.plan);records=[];frozen={};sha=args.expected_sha.lower();persistent_before=persistent_path_snapshot()
    elevated=bool(ctypes.windll.shell32.IsUserAnAdmin()) if os.name=='nt' else None
    execution_environment={'os':os.name,'hosted_ci':os.environ.get('GITHUB_ACTIONS')=='true',
                           'elevated':elevated,'local_windows_offline':'NOT_VERIFIED',
                           'non_admin_series':'NOT_VERIFIED','controller_only_series':'NOT_VERIFIED',
                           'human_test':'NOT_RUN'}
    write(output/'EXECUTION_ENVIRONMENT.json',execution_environment)
    sys.path.insert(0,str(controller/'CORE'))
    from common import validate_result_zip
    from run_target import authoritative_result
    try:
        if plan.get('status')!='FINAL_READY':raise ValueError('FINAL_PLAN_NOT_READY')
        if digest(archive)!=sha:raise ValueError('CANDIDATE_SHA_MISMATCH')
        with zipfile.ZipFile(archive) as z:
            if z.testzip() is not None:raise ValueError('CANDIDATE_ARCHIVE_CRC_FAILED')
        write(output/'CANDIDATE_FREEZE.json',{'candidate_sha256':sha,'size':archive.stat().st_size,'plan_sha256':digest(args.plan),'status':'FROZEN_BEFORE_RUN_1','product_acceptance':'HOLD','stable':'HOLD'})
        python=controller/'RUNTIME/python/python.exe'
        # Target identities are calculated before Final Run 1 in disposable
        # preparation roots. No baseline, result, cache or ledger is imported.
        for label in dict.fromkeys(plan['series']):
            item=plan['targets'][label];temp=output/('_freeze_'+label)
            shutil.copytree(controller/'CORE',temp/'CORE')
            helper=child(bundle,item['bundle_path'])/'prepare_target.py'
            code=run_logged([python,'-B','-E','-s',helper,'--candidate-root',temp],controller,output/('freeze_'+label+'.log'))
            if code:raise ValueError('TARGET_FREEZE_FAILED:'+label)
            record=target_record(temp)
            expected={k:item[k] for k in ('repository','commit','source_tree','selected_path')}
            if record['origin']!=expected or record['profile_version']!=item['profile_version']:raise ValueError('TARGET_SOURCE_FREEZE_MISMATCH:'+label)
            frozen[label]=record
            shutil.rmtree(temp)
        write(output/'TARGET_FREEZE.json',frozen)
        for index,label in enumerate(plan['series'],1):
            if digest(archive)!=sha:raise ValueError('CANDIDATE_CHANGED_DURING_SERIES')
            slot=output/('Run'+str(index));slot.mkdir()
            fresh=output/('fresh_'+str(index)+'_'+uuid.uuid4().hex[:8]);extract(archive,fresh)
            py=fresh/'RUNTIME/python/python.exe'
            if (fresh/'QA_BINDINGS.json').exists() or (fresh/'RESULTS/latest.json').exists():raise ValueError('PRISTINE_CANDIDATE_HAS_STALE_BINDING_OR_RESULT')
            integrity=slot/'FRESH_PACKAGE_INTEGRITY.json'
            code=run_logged([py,'-B','-E','-s',fresh/'scripts/package_integrity.py','--root',fresh,'--full-payload','--require-fresh-marker','--json-out',integrity],fresh,slot/'integrity.log')
            if code:raise ValueError('FRESH_PACKAGE_INVALID')
            extraction_id=uuid.uuid4().hex
            (fresh/'PHASE3_FRESH_EXTRACTION.marker').write_text(extraction_id,encoding='ascii')
            item=plan['targets'][label];helper=child(bundle,item['bundle_path'])/'prepare_target.py'
            code=run_logged([py,'-B','-E','-s',helper,'--candidate-root',fresh],fresh,slot/'target_prepare.log')
            if code:raise ValueError('TARGET_PREPARATION_FAILED:'+label)
            target=target_record(fresh)
            if target!=frozen[label]:raise ValueError('TARGET_CHANGED_AFTER_FREEZE')
            shutil.copy2(fresh/'TARGET_PREPARATION.json',slot/'TARGET_PREPARATION.json')
            run_env=os.environ.copy();run_env['FULLAUTOQA_AUTOMATED_CONTROLLER']='1'
            code=run_logged(['cmd.exe','/d','/c','START_QA.cmd'],fresh,slot/'START_QA.log',env=run_env)
            result=authoritative_result(fresh,set())
            validate_result_zip(result,require_manifest=True,expected_run_id=result.parent.name)
            with zipfile.ZipFile(result) as z:
                data=json.loads(z.read('result.json'));identities=data.get('target_identity',{})
                foreign=(set(data.get('versions',{}))!={target['game_id']} or set(identities)!={target['target_id']})
                actual=identities.get(target['target_id'],{})
                if actual.get('fingerprint')!=target['fingerprint']:raise ValueError('RUN_FROZEN_TARGET_MISMATCH')
                baseline_scopes={json.loads(z.read(n)).get('baseline_scope') for n in z.namelist() if n.endswith('_behavioral_regression.json')}
                if baseline_scopes!={'SAME_RUN_SELF_CHECK'}:raise ValueError('UNEXPECTED_BASELINE_PROVENANCE')
                env=json.loads(z.read('phase3_environment.json'))
                if env.get('fresh_extraction_id')!=extraction_id:raise ValueError('FRESH_MARKER_NOT_PROPAGATED')
            saved=slot/'RESULT_FOR_CHATGPT.zip';shutil.copy2(result,saved)
            row={'index':index,'target_key':label,'target':target,'candidate_sha256':sha,
                 'run_id':data['run_id'],'fresh_extraction_id':extraction_id,'evidence_root':str(slot),
                 'execution_root':str(fresh),'result_sha256':digest(saved),'start_qa_exit_code':code,
                 'archive_integrity':'PASS','evidence_missing':0,'diagnostic_archive':bool(data.get('diagnostic_archive')),
                 'foreign_target_evidence':foreign,'required_nonpass':[{'case':r['test_case'],'status':r['status'],'reason':r.get('reason_code')} for r in data['results'] if r.get('gate')=='REQUIRED' and r['status']!='PASS'],
                 'required_counts':{status:sum(r.get('gate')=='REQUIRED' and r['status']==status for r in data['results']) for status in ('PASS','FAIL','NOT_RUN','HARNESS_ERROR','INCONCLUSIVE')},
                 'headquarters':data.get('headquarters'),'completion_certified':data.get('completion_certified'),
                 'human_test_performed':data.get('human_test_performed'),'baseline_provenance':sorted(baseline_scopes),
                 'environment_observation':{
                     'admin_status':env.get('admin_status'),
                     'network_observation':env.get('network_observation'),
                     'automated_controller_marker':env.get('automated_controller_marker'),
                 }}
            records.append(row)
            print('FINAL_RUN_READBACK='+json.dumps({**{k:row[k] for k in ('index','target_key','target','candidate_sha256','run_id','fresh_extraction_id','result_sha256','start_qa_exit_code','archive_integrity','evidence_missing','required_counts','baseline_provenance')},'headquarters':[{'name':x['name'],'status':x['status'],'reason_code':x.get('reason_code')} for x in (row.get('headquarters') or {}).get('domains',[])]},ensure_ascii=True),flush=True)
            write(slot/'RUN_IDENTITY.json',row)
            write(output/'SERIES_RECORDS.json',records)
            if code or row['required_nonpass'] or foreign or row['diagnostic_archive']:raise ValueError('FINAL_RUN_NONPASS:'+str(index))
            # Only this driver's new extraction is removed, after the complete
            # validated evidence archive is retained outside it. No state carries.
            shutil.rmtree(fresh)
        result=compare_records(records,plan,frozen,sha)
    except Exception as ex:
        result=compare_records(records,plan,frozen,sha);result['technical_series_status']='FAIL';result['fatal_error']=repr(ex)
    execution_environment=summarize_execution_environment(records,plan,execution_environment)
    write(output/'EXECUTION_ENVIRONMENT.json',execution_environment)
    persistent_after=persistent_path_snapshot()
    write(output/'PERSISTENT_ENVIRONMENT_READBACK.json',{'scope':'Persistent user and machine PATH values only; not a complete Registry write audit','before':persistent_before,'after':persistent_after,'persistent_path_status':('UNCHANGED' if persistent_before==persistent_after else 'CHANGED_REQUIRES_REVIEW') if persistent_before['status']==persistent_after['status']=='MEASURED' else 'NOT_MEASURED','registry_write_audit':'NOT_RUN'})
    write(output/'OPERATION_LOG.json',{'automated_operations':OPERATION_LOG,'automated_operation_count':len(OPERATION_LOG),'start_qa_invocations':sum('START_QA.cmd' in row['argv'] for row in OPERATION_LOG),'manual_intervention':'NOT_OBSERVED_BY_CONTROLLER','controller_retry_count':0})
    write(output/'SERIES_COMPARISON.json',result);print(json.dumps(result,ensure_ascii=False,indent=2))
    return 0 if result['technical_series_status']=='PASS' else 2

if __name__=='__main__':raise SystemExit(main())
