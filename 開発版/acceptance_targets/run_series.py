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

def _read_zip_json(zip_path,name):
    try:
        with zipfile.ZipFile(zip_path) as z:
            names=z.namelist()
            for candidate in (name,'evidence/'+name):
                if candidate in names:
                    return json.loads(z.read(candidate).decode('utf-8-sig'))
    except Exception:
        return None
    return None

def _series_review_payload(source,index,label,candidate_sha,target):
    """Return the review payload bound to one Final-series run.

    A bare review file is intentionally not fanned out across A -> B -> A.
    The caller supplies one manifest containing one explicitly bound review
    per run.  Candidate and target identity are checked before the review is
    copied into the fresh extraction, so stale or cross-game human evidence
    cannot silently satisfy a different run.
    """
    if not source:return None
    path=Path(source)
    if not path.is_file():raise ValueError('SERIES_REVIEW_EVIDENCE_MISSING')
    document=read(path)
    if not isinstance(document,dict) or int(document.get('schema_version') or 0)!=1:
        raise ValueError('SERIES_REVIEW_MANIFEST_INVALID')
    entries=document.get('series_reviews')
    if not isinstance(entries,list):raise ValueError('SERIES_REVIEW_MANIFEST_REQUIRED')
    matches=[entry for entry in entries if isinstance(entry,dict)
             and int(entry.get('index') or -1)==int(index)
             and str(entry.get('target_key') or '')==str(label)]
    if not matches:return None
    if len(matches)!=1:raise ValueError('SERIES_REVIEW_BINDING_AMBIGUOUS:'+str(index)+':'+str(label))
    entry=matches[0]
    declared_candidate=str(entry.get('candidate_sha256') or '').lower()
    if declared_candidate!=str(candidate_sha or '').lower():
        raise ValueError('SERIES_REVIEW_CANDIDATE_MISMATCH:'+str(index))
    declared_fingerprint=str(entry.get('target_fingerprint') or '')
    if declared_fingerprint!=str((target or {}).get('fingerprint') or ''):
        raise ValueError('SERIES_REVIEW_TARGET_FINGERPRINT_MISMATCH:'+str(index))
    declared_game=str(entry.get('game_id') or '')
    if declared_game!=str((target or {}).get('game_id') or ''):
        raise ValueError('SERIES_REVIEW_GAME_ID_MISMATCH:'+str(index))
    payload=entry.get('review')
    if not isinstance(payload,dict):raise ValueError('SERIES_REVIEW_PAYLOAD_INVALID:'+str(index))
    payload=dict(payload)
    payload['series_binding']={
        'index':int(index),'target_key':str(label),'candidate_sha256':declared_candidate,
        'target_fingerprint':declared_fingerprint,'game_id':declared_game,
    }
    return payload

