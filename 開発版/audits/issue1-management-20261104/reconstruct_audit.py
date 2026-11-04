from pathlib import Path
import json,zipfile,hashlib,math,shutil,ast
R=Path(__file__).resolve().parent
B=R.parent/'series/_final_series'
def digest(b):return hashlib.sha256(b).hexdigest()
def read(p):return json.loads(p.read_bytes())
def save(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(d,ensure_ascii=False,indent=2,allow_nan=False))
def provenance(p):return {'path':str(p.relative_to(R.parent)),'sha256':digest(p.read_bytes())}
records=read(B/'SERIES_RECORDS.json')
operation=read(B/'OPERATION_LOG.json')
environment=read(B/'EXECUTION_ENVIRONMENT.json')
persistent=read(B/'PERSISTENT_ENVIRONMENT_READBACK.json')
freeze=read(B/'CANDIDATE_FREEZE.json')
wrapper=R.parent/'series.zip'
wrapper_check=provenance(wrapper)
assert wrapper_check['sha256']=='4556995e91aaf970a29a4b1086f17fd2890a27c020687660ebcf590a5926c00e'
audit={'schema_version':2,'basis':{'repository':'th060316-lgtm/fullautoQA','main':'23e0f3809ecb0da2ab68d62ffee443c68e68e408','workflow_run':41778937797,'artifact_id':13300004174,'artifact':wrapper_check,'candidate_freeze':freeze,'candidate_freeze_provenance':provenance(B/'CANDIDATE_FREEZE.json')},'runs':[],'changes':{'raw_zip_modified':False,'target_modified':False,'main_modified':False,'technical_rerun':False,'stable_promotion':False}}
for i in (1,2,3):
 p=B/f'Run{i}/RESULT_FOR_CHATGPT.zip';before=digest(p.read_bytes());z=zipfile.ZipFile(p);names=z.namelist()
 def member(n):return json.loads(z.read(n))
 def prov(n):return {'archive':str(p.relative_to(R.parent)),'archive_sha256':before,'member':n,'sha256':digest(z.read(n))}
 errors=[]
 if len(names)!=len(set(names)):errors.append('DUPLICATE_PATH')
 for n in names:
  nn=n.replace('\\','/')
  if nn.startswith('/') or '..' in Path(nn).parts or (':' in nn.split('/')[0]):errors.append('PATH_ESCAPE:'+n)
 manifest=member('evidence_manifest.json')
 for m in manifest:
  n=m['file'];b=z.read(n)
  if len(b)!=m['size'] or digest(b)!=m['sha256']:errors.append('SIZE_OR_SHA:'+n)
 unlisted=set(names)-{m['file'] for m in manifest}-{'evidence_manifest.json'}
 if unlisted:errors.append('UNLISTED_MEMBERS:'+str(sorted(unlisted)))
 raw=member('result.json');bundle=member('management_evidence.json');phase=member('phase3_environment.json');repro=member('reproduction.json');record=records[i-1];gid=record['target']['game_id'];profile=gid+'_profile.json';resources=gid+'_resources.json';beh=gid+'.__qa_regression_behavioral_regression.json';perf=gid+'.__qa_regression_performance_regression.json'
 missing=sorted({ref for row in raw['results'] for ref in row.get('evidence',[])}-set(names))
 if missing:errors.append('RESULT_EVIDENCE_MISSING')
 if before!=record['result_sha256']:errors.append('ARCHIVE_SERIES_SHA_MISMATCH')
 if raw['run_id']!=bundle['run_id'] or raw['run_id']!=record['run_id']:errors.append('RUN_ID_MISMATCH')
 required={x['test_case']:x['status'] for x in raw['results'] if x.get('gate')=='REQUIRED'}
 behavior=member(beh);regression=member(perf)
 perfrows=[x for x in raw['results'] if x['test_case'].endswith('.performance_regression')]
 behrows=[x for x in raw['results'] if x['test_case'].endswith('.behavioral_regression')]
 replay=behavior.get('baseline_scope')=='SAME_RUN_SELF_CHECK' and behavior.get('trajectory_equal') is True and behavior.get('actions_equal') is True and bool(behrows) and all(x['status']=='PASS' for x in behrows)
 new=json.loads(json.dumps(bundle));new['reproducibility']={'status':replay,'scope':'same-run profile behavior signature/action trajectory only; not complete-state/all-seed/Profile-order determinism','evidence':[beh,'reproduction.json',profile,'result.json'],'provenance':[prov(beh),prov('reproduction.json'),prov(profile),prov('result.json')]}
 new['provenance']={'derivation':'independent read-only existing-evidence reconstruction','run_id':raw['run_id'],'sources':[prov('management_evidence.json')]}
 for metric,m in new['measurements'].items():
  m['provenance']=[prov('management_evidence.json')]+([prov(resources)] if metric in ('cpu_percent','ram_mb','handles','runtime_seconds') else [])
  m['quality_verdict']='INCONCLUSIVE';m['quality_reason']='NO_AUTHORIZED_ABSOLUTE_THRESHOLD'
 metrics=member(resources)
 recomputed={'ram_mb':max(x['ram'] for x in metrics if isinstance(x.get('ram'),(int,float)))/1048576,'handles':max(x['handles'] for x in metrics if isinstance(x.get('handles'),(int,float))),'runtime_seconds':max(x['sample_time'] for x in metrics)-min(x['sample_time'] for x in metrics)}
 comparison={k:{'recomputed':v,'recorded':bundle['measurements'][k]['value'],'match':math.isclose(v,bundle['measurements'][k]['value'],rel_tol=0,abs_tol=1e-9)} for k,v in recomputed.items()}
 start=[x for x in operation['automated_operations'] if x.get('argv')==['cmd.exe','/d','/c','START_QA.cmd'] and x.get('cwd')==record['execution_root']]
 # Isolated controlled-fault rollback of actual final Profile bytes.
 dst=R/f'rollback/Run{i}';dst.mkdir(parents=True,exist_ok=True)
 profile_bytes=z.read(profile);f=dst/profile;f.write_bytes(profile_bytes);good=digest(f.read_bytes());f.write_bytes(b'controlled isolated corruption');detected=digest(f.read_bytes())!=good;f.write_bytes(profile_bytes)
 profile_rollback={'status':'PASS' if detected and digest(f.read_bytes())==good else 'FAIL','scope':'isolated archived Final Profile byte recovery','sha256':good,'frozen_profile_sha_match':good==record['target']['profile_sha256'],'provenance':[prov(profile)]}
 # ZIP bytes recovered into own copy, original unmodified.
 copy=dst/'evidence.zip';shutil.copyfile(p,copy)
 with copy.open('r+b') as out:out.write(b'BAD!')
 changed=digest(copy.read_bytes())!=before;shutil.copyfile(p,copy);restored=digest(copy.read_bytes())==before;copy.unlink()
 evidence_rollback={'status':'PASS' if changed and restored else 'FAIL','scope':'isolated raw result ZIP bytes recovered; not game re-execution or Stable executable rollback','sha256':before}
 out={
 'index':i,'run_id':raw['run_id'],'target':record['target'],'raw_zip':provenance(p),
 'archive_integrity':{'status':'PASS' if not errors else 'FAIL','manifest_verified':len(manifest),'entries':len(names),'errors':errors,'result_refs_missing':missing,'scope':'all member CRC via ZipFile.read, manifest Size/SHA, names and result refs'},
 'measurements':new['measurements'],'metric_recalculation':{'results':comparison,'provenance':[prov(resources),prov('management_evidence.json')],'cpu_note':'logical CPU count absent; recorded CPU measurement retained without audit-host normalization','disk_note':'pre-seal recorded sizes retained; current ZIP size is a different quantity'},
 'signals':{
 'reproducibility':new['reproducibility'],
 'performance_regression':{'status':'NOT_RUN','value':None,'reason':'PERFORMANCE_LIMITS_NOT_DECLARED; JSON has version/scope only','rows':perfrows,'raw':regression,'provenance':[prov(perf),prov('result.json')]},
 'fresh':{'status':'PASS' if phase.get('fresh_extraction_marker') and phase.get('fresh_extraction_id')==record['fresh_extraction_id'] else 'FAIL','scope':'hosted fresh extraction marker cross-check only','provenance':[prov('phase3_environment.json'),provenance(B/'SERIES_RECORDS.json')]},
 'start_qa':{'status':'PASS' if len(start)==1 and start[0]['exit_code']==0 and phase.get('start_qa_marker') else 'NOT_RUN','wall_seconds':start[0]['elapsed_seconds'] if len(start)==1 else None,'scope':'one successful hosted controller START_QA invocation; not all setup burden','provenance':[provenance(B/'OPERATION_LOG.json'),prov('reproduction.json'),prov('phase3_environment.json')]},
 'manual_intervention':{'status':'NOT_RUN','value':None,'observed':operation['manual_intervention'],'scope':'controller did not observe intervention; global absence unproven','provenance':[provenance(B/'OPERATION_LOG.json')]},
 'no_admin':{'status':'NOT_RUN','value':None,'observed_admin_status':phase['admin_status'],'reason':'ELEVATED run does not establish standard-user completion','provenance':[prov('phase3_environment.json'),provenance(B/'EXECUTION_ENVIRONMENT.json')]},
 'offline':{'status':'NOT_RUN','value':None,'observed':environment['local_windows_offline'],'reason':'hosted CI does not establish local fully offline completion','provenance':[provenance(B/'EXECUTION_ENVIRONMENT.json')]}
 },
 'required_statuses':required,'original_management_status':raw['management_readback']['status'],
 'evaluator_execution':{'status':'EXECUTED','scope':'readback exists; independent from target quality and final Gate acceptance','provenance':[prov('result.json')]},
 'profile_rollback':profile_rollback,'evidence_rollback':evidence_rollback,
 'raw_unchanged':digest(p.read_bytes())==before
 }
 save(R/f'reconstructed/Run{i}/management_evidence.json',new)
 save(R/f'reconstructed/Run{i}/audit.json',out);audit['runs'].append(out);z.close()
a1,a3=audit['runs'][0],audit['runs'][2]
audit['A1_A3']={'same_target_fingerprint':a1['target']['fingerprint']==a3['target']['fingerprint'],'same_profile_sha256':a1['target']['profile_sha256']==a3['target']['profile_sha256'],'required_case_statuses_equal':a1['required_statuses']==a3['required_statuses'],'independent_run_ids':a1['run_id']!=a3['run_id'],'deltas':{m:{'A1':a1['measurements'][m]['value'],'A3':a3['measurements'][m]['value'],'delta':a3['measurements'][m]['value']-a1['measurements'][m]['value'],'quality_verdict':'INCONCLUSIVE','reason':'no authorized tolerance'} for m in a1['measurements']},'scope':'A-B-A Required mapping equivalence only; not all trajectories or seed space','provenance':[provenance(B/'SERIES_RECORDS.json')]}
audit['environment']={'persistent_path':{'status':'PASS' if persistent['before']==persistent['after'] and persistent['persistent_path_status']=='UNCHANGED' else 'FAIL','scope':persistent['scope'],'provenance':[provenance(B/'PERSISTENT_ENVIRONMENT_READBACK.json')]},'registry_global':{'status':'NOT_RUN','observed':persistent['registry_write_audit'],'provenance':[provenance(B/'PERSISTENT_ENVIRONMENT_READBACK.json')]},'manual_operations':{'automated_operation_count':operation['automated_operation_count'],'start_qa_invocations':operation['start_qa_invocations'],'controller_retry_count':operation['controller_retry_count'],'scope':'hosted controller only','provenance':[provenance(B/'OPERATION_LOG.json')]}}
# Re-run the exact current comparator functions without importing production dependencies.
tree=ast.parse((R/'source/hq_evidence.py').read_text())
ns={};exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in ('_as_number','compare_threshold')],type_ignores=[]),'hq_evidence.py','exec'),ns)
audit['nonfinite_probe']={'method':'exact GitHub-main functions extracted by AST, isolated; no production mutation','cases':[],'source':read(R/'source_metadata.json')['hq_evidence.py']}
for v,b,display in [(float('nan'),{'max':1},'NaN <= max1'),(1,{'max':float('nan')},'1 <= maxNaN'),(float('inf'),{'min':0},'+Infinity >= min0')]:
 ok,detail=ns['compare_threshold'](v,b);audit['nonfinite_probe']['cases'].append({'case':display,'observed_comparison_ok':ok,'detail':detail})