def cross_run_reproducibility(records):
    """Independent-run reproducibility observed by the A -> B -> A series.

    A single run can only observe its own seed replay, and the Management
    evaluator explicitly refuses that narrower scope.  The series executes the
    same target twice, so the independent-run observation the gate needs is
    produced here and handed over with an explicit scope.  This is the only
    way the gate can be satisfied: by real evidence, not by relaxing it.

    The observation is fail-closed: it reports ``status=False`` with the
    reasons why whenever the two runs do not agree, whenever a required case
    did not pass, or whenever the series does not contain two independent runs
    of one target at all.
    """
    groups={}
    for row in records or []:
        key=row.get('target_key')
        if not key:continue
        groups.setdefault(key,[]).append(row)
    for key,rows in sorted(groups.items()):
        if len(rows)<2:continue
        first,last=rows[0],rows[-1]
        reasons=[]
        first_digest=first.get('required_case_digest')
        last_digest=last.get('required_case_digest')
        if not first_digest or not last_digest:
            reasons.append('REQUIRED_CASE_DIGEST_ABSENT')
        elif first_digest!=last_digest:
            reasons.append('REQUIRED_CASE_DIGEST_DIVERGED')
        nonpass=list(first.get('required_nonpass') or [])+list(last.get('required_nonpass') or [])
        if nonpass:reasons.append('REQUIRED_CASE_NOT_PASSED')
        first_run,last_run=first.get('run_id'),last.get('run_id')
        if not first_run or not last_run or first_run==last_run:
            reasons.append('CROSS_RUN_SAMPLE_INSUFFICIENT')
        first_extraction,last_extraction=first.get('fresh_extraction_id'),last.get('fresh_extraction_id')
        if not first_extraction or not last_extraction:
            reasons.append('FRESH_EXTRACTION_ID_ABSENT')
        elif first_extraction==last_extraction:
            reasons.append('FRESH_EXTRACTION_NOT_INDEPENDENT')
        first_candidate,last_candidate=first.get('candidate_sha256'),last.get('candidate_sha256')
        if not first_candidate or not last_candidate:
            reasons.append('CANDIDATE_IDENTITY_ABSENT')
        elif first_candidate!=last_candidate:
            reasons.append('CANDIDATE_IDENTITY_DIVERGED')
        first_target=first.get('target') if isinstance(first.get('target'),dict) else {}
        last_target=last.get('target') if isinstance(last.get('target'),dict) else {}
        first_target_fp,last_target_fp=first_target.get('fingerprint'),last_target.get('fingerprint')
        if not first_target_fp or not last_target_fp:
            reasons.append('TARGET_IDENTITY_ABSENT')
        elif first_target_fp!=last_target_fp:
            reasons.append('TARGET_IDENTITY_DIVERGED')
        return {'status':not reasons,'scope':'cross_run_same_target','source':'series_records',
                'target_key':key,'run_ids':[first.get('run_id'),last.get('run_id')],
                'required_case_count':first.get('required_case_count'),
                'evidence':['SERIES_RECORDS.json'],
                'reasons':reasons,
                'detail':('the same target ran in two independent fresh extractions and produced the '
                          'same required outcomes') if not reasons else
                         'the two runs of the same target do not establish reproducibility: '+','.join(reasons)}
    return {'status':False,'scope':'cross_run_same_target','source':'series_records',
            'evidence':['SERIES_RECORDS.json'],'reasons':['CROSS_RUN_SAMPLE_INSUFFICIENT'],
            'detail':'the series does not contain two independent runs of the same target'}

def _domain_payload(report):
    return {'name':report.name,'status':report.status,'reason_code':report.reason_code,
            'gates':list(report.gates),'counts':dict(report.counts),'notes':list(report.notes)}

def _series_domain_status(rows):
    if not rows:return 'NOT_RUN'
    for status in ('HARNESS_ERROR','FAIL','NOT_RUN','INCONCLUSIVE'):
        if any(row.get('status')==status for row in rows):return status
    return 'PASS' if all(row.get('status')=='PASS' for row in rows) else 'NOT_RUN'

def _series_reason(rows,status):
    for row in rows:
        if row.get('status')==status:
            return row.get('reason_code') or row.get('reason')
    return None

def series_hq_readback(records,output,expected_count=None):
    """Evaluate Management and Sales across every completed Final-series run.

    The old implementation re-evaluated only the last run.  That allowed an
    A -> B -> A series to obtain an independent HQ verdict while the B run (or
    the first A run) had unresolved HQ evidence.  Every run is now evaluated
    independently and the series domain passes only when all per-run reports
    pass.  The cross-run reproducibility observation is injected into each
    Management evaluation without weakening any per-run gate.
    """
    if not records:return {'status':'NOT_RUN','reason':'NO_SERIES_RECORDS'}
    controller=Path(__file__).resolve().parent.parent
    core_candidates=[controller/'CORE',controller/'source'/'CORE']
    core_root=next((item for item in core_candidates if item.is_dir()),None)
    if core_root is None:raise RuntimeError('SERIES_HQ_CORE_ROOT_NOT_FOUND')
    core=str(core_root)
    if core not in sys.path:sys.path.insert(0,core)
    from coordinator import CoordinatorContext
    from management_evaluator import evaluate_management
    from sales_evaluator import evaluate_sales

    observation=cross_run_reproducibility(records)
    management_runs=[]
    sales_runs=[]
    for row in records:
        archive=Path(row['evidence_root'])/'RESULT_FOR_CHATGPT.zip'
        base={'index':row.get('index'),'target_key':row.get('target_key'),'run_id':row.get('run_id')}

        management_bundle=_read_zip_json(archive,'management_evidence.json')
        if not isinstance(management_bundle,dict):
            management_runs.append({**base,'name':'management','status':'NOT_RUN',
                                    'reason_code':'MANAGEMENT_EVIDENCE_BUNDLE_UNAVAILABLE'})
        else:
            bundle=dict(management_bundle);bundle['reproducibility']=observation
            context=CoordinatorContext(root=str(output),evidence_root=str(output),results=[],
                                       identity={'target':row.get('target') or {}},
                                       extras={'management_evidence':bundle})
            payload=_domain_payload(evaluate_management(context));payload.update(base)
            management_runs.append(payload)

        sales_bundle=_read_zip_json(archive,'sales_evidence.json')
        if not isinstance(sales_bundle,dict):
            sales_runs.append({**base,'name':'sales','status':'NOT_RUN',
                               'reason_code':'SALES_EVIDENCE_BUNDLE_UNAVAILABLE',
                               'human_test_performed':False})
        else:
            context=CoordinatorContext(root=str(output),evidence_root=str(output),results=[],
                                       identity=None,extras={'sales_evidence':dict(sales_bundle)})
            report=evaluate_sales(context)
            payload=_domain_payload(report);payload.update(base)
            sales_readback=getattr(report,'readback',None) or {}
            payload['human_test_performed']=bool(sales_readback.get('human_test_performed'))
            sales_runs.append(payload)

    management_status=_series_domain_status(management_runs)
    complete=(expected_count is None or len(records)==int(expected_count))

    # Sales is a series-level product gate.  A -> B -> A must cover every
    # distinct target, but the repeated A run exists for stale-state and
    # reproducibility detection; it is not an invented requirement for a
    # duplicate human playtest.  A hard FAIL/HARNESS_ERROR from any actual
    # review is never hidden by another PASS.
    target_keys=[]
    for row in records:
        key=row.get('target_key')
        if key and key not in target_keys:target_keys.append(key)
    sales_targets=[]
    for key in target_keys:
        rows=[item for item in sales_runs if item.get('target_key')==key]
        hard=next((status for status in ('HARNESS_ERROR','FAIL')
                   if any(item.get('status')==status for item in rows)),None)
        passed=[item for item in rows if item.get('status')=='PASS'
                and item.get('human_test_performed') is True]
        if hard:
            status=hard
        elif passed:
            status='PASS'
        elif any(item.get('status')=='INCONCLUSIVE' for item in rows):
            status='INCONCLUSIVE'
        else:
            status='NOT_RUN'
        sales_targets.append({
            'target_key':key,'status':status,
            'reviewed_run_ids':[item.get('run_id') for item in passed],
            'observed_run_ids':[item.get('run_id') for item in rows],
            'reason_code':_series_reason(rows,status),
        })
    sales_status=_series_domain_status(sales_targets)
    sales_human=bool(sales_targets) and all(item.get('status')=='PASS' for item in sales_targets)

    out={'schema_version':3,
         'scope':'series level; Management checks every run plus series reproducibility; Sales requires at least one valid human cold-start review for each distinct target',
         'series_run_ids':[row.get('run_id') for row in records],
         'expected_run_count':expected_count,'observed_run_count':len(records),
         'product_acceptance':'HOLD','stable':'HOLD','human_test':'NOT_RUN'}
    out['management']={'status':management_status,
                       'reason_code':_series_reason(management_runs,management_status),
                       'per_run':management_runs,
                       'reproducibility_observation':observation}
    out['sales']={'status':sales_status,
                  'reason_code':_series_reason(sales_targets,sales_status),
                  'per_run':sales_runs,'per_target':sales_targets,
                  'human_test_performed':sales_human}
    out['human_test']='PASS' if sales_human and complete else 'NOT_RUN'
    satisfied=complete and management_status=='PASS' and sales_status=='PASS'
    out['status']='PASS' if satisfied else 'NOT_PASS'
    if not complete:out['reason']='SERIES_INCOMPLETE_FOR_HQ'
    out['product_acceptance']='HOLD'
    return out

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
    ap.add_argument('--review-evidence',default='',help='Optional schema-v1 series review manifest with one candidate/target-bound review per Final run')
    args=ap.parse_args();archive=Path(args.candidate).resolve();output=Path(args.output).resolve()
    if output.exists():raise ValueError('SERIES_OUTPUT_ALREADY_EXISTS')
    output.mkdir(parents=True);bundle=Path(__file__).resolve().parent;controller=bundle.parent
    core=str(controller/'CORE')
    if core not in sys.path:sys.path.insert(0,core)
    from environment_audit import environment_audit_comparison, environment_audit_snapshot
    plan=read(args.plan);records=[];frozen={};sha=args.expected_sha.lower();persistent_before=persistent_path_snapshot()
    review_evidence=args.review_evidence or ''
    environment_before=environment_audit_snapshot()
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
        review_intake_problems=[]
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
            review_payload=None
            try:
                review_payload=_series_review_payload(review_evidence,index,label,sha,target)
            except Exception as ex:
                review_intake_problems.append({
                    'index':index,'target_key':label,'error':str(ex),
                })
            if review_payload is not None:
                review_dir=fresh/'review_evidence';review_dir.mkdir(parents=True,exist_ok=True)
                review_target=review_dir/'sales_review.json'
                write(review_target,review_payload)
                run_env['FULLAUTOQA_SALES_REVIEW_EVIDENCE']=str(review_target)
            code=run_logged(['cmd.exe','/d','/c','START_QA.cmd'],fresh,slot/'START_QA.log',env=run_env)
            result=authoritative_result(fresh,set())
            validate_result_zip(result,require_manifest=True,expected_run_id=result.parent.name)
            with zipfile.ZipFile(result) as z:
                data=json.loads(z.read('result.json'));identities=data.get('target_identity',{})
                foreign=(set(data.get('versions',{}))!={target['game_id']} or set(identities)!={target['target_id']})
                actual=identities.get(target['target_id'],{})
                if actual.get('fingerprint')!=target['fingerprint']:raise ValueError('RUN_FROZEN_TARGET_MISMATCH')
                required_rows=sorted('%s=%s'%(str(r.get('test_case')),str(r.get('status'))) for r in data['results'] if r.get('gate')=='REQUIRED')
                required_digest=hashlib.sha256('\n'.join(required_rows).encode('utf-8')).hexdigest()
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
                 'required_case_count':len(required_rows),'required_case_digest':required_digest,
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
    environment_after=environment_audit_snapshot()
    write(output/'ENVIRONMENT_AUDIT.json',{'schema_version':1,'before':environment_before,'after':environment_after,'comparison':environment_audit_comparison(environment_before,environment_after)})
    write(output/'PERSISTENT_ENVIRONMENT_READBACK.json',{'scope':'Persistent user and machine PATH values only; not a complete Registry write audit','before':persistent_before,'after':persistent_after,'persistent_path_status':('UNCHANGED' if persistent_before==persistent_after else 'CHANGED_REQUIRES_REVIEW') if persistent_before['status']==persistent_after['status']=='MEASURED' else 'NOT_MEASURED','registry_write_audit':'NOT_RUN'})
    write(output/'OPERATION_LOG.json',{'automated_operations':OPERATION_LOG,'automated_operation_count':len(OPERATION_LOG),'start_qa_invocations':sum('START_QA.cmd' in row['argv'] for row in OPERATION_LOG),'manual_intervention':'NOT_OBSERVED_BY_CONTROLLER','controller_retry_count':0})
    write(output/'SERIES_REVIEW_INTAKE.json',{
        'schema_version':1,'source':review_evidence or None,
        'problems':review_intake_problems if 'review_intake_problems' in locals() else [],
        'status':('INVALID' if ('review_intake_problems' in locals() and review_intake_problems)
                  else ('PRESENT' if review_evidence else 'ABSENT')),
        'product_acceptance':'HOLD','stable':'HOLD',
    })
    hq=series_hq_readback(records,output,expected_count=len(plan.get('series',[])))
    if 'review_intake_problems' in locals() and review_intake_problems:
        hq['sales']['status']='FAIL'
        hq['sales']['reason_code']='SERIES_REVIEW_INTAKE_INVALID'
        hq['sales']['review_intake_problems']=review_intake_problems
        hq['sales']['human_test_performed']=False
        hq['human_test']='NOT_RUN'
        hq['status']='NOT_PASS'
    write(output/'SERIES_HQ_READBACK.json',hq)
    result['independent_hq_final_verdict']=hq.get('status','NOT_RUN')
    result['independent_hq_domains']={'management':hq.get('management',{}).get('status'),'sales':hq.get('sales',{}).get('status')}
    write(output/'SERIES_COMPARISON.json',result);print(json.dumps(result,ensure_ascii=False,indent=2))
    return 0 if result['technical_series_status']=='PASS' else 2

if __name__=='__main__':raise SystemExit(main())