# Source rollback means the four audited fixed-main files, not a full runtime.
src=R/'source';target=R/'rollback/source_isolated';shutil.copytree(src,target,dirs_exist_ok=True)
before={p.name:digest(p.read_bytes()) for p in src.glob('*.py')};f=target/'management_evaluator.py';f.write_bytes(b'controlled isolated corruption');detected=digest(f.read_bytes())!=before[f.name];shutil.copytree(src,target,dirs_exist_ok=True)
audit['rollback']={'source':{'status':'PASS' if detected and all(digest((target/n).read_bytes())==h for n,h in before.items()) else 'FAIL','scope':'four audited fixed-main Source files byte recovery, not full runtime function','sha256':before},'candidate':{'status':'NOT_RUN','scope':'package bytes not independently available in this resumed audit; CANDIDATE_FREEZE is metadata only'},'stable_executable':{'status':'NOT_RUN','reason':'fixed-main stable tree0c57de0cfcd945f87bbdd1b793d7edb4436c9813 has README.md only; no executable','verified_via':'GitHub recursive tree of fixed main'}}
audit['requirement_analysis']={'issue':'https://github.com/th060316-lgtm/fullautoQA/issues/1','sections':['C-1','C-2','C-3','G'],'facts':['C-1 requires measurement/regression/Profile bounds or tolerance, and unavailable is not zero/PASS','management_evaluator defaults all six absolute resource quality gates REQUIRED; missing threshold is INCONCLUSIVE and blocks domain'],'inference':'unconditional absolute limit requirement is added beyond Issue wording; separate measurement coverage/evaluator execution/quality outcome/Stable authorization','constraints':['do not change unconfigured resource quality to PASS','keep required measurements and real configured violations strict','preserve performance-quality NOT_RUN when no baseline tolerance exists','same-run behavior reproduction does not certify all seeds/Profile-order reversal']}
audit['management_final_verdict']='NOT_RUN';audit['product_acceptance']='HOLD';audit['stable']='HOLD';audit['release']='HOLD'
save(R/'management_evidence_audit.json',audit)
print(json.dumps({'runs':[(x['run_id'],x['archive_integrity']['status'],x['archive_integrity']['manifest_verified']) for x in audit['runs']],'A1A3':audit['A1_A3']['required_case_statuses_equal'],'management':audit['management_final_verdict'],'raw_unchanged':all(x['raw_unchanged'] for x in audit['runs']),'probe':audit['nonfinite_probe']['cases']},indent=2))

