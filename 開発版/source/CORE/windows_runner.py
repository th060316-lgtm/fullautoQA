from __future__ import annotations
import argparse,copy,os,sys,time,uuid,subprocess,shutil,traceback,json,re,threading
from pathlib import Path
from common import *
from profile import load,condition,get
from observations import observation_condition,predicate_evidence,condition_source
from tools import Tools
from agents import Agent,StallDetector
from adapters import load_adapter,image_features,image_distance
from recording import Recorder,obs_probe,select_recording,tool_requirements,tool_gate,threaded_desktop_recorder
from windows import Desktop,process_metrics,child_pids,Job
from selftest import selftest
from backends import ProcessSupervisor,select_display
from assets import inspect_assets,copy_game
from campaigns import execute_plans,soak_complete,validate_campaigns
from regression import export_baseline,load_baseline,compare,import_baseline
from contracts import profile_plan,audit_plan,prototype_summary
from finalize import finalize_run
from coordinator import prepare_execution,preflight_execution,execution_finalizer
from targets import load_target_manifest,selected_profiles,entry_for_profile,validate_target_profile,required_agents,baseline_source,requirement_coverage,target_scope_satisfied
from collections import deque
from backends import DisplaySampler
from supporting_diagnostics import attach_diagnostics

def finalization_issue(e,results,case,reason,ex):
    try:row=e.result(case,'HARNESS_ERROR',reason,detail=repr(ex),gate='REQUIRED')
    except Exception:row={'test_case':case,'status':'HARNESS_ERROR','reason_code':reason,'detail':repr(ex),'gate':'REQUIRED','evidence':[]}
    results.append(row)

class Session:
    def __init__(self,root,e,tools,profile):
        self.root=Path(root);self.e=e;self.tools=tools;self.p=profile;self.processes=[];self.results=[];self.rec=None;self.desktop=None;self.lock=None;self.failure_times=[];self.metrics=[];self.job=None;self.last_disk_guard=0;self.prepared_work=None;self.performance={};self.comparison_baselines={};self.imported_baselines=None;self.active_supervisor=None;self.sampler=None;self.transitions=[];self.coverage={'agents':set(),'actions':set(),'states':set(),'scenarios':set(),'goals':set(),'test_cases':set()}
    def verdict(self,case,status,reason,files=(),**kw):
        r=self.e.result(case,status,reason,files,**kw);self.results.append(r);self.coverage['test_cases'].add(case)
        if status=='FAIL' and self.rec:self.failure_times.append((case,time.monotonic()-self.rec.started))
        return r
    def command(self,argv,work,label,timeout=90):
        path=self.e.root/(label+'.log');cmd=self.tools.expand(argv,work)
        with path.open('wb') as f:
            job=None;p=None
            try:
                p=subprocess.Popen(cmd,cwd=work,stdout=f,stderr=subprocess.STDOUT,env=self.environment(work))
                if os.name=='nt':job=Job();job.add(p)
                r=p;p.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                if p:p.kill();p.wait(timeout=10)
                self.verdict(label,'FAIL','BUILD_TIMEOUT',[path.name]);return None
            finally:
                if job:job.close()
                if p and p.poll() is None:p.kill();p.wait(timeout=10)
        text=path.read_text(encoding='utf-8',errors='replace')
        ok=r.returncode==0 and not re.search(r'SCRIPT ERROR:|Parse Error:',text)
        self.verdict(label,'PASS' if ok else 'FAIL','COMMAND_OK' if ok else 'BUILD_FAIL',[path.name],exit_code=r.returncode,argv=cmd);return ok
    def environment(self,work):
        env=os.environ.copy();base=Path(work)/'isolated_user'
        for n in ['APPDATA','LOCALAPPDATA','TEMP','TMP','HOME','USERPROFILE']:
            p=base/n;p.mkdir(parents=True,exist_ok=True);env[n]=str(p)
        env['PYTHONNOUSERSITE']='1';env.pop('PYTHONPATH',None)
        system_root=env.get('SystemRoot') or env.get('WINDIR')
        if not system_root:raise OSError('SYSTEM_ROOT_UNAVAILABLE')
        env['PATH']=os.pathsep.join(sorted({str(Path(p).parent) for p in self.tools.paths.values()}))+os.pathsep+str(Path(system_root)/'System32')
        return env
    def copy_game(self,tag):
        src=self.prepared_work or inside(self.root,self.p['source']);dst=self.e.root/'WORK'/tag
        if dst.exists():shutil.rmtree(dst)
        ignored=['.git','__pycache__']
        if self.prepared_work is None:ignored.append('.godot')
        copy_game(src,dst,self.p,ignore=ignored);return dst
    def technical(self,work):
        case=self.p['game_id']+'.source';files=[p for p in Path(work).rglob('*') if p.is_file()]
        inventory=[{'file':p.relative_to(work).as_posix(),'size':p.stat().st_size,'sha256':digest(p)} for p in files]
        name=self.p['game_id']+'_source.json';write_json(self.e.root/name,inventory)
        self.verdict(case,'PASS' if files else 'FAIL','SOURCE_EXISTS' if files else 'MISSING_SOURCE',[name])
        inspection=inspect_assets(work,self.p);missing=inspection['missing']
        name=self.p['game_id']+'_assets.json';write_json(self.e.root/name,inspection)
        self.verdict(self.p['game_id']+'.assets','FAIL' if missing else 'PASS','MISSING_ASSET' if missing else 'ASSET_REFERENCES_EXIST',[name])
        if missing:return False
        build=self.p.get('build')
        if build and not self.command(build['argv'],work,self.p['game_id']+'.build',build.get('timeout',120)):return False
        if not build:self.verdict(self.p['game_id']+'.build','NOT_RUN','NO_BUILD_REQUIRED')
        for t in self.p.get('technical_tests',[]):self.command(t['argv'],work,self.p['game_id']+'.'+t['id'],t.get('timeout',90))
        for kind in ['unit','integration','migration']:
            if not any(x.get('kind')==kind for x in self.p.get('technical_tests',[])):self.verdict(self.p['game_id']+'.'+kind,'NOT_RUN','NO_GAME_TEST_PROVIDED')
        return True
    def start(self,work,scenario,seed):
        if self.p.get('bridge'):
            bridge=inside(work,self.p['bridge'])
            if bridge.exists():bridge.unlink()
        cmd=self.tools.expand(self.p['launch']['argv']+self.p['launch'].get('extra_args',[]),work,self.p)
        cmd=[str(v).replace('{seed}',str(seed)) for v in cmd]
        # seed is expanded after tool tokens by Tools.expand.
        if self.p.get('display',{}).get('kind')=='browser':
            from browser_backend import validate_browser_profile
            browser_target=validate_browser_profile(self.p,work,launch_args=cmd)
            proof=scenario+'_browser_target.json';write_json(self.e.root/proof,browser_target)
            self.e.event('browser_target',scenario,file=proof,target=browser_target)
        out=(self.e.root/(scenario+'_stdout.log')).open('wb');err=(self.e.root/(scenario+'_stderr.log')).open('wb')
        start=time.monotonic();supervisor=ProcessSupervisor();p=supervisor.start(cmd,work,out,err,env=self.environment(work));self.processes.append((p,out,err));self.job=supervisor.job;self.active_supervisor=supervisor
        self.e.event('process',scenario,pid=p.pid,event='start',argv=cmd)
        deadline=time.monotonic()+self.p.get('startup_timeout',30);endpoint=self.p.get('display',{}).get('endpoint')
        if endpoint:
            while not inside(work,endpoint).exists():
                if p.poll() is not None:raise RuntimeError('LAUNCH_EXIT:'+str(p.returncode))
                if time.monotonic()>=deadline:raise TimeoutError('DISPLAY_STARTUP_TIMEOUT')
                time.sleep(.02)
        selected_display=select_display(self.p,work,p);self.desktop=getattr(selected_display,'d',selected_display);selected_display.focus()
        if not self.desktop.state().get('exists'):raise OSError('DISPLAY_NOT_AVAILABLE')
        if self.rec and hasattr(self.rec,'frame'):
            self.sampler=DisplaySampler(self.desktop,self.rec,self.e.root/(scenario+'_continuous.bmp'));self.sampler.start()
        if self.p.get('bridge'):
            while time.monotonic()<deadline:
                path=inside(work,self.p['bridge'])
                if path.exists():
                    try:read_json(path);break
                    except (OSError,ValueError):pass
                time.sleep(.1)
            else:raise TimeoutError('BRIDGE_STARTUP_TIMEOUT')
        self.performance[scenario]={'startup_seconds':time.monotonic()-start}
        self.e.event('process',scenario,pid=p.pid,child_pids=child_pids(p.pid),startup_seconds=time.monotonic()-start,window=self.desktop.state())
        adapter=load_adapter(self.root,self.p,{'desktop':self.desktop,'work':work,'evidence':self.e,'tools':self.tools})
        return p,adapter
    def shot(self,case,event,periodic=False):
        if getattr(self,'disable_capture',False):raise OSError('CAPTURE_INTENTIONALLY_DISABLED')
        name=f'{case}_{event}_{self.e.seq:07d}.bmp';rel=('FULL_EVIDENCE/' if periodic else '')+name
        if (self.active_supervisor and self.active_supervisor.p.poll() is not None) or not self.desktop or not self.desktop.state()['exists']:
            self.e.event('screenshot_unavailable',case,event=event,reason='GAME_WINDOW_UNAVAILABLE')
            return None,None
        try:self.desktop.capture(self.e.root/rel)
        except Exception as ex:
            if self.active_supervisor and self.active_supervisor.p.poll() is not None:
                self.e.event('screenshot_unavailable',case,event=event,reason='GAME_PROCESS_EXITED');return None,None
            self.verdict(case+'.capture','HARNESS_ERROR','SCREEN_CAPTURE_FAILED',detail=repr(ex));return None,None
        self.e.event('screenshot',case,file=rel,event=event)
        if self.rec and hasattr(self.rec,'frame'):self.rec.frame(self.e.root/rel)
        return rel,image_features(self.e.root/rel)
    def observe_features(self,case):
        if getattr(self,'disable_capture',False) or not self.desktop:return None
        if self.active_supervisor and self.active_supervisor.p.poll() is not None:return None
        path=self.e.root/'WORK'/'_agent_observation.bmp';path.parent.mkdir(parents=True,exist_ok=True)
        try:
            self.desktop.capture(path);return image_features(path)
        except Exception as ex:
            self.e.event('observation_unavailable',case,reason='SCREEN_OBSERVATION_FAILED',detail=repr(ex));return None
    def disk_guard(self):
        if time.monotonic()-self.last_disk_guard<1:return
        self.last_disk_guard=time.monotonic()
        free=shutil.disk_usage(self.e.root).free
        size=tree_size(self.e.root,tolerate_excluded_vanish=True)
        if free<self.p.get('disk_reserve_mb',512)*1024*1024 or size>self.p.get('evidence_limit_mb',8192)*1024*1024:raise OSError('DISK_GUARD_STOP')
    def monitor(self,p,case):
        metrics=process_metrics(p.pid) if os.name=='nt' else self.active_supervisor.metrics();metrics['harness']=process_metrics(os.getpid());metrics['video']=process_metrics(self.rec.p.pid) if self.rec and self.rec.p else {};metrics['log_size']=sum(x.stat().st_size for x in self.e.root.glob('*.log'));save_name=self.p.get('save',{}).get('file');metrics['save_size']=sum(x.stat().st_size for x in (self.e.root/'WORK').glob('*/'+save_name) if x.is_file()) if save_name else None;metrics.update({'timestamp':stamp(),'sample_time':time.monotonic(),'child_pids':child_pids(p.pid),'exit_code':p.poll()});self.metrics.append(metrics)
        if len(self.metrics)>4096:del self.metrics[:-4096]
        self.e.event('process',case,**metrics);return metrics
    def stop(self):
        if self.sampler:
            try:
                sampling=self.sampler.stop();proof='capture_'+str(self.e.seq)+'.json';write_json(self.e.root/proof,sampling)
                if sampling['error'] and self.active_supervisor and self.active_supervisor.p.poll() is None:self.verdict('capture.worker','HARNESS_ERROR','RECORDING_CAPTURE_FAILED',[proof])
            except Exception as ex:
                proof='capture_cleanup_error_'+str(self.e.seq)+'.json';write_json(self.e.root/proof,{'error':repr(ex)});self.verdict('capture.cleanup','HARNESS_ERROR','CAPTURE_CLEANUP_FAILED',[proof])
            finally:self.sampler=None
        if self.desktop:
            try:self.desktop.release()
            except Exception:pass
            try:
                if hasattr(self.desktop,'close'):self.desktop.close()
            except Exception:pass
        for p,out,err in self.processes:
            if p.poll() is None:
                try:
                    if os.name=='nt':subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),'/PID',str(p.pid),'/T','/F'],capture_output=True,timeout=15)
                    else:p.terminate();p.wait(timeout=5)
                except Exception:
                    try:p.kill();p.wait(timeout=5)
                    except Exception:pass
            out.close();err.close();self.e.event('process',pid=p.pid,event='stop',exit_code=p.poll())
        if self.active_supervisor:self.active_supervisor.stop();self.active_supervisor=None
        self.processes.clear()
        if self.job:self.job.close();self.job=None
    def snapshot_save(self,work):
        cfg=self.p.get('save')
        if not cfg:return None
        return inside(work,cfg['file'])
    def save_load(self,work,a,case):
        cfg=self.p.get('save')
        if not cfg:
            self.verdict(case+'.save_load','NOT_RUN','SAVE_NOT_SUPPORTED');return
        file=self.snapshot_save(work);before=a.observe()['internal_state'];old=digest(file) if file.exists() else None;previous=file.stat().st_mtime_ns if file.exists() else None
        storage_cfg=self.p.get('storage') or {};storage_inspector=None;storage_pre=None;storage_saved=None;storage_mutated=None
        storage_gate='REQUIRED' if storage_cfg.get('required') else 'OPTIONAL'
        if storage_cfg.get('locations'):
            try:
                from storage_qa import StorageInspector
                storage_root=inside(work,storage_cfg.get('root','isolated_user'))
                storage_inspector=StorageInspector(storage_root,storage_cfg.get('locations'))
                storage_pre=storage_inspector.snapshot('pre_save')
            except Exception as ex:
                proof=case+'_storage_unavailable.json';write_json(self.e.root/proof,{'error':repr(ex),'config':storage_cfg})
                self.verdict(case+'.storage','NOT_RUN','STORAGE_UNAVAILABLE',[proof],gate=storage_gate)
        else:self.verdict(case+'.storage','NOT_RUN','NO_STORAGE_CONTRACT',gate='OPTIONAL')
        a.act(cfg.get('save_action','save'));time.sleep(.3);saved=a.observe()['internal_state'];shot,_=self.shot(case,'save')
        if storage_inspector:
            try:storage_saved=storage_inspector.snapshot('post_save')
            except Exception as ex:
                proof=case+'_storage_save_error.json';write_json(self.e.root/proof,{'error':repr(ex)})
                self.verdict(case+'.storage','NOT_RUN','STORAGE_POST_SAVE_UNAVAILABLE',[proof],gate=storage_gate);storage_inspector=None
        if not file.exists() or (previous is not None and file.stat().st_mtime_ns==previous):
            self.verdict(case+'.save','FAIL','SAVE_FAIL',[shot] if shot else [],severity='MAJOR');return
        copyfile=self.e.root/(case+'_save_copy.json');shutil.copy2(file,copyfile)
        save_event=self.e.event('save',case,file=copyfile.name,previous_hash=old,hash=digest(file))
        a.act(cfg.get('mutate_action','confirm'));time.sleep(.2)
        mutated=a.observe()['internal_state']
        if storage_inspector:
            try:storage_mutated=storage_inspector.snapshot('post_mutation')
            except Exception as ex:
                proof=case+'_storage_mutation_error.json';write_json(self.e.root/proof,{'error':repr(ex)})
                self.verdict(case+'.storage','NOT_RUN','STORAGE_POST_MUTATION_UNAVAILABLE',[proof],gate=storage_gate);storage_inspector=None
        fields=cfg.get('state_fields',[])
        state_mutated=bool(fields) and any(get(mutated,f)!=get(saved,f) for f in fields)
        if not state_mutated:
            self.verdict(case+'.restore','INCONCLUSIVE','SAVE_STATE_NOT_MUTATED',[copyfile.name])
            # Declared storage QA is independent of an internal bridge. If storage
            # is observable, continue through load and judge storage restoration.
            if not storage_inspector:return
        a.act(cfg.get('load_action','load'));time.sleep(.3);restored=a.observe()['internal_state'];shot2,_=self.shot(case,'load')
        storage_result=None;storage_name=None
        if storage_inspector:
            try:
                storage_loaded=storage_inspector.snapshot('post_load')
                storage_result=storage_inspector.check_persistence(storage_pre,storage_saved,storage_mutated,storage_loaded,contract=storage_cfg.get('contract','disk_restore'),state_mutated=state_mutated,state_restored=bool(fields) and all(get(restored,f)==get(saved,f) for f in fields))
                storage_name=case+'_storage_qa.json';write_json(self.e.root/storage_name,{'config':storage_cfg,'pre_save':storage_pre.to_dict(),'post_save':storage_saved.to_dict(),'post_mutation':storage_mutated.to_dict(),'post_load':storage_loaded.to_dict(),'result':storage_result})
                self.verdict(case+'.storage',storage_result['status'],storage_result['reason_code'],[storage_name],gate=storage_gate)
            except Exception as ex:
                proof=case+'_storage_load_error.json';write_json(self.e.root/proof,{'error':repr(ex)})
                self.verdict(case+'.storage','NOT_RUN','STORAGE_POST_LOAD_UNAVAILABLE',[proof],gate=storage_gate)
        name=case+'_save_load.json';write_json(self.e.root/name,{'before':before,'saved':saved,'mutated':mutated,'restored':restored,'fields':fields,'state_mutated_before_load':state_mutated,'storage_evidence':storage_name})
        if state_mutated:
            ok=all(get(restored,f)==get(saved,f) for f in fields)
            self.verdict(case+'.save_load','PASS' if ok else 'FAIL','STATE_RESTORED' if ok else 'SAVE_MISMATCH',[name,copyfile.name]+[x for x in [shot,shot2] if x],severity='INFO' if ok else 'MAJOR')
        else:
            self.verdict(case+'.save_load','INCONCLUSIVE','STATE_RESTORE_UNVERIFIED',[name,copyfile.name]+[x for x in [shot,shot2] if x])
        # Only the per-run working copy is ever corrupted.
        original=file.read_bytes()
        try:
            file.write_text('{invalid save',encoding='utf-8');a.act(cfg.get('load_action','load'));time.sleep(.3);rejected=a.observe()['internal_state']
            expected=cfg.get('invalid_expected');name=case+'_invalid_save.json';write_json(self.e.root/name,rejected)
            self.verdict(case+'.invalid_save','PASS' if expected and condition(rejected,expected) else 'INCONCLUSIVE','INVALID_SAVE_REJECTED' if expected and condition(rejected,expected) else 'INVALID_SAVE_OUTCOME_UNSPECIFIED',[name])
        finally:file.write_bytes(original)
        self.verdict(case+'.multiple_slot','NOT_RUN','NO_MULTIPLE_SLOT_CONTRACT')
        self.verdict(case+'.autosave','NOT_RUN','NO_AUTOSAVE_CONTRACT')
        baseline=cfg.get('baseline')
        if baseline:
            original=file.read_bytes()
            try:
                shutil.copy2(inside(self.root,baseline),file);a.act(cfg.get('load_action','load'));time.sleep(.3);state=a.observe()['internal_state'];checks=cfg.get('migration_expected',[]);ok=bool(checks) and all(condition(state,c) for c in checks)
                name=case+'_migration.json';write_json(self.e.root/name,{'state':state,'baseline':baseline,'checks':checks});self.verdict(case+'.migration','PASS' if ok else 'FAIL' if checks else 'INCONCLUSIVE','MIGRATION_RESTORED' if ok else 'MIGRATION_UNVERIFIED',[name])
            finally:file.write_bytes(original)
        else:self.verdict(case+'.save_migration','NOT_RUN','BASELINE_SAVE_NOT_PROVIDED')
    def storage_scenarios(self,work,case,seed,p,a):
        from storage_qa import StorageInspector,STORAGE_FEATURES,run_storage_scenario
        cfg=self.p.get('storage') or {};declared=cfg.get('scenarios') or []
        if not isinstance(declared,list):raise ValueError('STORAGE_SCENARIOS_INVALID')
        ids=[str(row.get('id',row.get('feature'))) for row in declared]
        if len(ids)!=len(set(ids)):raise ValueError('STORAGE_SCENARIO_ID_COLLISION')
        represented={row.get('feature') for row in declared}
        for feature in STORAGE_FEATURES:
            if feature not in represented:
                proof=case+'_storage_'+feature+'.json';write_json(self.e.root/proof,{'feature':feature,'supported':False,'scope':'No declared executable contract'})
                self.verdict(case+'.storage.'+feature,'NOT_RUN','STORAGE_SCENARIO_NOT_DECLARED',[proof],gate='OPTIONAL')
        active={'process':p,'adapter':a}
        def observe():
            if active['process'].poll() is not None:raise RuntimeError('STORAGE_PROCESS_EXITED')
            state=active['adapter'].observe()['internal_state'];self.e.event('state',case,internal_state=state,reason='declared_storage_scenario');return state
        def act(action):
            if action not in self.p['actions']:raise ValueError('STORAGE_ACTION_UNDECLARED:'+str(action))
            before=observe();active['adapter'].act(action);time.sleep(cfg.get('observation_delay',.3));after=observe()
            self.e.event('action',case,agent='StorageContract',action=action,input=self.p['actions'][action].get('inputs'),target=self.p['actions'][action].get('target'),reason='declared_storage_scenario',result={'before':before,'after':after},seed=seed)
        def restart():
            previous=active['process'];active['adapter'].close();self.stop()
            process,adapter=self.start(work,case+'_storage_restart_'+str(time.monotonic_ns()),seed);active.update(process=process,adapter=adapter)
            proof={'before_pid':previous.pid,'after_pid':process.pid,'before_exited':previous.poll() is not None};self.e.event('storage_restart',case,**proof);return proof
        for row in declared:
            proof=case+'_storage_'+str(row.get('id',row.get('feature')))+'.json';gate='REQUIRED' if row.get('required') else 'OPTIONAL'
            try:
                inspector=StorageInspector(inside(work,cfg.get('root','isolated_user')),cfg.get('locations'))
                outcome=run_storage_scenario(inspector,row,act=act,observe=observe,restart=restart,fixture_root=self.root,condition=condition)
            except Exception as ex:outcome={'status':'NOT_RUN','reason_code':'STORAGE_UNAVAILABLE','error':repr(ex)}
            write_json(self.e.root/proof,{'contract':row,'result':outcome});self.verdict(case+'.storage.'+str(row.get('id',row.get('feature'))),outcome['status'],outcome['reason_code'],[proof],gate=gate)
        return active['process'],active['adapter']
    def crash_observed(self,p,case,history):
        code=p.poll()
        if code is None:return False
        shot,_=self.shot(case,'crash');name=case+'_crash.json'
        write_json(self.e.root/name,{'exit_code':code,'unexpected':True,'action_sequence':list(history)})
        self.verdict(case+'.crash','FAIL','CRASH',[name,case+'_stderr.log']+([shot] if shot else []),severity='CRITICAL')
        return True

    def run_scenario(self,s,seed,replay=None):
        case=self.p['game_id']+'.'+s['id'];work=self.copy_game(case);agent=Agent(self.p,s,seed);self.coverage['scenarios'].add(case)
        write_json(self.e.root/'journal.json',{'run_id':self.e.run_id,'current_profile':self.p['game_id'],'scenario':s['id'],'seed':seed,'state':'running','resume_policy':'restart_current_scenario_from_pristine_copy'})
        p=None;a=None;shots=[];observed=deque(maxlen=s.get('memory_limit',1024)) if s.get('soak') else [];self.transitions=[];features=None;start=time.monotonic();last_shot=0;last_monitor=0;recovery=0
        try:
            if s.get('missing_asset'):
                missing=inside(work,s['missing_asset']);missing.unlink(missing_ok=True);proof=case+'_assets.json';inspection=inspect_assets(work,self.p);write_json(self.e.root/proof,inspection);self.verdict(case+'.assets','FAIL' if inspection['missing'] else 'HARNESS_ERROR','MISSING_ASSET' if inspection['missing'] else 'FAULT_ASSET_NOT_REQUIRED',[proof]);return agent.export(),list(observed)
            p,a=self.start(work,case,seed);caps=a.capabilities();write_json(self.e.root/(case+'_capabilities.json'),caps)
            agent.started=time.monotonic();play_started=agent.started
            shot,features=self.shot(case,'start');shots += [shot] if shot else []
            self.verdict(case+'.launch','PASS' if shot else 'HARNESS_ERROR','WINDOW_AND_PROCESS_STARTED' if shot else 'SCREEN_CAPTURE_FAILED',shots+[case+'_stdout.log',case+'_stderr.log'])
            for capability in ('ocr','audio','gamepad'):
                if not caps.get(capability):self.verdict(case+'.'+capability,'NOT_RUN','CAPABILITY_UNAVAILABLE')
            stall=StallDetector(s.get('stall_seconds',self.p.get('stall_seconds',8)));goal=next((g for g in self.p['goals'] if g['id']==s.get('goal')),None)
            goal_reached=False;iterations=0;replay_index=0
            observational=not bool(self.p.get('bridge')) or bool(s.get('observational_learning'))
            while not agent.exhausted():
                if s.get('soak') and soak_complete(time.monotonic()-play_started,iterations,s,p.poll() is None):break
                self.disk_guard();now=time.monotonic()
                if p.poll() is not None:
                    shot,_=self.shot(case,'crash');name=case+'_crash.json';write_json(self.e.root/name,{'exit_code':p.returncode,'unexpected':True,'action_sequence':agent.history})
                    self.verdict(case+'.crash','FAIL','CRASH',[name,case+'_stderr.log'],severity='CRITICAL');return agent.export(),list(observed)
                obs=a.observe();state=obs['internal_state'];observed.append(state);self.coverage['states'].add(agent.signature(state))
                if s.get('soak') and len(self.coverage['states'])>s.get('memory_limit',1024):self.coverage['states'].pop()
                self.e.event('state',case,current_state=state,internal_state=state,observation_status=obs.get('observation_status'),external_observations=obs.get('external_observations'),ocr=obs.get('ocr'),window=obs['window'],scene=obs.get('scene'),goal_progress=condition(state,goal) if goal else None)
                if not obs['window']['exists']:
                    wins=self.desktop.windows(child_pids(p.pid))
                    if wins:self.desktop.hwnd=wins[0][0]
                    else:
                        # A window can disappear just before the process exit is
                        # observable. Never certify execution from the stale bridge.
                        try:p.wait(timeout=.5)
                        except subprocess.TimeoutExpired:pass
                        if self.crash_observed(p,case,agent.history):return agent.export(),list(observed)
                        self.verdict(case+'.window','INCONCLUSIVE','WINDOW_DISAPPEARED',shots);break
                if not obs['window'].get('focused'):self.desktop.focus();self.e.event('recovery',case,method='refocus')
                for error in self.p.get('error_states',[]):
                    if condition(state,error):
                        sh,_=self.shot(case,'failure');self.verdict(case+'.invariant','FAIL',error.get('reason','FORBIDDEN_STATE'),[sh] if sh else [],severity='MAJOR')
                if goal and condition(state,goal):
                    if not goal_reached:
                        sh,_=self.shot(case,'goal');name=case+'_goal.json';write_json(self.e.root/name,{'goal':goal,'state':state,'agent_assessment':agent.goal_assessment(True)});self.verdict(case+'.goal','PASS','GOAL_REACHED',[name]+([sh] if sh else []));self.coverage['goals'].add(goal['id']);goal_reached=True
                    if s.get('stop_on_goal',True) and replay is None:break
                if now-last_monitor>=1:self.monitor(p,case);last_monitor=now
                if now-last_shot>=s.get('screenshot_interval',self.p.get('screenshot_interval',3)):
                    _,newfeatures=self.shot(case,'periodic',True)
                    self.e.event('screen_change',case,distance=image_distance(features,newfeatures) if features and newfeatures else None)
                    features=newfeatures;last_shot=now
                wait=any(condition(state,c) for c in self.p.get('normal_wait_states',[]))
                warning=stall.observe(now,agent.signature(state),tuple(features) if features else None,agent.history[-1] if agent.history else None,wait,reaction=state.get('reaction'))
                if warning:
                    sh,_=self.shot(case,'stall');name=case+'_stall.json';write_json(self.e.root/name,{'state':state,'history':agent.history,'recovery':recovery})
                    if recovery<s.get('recovery_attempts',2):
                        recovery+=1;self.desktop.focus()
                        if 'cancel' in self.p['actions']:a.act('cancel')
                        agent.mode='Explorer';self.e.event('recovery',case,method='refocus_cancel_explore',evidence=[name]);stall=StallDetector(s.get('stall_seconds',self.p.get('stall_seconds',8)))
                    else:
                        self.verdict(case+'.stall','FAIL',warning,[name]+([sh] if sh else []),severity='MAJOR');break
                screen_before=self.observe_features(case) if observational else None
                if replay is not None:
                    if replay_index>=len(replay):break
                    action=replay[replay_index];replay_index+=1;agent.history.append(action);agent.total_actions+=1
                    agent.action_modes.append('Replay');agent.actions_by_mode['Replay']+=1
                else:
                    prior_loops=agent.loops;action=agent.choose(state,screen=screen_before)
                    if agent.loops>prior_loops:
                        name=case+'_action_loop_'+str(agent.loops)+'.json';write_json(self.e.root/name,{'history':agent.history,'strategy':agent.mode,'loop_count':agent.loops})
                        self.e.event('strategy_change',case,reason_code='ACTION_LOOP',strategy=agent.mode,evidence=[name])
                        if prior_loops==0:self.verdict(case+'.agent_loop','FAIL' if s.get('loop_failure') else 'INCONCLUSIVE','ACTION_LOOP',[name],gate='REQUIRED' if s.get('loop_failure') else 'INFORMATIONAL',recovery='Explorer fallback')
                        if s.get('loop_failure'):break
                before=state;tick=time.monotonic();a.act(action);time.sleep(s.get('observation_delay',.15));after=a.observe()['internal_state'];observed.append(after)
                screen_after=self.observe_features(case) if observational else None
                agent.feedback(before,after,action,screen_before=screen_before,screen_after=screen_after);iterations+=1
                if screen_after is not None:features=screen_after
                if not s.get('soak'):self.transitions.append(after)
                self.coverage['agents'].update(k for k,v in agent.actions_by_mode.items() if v and k!='Replay');self.coverage['actions'].add(action);self.e.event('action',case,agent=agent.action_modes[-1],action=action,input=self.p['actions'][action].get('inputs'),target=self.p['actions'][action].get('target'),reason='replay' if replay is not None else s['agent'],result={'changed':agent.signature(before)!=agent.signature(after),'response_delay_upper_bound_seconds':time.monotonic()-tick},seed=seed)
            if self.crash_observed(p,case,agent.history):return agent.export(),list(observed)
            if goal and not goal_reached:
                # Observe once more: the final budgeted action may itself complete the goal.
                final=a.observe()['internal_state']
                if condition(final,goal):
                    goal_reached=True;name=case+'_goal.json';write_json(self.e.root/name,{'goal':goal,'state':final,'agent_assessment':agent.goal_assessment(True)});self.verdict(case+'.goal','PASS','GOAL_REACHED',[name]);self.coverage['goals'].add(goal['id'])
                else:self.verdict(case+'.goal','INCONCLUSIVE','GOAL_NOT_REACHED',shots,agent_budget_exhausted=True)
            if goal:
                assessment=agent.goal_assessment(goal_reached)
                proof=case+'_goal_agent.json';write_json(self.e.root/proof,assessment)
                self.verdict(case+'.goal_agent',assessment['status'],assessment['reason_code'],[proof],gate='REQUIRED' if case+'.goal_agent' in getattr(self,'required_cases',[]) else 'INFORMATIONAL',claim=assessment['scope'])
            if not goal:
                name=case+'_execution.json';write_json(self.e.root/name,{'actions':iterations,'final_state':a.observe(),'duration':time.monotonic()-start})
                self.verdict(case+'.execution','PASS' if iterations else 'INCONCLUSIVE','ACTIONS_EXECUTED' if iterations else 'NO_ACTIONS_EXECUTED',[name])
            if s.get('soak'):
                elapsed=time.monotonic()-play_started;proof=case+'_soak.json';complete=soak_complete(elapsed,iterations,s,p.poll() is None);write_json(self.e.root/proof,{'elapsed_seconds':elapsed,'requested_seconds':s.get('soak_seconds',0),'actions':iterations,'requested_loops':s.get('soak_loops',0),'alive':p.poll() is None,'budget_exhausted':agent.exhausted(),'memory_limit':s.get('memory_limit',1024),'retained_states':len(observed),'full_samples':'state.jsonl/process.jsonl','completion':complete});self.verdict(case+'.soak','PASS' if complete else 'INCONCLUSIVE','SOAK_TARGET_REACHED' if complete else 'SOAK_INCOMPLETE',[proof])
            if s.get('save_load'):self.save_load(work,a,case)
            if s.get('retry_test'):
                cfg=s['retry_test'];a.act(cfg['fail_action']);time.sleep(.1);failed=a.observe()['internal_state'];a.act(cfg['retry_action']);time.sleep(.1);restored=a.observe()['internal_state'];proof=case+'_retry.json';write_json(self.e.root/proof,{'failed':failed,'recovered':restored,'contract':cfg});ok=condition(failed,cfg['failed']) and condition(restored,cfg['recovered']);self.verdict(case+'.retry','PASS' if ok else 'FAIL','FAILURE_RETRY_VERIFIED' if ok else 'FAILURE_RETRY_MISMATCH',[proof])
            for test in self.p.get('tests',[]):
                if test.get('scenario')!=s['id']:continue
                test_observation=a.observe();ok=observation_condition(test_observation,test['expect'],self.e.root);name=case+'_'+test['id']+'.json';proof=predicate_evidence(test_observation,test['expect'],self.e.root);write_json(self.e.root/name,proof)
                external=condition_source(test['expect'])=='external_observations'
                self.verdict(case+'.'+test['id'],'PASS' if ok else 'FAIL',('EXTERNAL_OBSERVATION_CHECK' if external else 'EXPECTED_STATE') if ok else test.get('reason','STATE_MISMATCH'),[name],severity='INFO' if ok else 'MAJOR',observation_source=condition_source(test['expect']),claim_scope=proof.get('claim_scope','internal_game_state'),semantic_game_outcome='UNVERIFIED' if external else 'PROFILE_EXPECTATION_ONLY')
            if s.get('evaluation'):
                elapsed=time.monotonic()-start;name=case+'_proxy_evaluation.json';write_json(self.e.root/name,{'elapsed':elapsed,'action_count':iterations,'observed_states':len(set(agent.signature(x) for x in observed)),'human_test':False,'cognitive_readability_verified':False})
                self.verdict(case+'.30s','INCONCLUSIVE' if elapsed>=30 else 'NOT_RUN','READABILITY_REQUIRES_VALIDATED_PROXY' if elapsed>=30 else 'OBSERVATION_UNDER_30_SECONDS',[name],gate='OPTIONAL')
                changed=sum(agent.success.values());ok=elapsed>=300 and changed>=10
                self.verdict(case+'.5m','PASS' if ok else 'INCONCLUSIVE','AUTOMATED_ACTION_REACTION_CYCLES' if ok else 'INSUFFICIENT_FIVE_MINUTE_EVIDENCE',[name],claim='Automated proxy cycles only; does not establish enjoyment or comprehension')
            # Error log detection uses profile patterns; engine errors are independent of GUI progress.
            for _,out,err in self.processes:out.flush();err.flush()
            text=(self.e.root/(case+'_stderr.log')).read_text(encoding='utf-8',errors='replace')
            if re.search(self.p.get('fatal_log_pattern',r'SCRIPT ERROR:|FATAL|Unhandled Exception'),text):self.verdict(case+'.runtime_log','FAIL','FATAL_ERROR_LOG',[case+'_stderr.log'],severity='CRITICAL')
            sh,_=self.shot(case,'finish')
            final=a.observe()['internal_state'];observed.append(final)
            self.checkpoint(s,seed,case,final,agent.history,sh)
            if not self.p.get('qa_plan',{}).get('regression'):self.behavioral_regression(case,agent,observed,sh)
            if s.get('save_load'):p,a=self.storage_scenarios(work,case,seed,p,a)
        except Exception as ex:
            name=case+'_harness_error.txt';(self.e.root/name).write_text(traceback.format_exc(),encoding='utf-8');self.verdict(case,'FAIL' if p and p.poll() is not None else 'HARNESS_ERROR','CRASH' if p and p.poll() is not None else 'HARNESS_FAILURE',[name],detail=str(ex))
        finally:
            if a:
                try:a.close()
                except Exception:pass
            self.stop();write_json(self.e.root/(case+'_agent.json'),agent.export());write_json(self.e.root/(case+'_observations.json'),list(observed))
        return agent.export(),list(observed)
    def checkpoint(self,s,seed,case,state,actions,shot):
        cfg=self.p.get('qa_plan',{}).get('regression')
        if not cfg or not shot or s.get('soak'):return
        key=s.get('regression_key',s['id']);identity=(self.p['game_id'],key);perf=dict(self.performance.get(case,{}));samples=[x for x in self.metrics if x.get('pid')==getattr(getattr(self.active_supervisor,'p',None),'pid',None)]
        if any('ram' in x for x in samples):perf['peak_ram']=max(x['ram'] for x in samples if 'ram' in x)
        if any('handles' in x for x in samples):perf['peak_handles']=max(x['handles'] for x in samples if 'handles' in x)
        self.performance[case]=perf
        if s.get('export_baseline') or s['id']==cfg['scenario']:
            target=inside(self.e.root,'baseline_exports/'+self.p['game_id']+'/'+key);export_baseline(target,self.p,key,seed,state,actions,self.transitions,perf,self.e.root/shot,'SELF_CHECK' if s.get('export_baseline') else 'RECORDED_RUN_NOT_AUTO_APPROVED',target_identity=getattr(self,'target_identity',None))
        if s.get('compare_baseline'):
            base=self.comparison_baselines.get(identity)
            if base is None:raise ValueError('REQUIRED_BASELINE_MISSING')
            baseline=load_baseline(base,self.p,key,seed,identity=getattr(self,'target_identity',None),identity_root=self.root,settings=getattr(self,'binding_settings',None))
            for test,status,reason,proof in compare(baseline,self.p,state,actions,self.transitions,perf,base/'screen.bmp',self.e.root/shot):
                name=case+'_'+test+'.json';write_json(self.e.root/name,{'baseline_game_version':baseline['game_version'],'current_game_version':self.p['game_version'],'baseline_scope':'USER_SPECIFIED_PREVIOUS_RUN' if self.imported_baselines else 'SAME_RUN_SELF_CHECK',**proof});self.verdict(case+'.'+test,status,reason,[name,shot,(base/'screen.bmp').relative_to(self.e.root).as_posix(),(base/'checkpoint.json').relative_to(self.e.root).as_posix(),(base/'bundle.json').relative_to(self.e.root).as_posix()])
    def behavioral_regression(self,case,agent,states,shot):
        baseline=self.root/'BASELINES'/self.p['game_id']/(case+'.json');name=case+'_regression.json'
        if not baseline.exists():self.verdict(case+'.regression','NOT_RUN','BASELINE_NOT_PROVIDED');return
        b=read_json(baseline)
        if b.get('seed')!=agent.seed or b.get('scenario')!=agent.scenario['id']:
            self.verdict(case+'.regression','NOT_RUN','BASELINE_SEED_SCENARIO_MISMATCH');return
        final=states[-1] if states else {};checks=[condition(final,c) for c in b.get('expected',[])];write_json(self.e.root/name,{'baseline':b,'final':final,'checks':checks})
        self.verdict(case+'.behavioral_regression','PASS' if checks and all(checks) else 'FAIL' if checks else 'INCONCLUSIVE','BASELINE_EXPECTATIONS_MATCH' if checks and all(checks) else 'BEHAVIORAL_REGRESSION',[name])
        perf=b.get('performance',{});actual=self.performance.get(case,{})
        if perf:
            matches=[actual.get(k) is not None and actual[k]<=v.get('maximum',float('inf')) for k,v in perf.items()]
            name_perf=case+'_performance.json';write_json(self.e.root/name_perf,{'baseline_limits':perf,'actual':actual})
            self.verdict(case+'.performance_regression','PASS' if all(matches) else 'FAIL','PERFORMANCE_WITHIN_LIMIT' if all(matches) else 'PERFORMANCE_REGRESSION',[name_perf])
        if shot and b.get('screenshot'):
            path=inside(baseline.parent,b['screenshot']);distance=image_distance(image_features(path),image_features(self.e.root/shot));write_json(self.e.root/(case+'_visual.json'),{'distance':distance,'threshold':b.get('visual_tolerance',.08)})
            self.verdict(case+'.visual_regression','FAIL' if distance>b.get('visual_tolerance',.08) else 'PASS','VISUAL_REGRESSION' if distance>b.get('visual_tolerance',.08) else 'VISUAL_WITHIN_TOLERANCE',[case+'_visual.json',shot])
        else:self.verdict(case+'.visual_regression','NOT_RUN','VISUAL_BASELINE_NOT_PROVIDED')
    def resource_analysis(self):
        name=self.p['game_id']+'_resources.json';write_json(self.e.root/name,self.metrics);groups={};candidates=[];analyzed=[]
        for sample in self.metrics:groups.setdefault(sample['pid'],[]).append(sample)
        for pid,samples in groups.items():
            for metric,threshold in [('ram',64*1024*1024),('handles',256)]:
                values=[m[metric] for m in samples if metric in m]
                if len(values)<10:continue
                continuity=sum(b>=a for a,b in zip(values,values[1:]))/(len(values)-1);growth=values[-1]-values[0];analyzed.append({'pid':pid,'metric':metric,'samples':len(values),'growth':growth})
                if growth>threshold and continuity>.85:candidates.append({'pid':pid,'metric':metric,'growth':growth,'continuity':continuity})
        if not analyzed:self.verdict(self.p['game_id']+'.leak','INCONCLUSIVE','TOO_FEW_SAMPLES_PER_PID',[name],gate='INFORMATIONAL');return
        self.verdict(self.p['game_id']+'.leak','INCONCLUSIVE' if candidates else 'PASS','LEAK_CANDIDATE' if candidates else 'NO_SUSTAINED_GROWTH_IN_OBSERVED_INTERVAL',[name],gate='INFORMATIONAL',candidates=candidates,analyzed=analyzed,limited_observation=True)
        if not self.p.get('qa_plan',{}).get('regression'):self.verdict(self.p['game_id']+'.performance_regression','NOT_RUN','PERFORMANCE_BASELINE_NOT_PROVIDED')
    def execute(self,seed,options=None):
        self.expected_plan=profile_plan(self.p,options,bool(self.imported_baselines))
        self.required_cases=[r['test_case'] for r in self.expected_plan if r['gate']=='REQUIRED']
        proof=self.p['game_id']+'_expected_cases.json'
        write_json(self.e.root/proof,{'game_id':self.p['game_id'],'options':options or {},'cases':self.expected_plan})
        try:
            self.supporting_diagnostics=attach_diagnostics(self.root,self.e,self.p)
            validate_campaigns(self.p)
            work=self.copy_game('technical_'+self.p['game_id'])
            if not self.technical(work):
                for scenario in self.p['scenarios']:self.verdict(self.p['game_id']+'.'+scenario['id'],'NOT_RUN','TECHNICAL_PREREQUISITE_FAILED')
                return self.results
            self.prepared_work=work
            prior=None
            for s in self.p['scenarios']:
                exported,states=self.run_scenario(s,seed)
                if s.get('verify_seed_replay'):
                    again=dict(s);again['id']=s['id']+'_seed_replay'
                    ex2,st2=self.run_scenario(again,seed,replay=exported['action_history'])
                    fields=s.get('replay_fields',['score','turn','event']);a=states[-1] if states else {};b=st2[-1] if st2 else {};ok=bool(states and st2) and all(get(a,f)==get(b,f) for f in fields)
                    name=self.p['game_id']+'_seed_replay.json';write_json(self.e.root/name,{'seed':seed,'fields':fields,'first':a,'second':b,'sequence':exported['action_history']})
                    self.verdict(self.p['game_id']+'.seed_replay','PASS' if ok else 'FAIL','SEED_REPLAY_MATCH' if ok else 'SEED_REPLAY_MISMATCH',[name])
            execute_plans(self,seed,options);self.resource_analysis();return self.results
        finally:
            self.plan_audit=audit_plan(self.e,self.results,self.expected_plan,proof)


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--root',default=str(Path(__file__).resolve().parents[1]));ap.add_argument('--profile',action='append');ap.add_argument('--prototype',choices=['logic','playable']);ap.add_argument('--seed',type=int,default=12345);ap.add_argument('--resume',action='store_true');ap.add_argument('--faults',action=argparse.BooleanOptionalAction,default=True);ap.add_argument('--soak-seconds',type=float);ap.add_argument('--baseline');args=ap.parse_args()
    root=Path(args.root);settings=read_json(root/'acceptance_manifest.json') if (root/'acceptance_manifest.json').is_file() else {};results_dir=inside(root,settings.get('paths',{}).get('results','RESULTS'));run_id=time.strftime('%Y%m%dT%H%M%S')+'_'+uuid.uuid4().hex[:8];out=results_dir/run_id;e=Evidence(out,run_id);start=stamp();results=[];sessions=[];lock=results_dir/'active.lock';lock_owned=False;rec=None
    run_mode='adhoc' if args.profile else 'target';target_manifest=None;target_entries={};target_contracts={};imported=None;prepared=None
    (out/'FULL_EVIDENCE').mkdir();(out/'WORK').mkdir()
    for kind in ['action','state','process']:(out/(kind+'.jsonl')).touch()
    global_plan=[{'test_case':'preflight.core','gate':'REQUIRED'},{'test_case':'video','gate':'REQUIRED'}]
    if run_mode=='target':global_plan += [{'test_case':'target.binding','gate':'REQUIRED'},{'test_case':'target.review_packet','gate':'REQUIRED'}]
    write_json(out/'global_expected_cases.json',global_plan)
    try:
        errors=verify_core(root)
        write_json(out/'core_check.json',{'errors':errors,'version':VERSION})
        if errors:
            results.append(e.result('preflight.core','HARNESS_ERROR','CORE_INTEGRITY_FAILURE',['core_check.json']));return 2
        results.append(e.result('preflight.core','PASS','CORE_INTEGRITY_VERIFIED',['core_check.json']))
        if run_mode=='target':
            try:
                target_manifest=load_target_manifest(root,settings);write_json(out/'target_manifest_snapshot.json',target_manifest)
                results.append(e.result('target.binding','PASS','TARGET_MANIFEST_BOUND',['target_manifest_snapshot.json']))
            except Exception as ex:
                write_json(out/'target_config_error.json',{'error':str(ex)});results.append(e.result('target.binding','HARNESS_ERROR',str(ex).split(':',1)[0],['target_config_error.json']))
                raise
        try:
            fd=os.open(lock,os.O_CREAT|os.O_EXCL|os.O_WRONLY);os.write(fd,json.dumps({'pid':os.getpid(),'run_id':run_id}).encode());os.close(fd);lock_owned=True
        except FileExistsError:
            previous=read_json(lock);alive=False
            if os.name=='nt':alive=bool(process_metrics(previous['pid']).get('ram'))
            else:
                try:os.kill(previous['pid'],0);alive=True
                except ProcessLookupError:pass
            if alive:raise OSError('ANOTHER_QA_RUN_IS_ACTIVE')
            # Resume means restart interrupted scenarios, never reuse an unverified half-state.
            write_json(out/'interrupted_run.json',previous);lock.unlink();fd=os.open(lock,os.O_CREAT|os.O_EXCL|os.O_WRONLY);os.write(fd,json.dumps({'pid':os.getpid(),'run_id':run_id}).encode());os.close(fd);lock_owned=True
        # The binding ledger is updated under the run lock, before any Session exists.
        if run_mode=='target':
            prepared=prepare_execution(root,target_manifest,settings)
            preflight=preflight_execution(e,prepared);results+=preflight
            if preflight:raise ValueError('TARGET_PREFLIGHT_BLOCKED')
        else:
            adhoc={'schema_version':1,'targets':[{'id':str(i),'profile':rel,'kind':'selftest'} for i,rel in enumerate(args.profile or [])]}
            prepared=prepare_execution(root,adhoc,settings)
            results+=preflight_execution(e,prepared)
        if shutil.disk_usage(root).free<3*1024**3:raise OSError('DISK_GUARD_MIN_3_GIB')
        if os.name!='nt':
            write_json(out/'environment.json',{'platform':sys.platform,'windows_desktop':False,'windows_e2e_executed':False})
            results.append(e.result('preflight.windows','HARNESS_ERROR','WINDOWS_DESKTOP_REQUIRED',['environment.json']))
            for gate in ['input','screenshot','video','logic_e2e','playable_e2e','ui_e2e','narrative_e2e','procedural_e2e','obs','toolchain_10_of_10','fresh_extraction_e2e']:results.append(e.result(gate,'NOT_RUN','WINDOWS_DESKTOP_UNAVAILABLE'))
            return 2
        requirements=tool_requirements(read_json(root/'acceptance_manifest.json'))
        selected_profile_paths=args.profile or selected_profiles(target_manifest)
        tools=Tools(root,e);declared_tools={t['id'] for t in tools.manifest}
        from target_intake import tool_ids_from_profile,optional_tool_ids_from_profile
        profile_required=set();profile_optional=set()
        for rel in selected_profile_paths:
            try:
                raw_profile=read_json(inside(root,rel))
                profile_required.update(tool_ids_from_profile(raw_profile,declared_tools))
                profile_optional.update(optional_tool_ids_from_profile(raw_profile,declared_tools))
            except Exception:
                pass  # the authoritative profile loader records the real profile failure later
        required_tools=set(requirements)|profile_required|{'ffmpeg'}
        if 'oculix' in required_tools:required_tools.add('java')
        unknown_required=required_tools-declared_tools
        for tool in sorted(unknown_required):
            results.append(e.result('required_tool.'+tool,'HARNESS_ERROR','REQUIRED_TOOL_NOT_DECLARED',
                product_reason=requirements.get(tool,'PROFILE_OR_HARNESS_REQUIRED'),gate='REQUIRED'))
        known_required=required_tools & declared_tools
        optional_tools=((profile_optional|{'ahk','java','oculix','c'}) & declared_tools)-known_required
        results+=tools.prepare(required=known_required,optional=optional_tools)
        desktop=Desktop()
        # Dedicated self-test is a real GUI window. Input assertions are implemented in the fixture suite.
        for capability in ['audio','gamepad']:results.append(e.result('selftest.'+capability,'NOT_RUN','NO_VALIDATED_BACKEND'))
        ffmpeg=tools.get('ffmpeg');ffprobe=str(Path(ffmpeg).with_name('ffprobe.exe'))
        rec=select_recording({'desktop_ffmpeg':lambda:Recorder(ffmpeg,ffprobe,out/'FULL_EVIDENCE'/'screen.mp4'),'captured_frames':lambda:threaded_desktop_recorder(ffmpeg,ffprobe,out/'FULL_EVIDENCE'/'screen.mp4')},out,read_json(root/'acceptance_manifest.json').get('recording',{}).get('preferred_backends',['desktop_ffmpeg','captured_frames']))
        results+=selftest(root,e,tools,required_tools)
        write_json(out/'tool_versions.json',tools.manifest)
        if tools.is_available('obs'):
            try:
                obsfile=obs_probe(tools.get('obs'),out/'FULL_EVIDENCE');rel=Path(obsfile).relative_to(out).as_posix()
                probe=subprocess.run([ffprobe,'-v','error','-show_streams','-show_format','-of','json',obsfile],capture_output=True,timeout=30)
                (out/'obs_probe.json').write_bytes(probe.stdout);info=json.loads(probe.stdout or b'{}')
                ok=probe.returncode==0 and float(info.get('format',{}).get('duration',0))>0 and any(x['codec_type']=='video' for x in info.get('streams',[]))
                results.append(e.result('tool.obs.functional','PASS' if ok else 'HARNESS_ERROR','OBS_RECORDING_PROBED' if ok else 'OBS_RECORDING_INVALID',[rel,'obs_probe.json'],gate=tool_gate('obs',requirements)))
            except Exception as ex:
                write_json(out/'obs_error.json',{'error':repr(ex)});results.append(e.result('tool.obs.functional','HARNESS_ERROR','OBS_RECORDING_FAILED',['obs_error.json'],gate=tool_gate('obs',requirements)))
        else:
            results.append(e.result('tool.obs.functional','NOT_RUN','TOOL_NOT_PREPARED',gate=tool_gate('obs',requirements)))
        profiles=selected_profile_paths
        baseline=baseline_source(root,target_manifest,args.baseline)
        imported=import_baseline(baseline,out) if baseline else None
        selected_ids=set()
        for rel in profiles:
            try:
                profile=load(root,inside(root,rel))
                if args.prototype and profile['prototype_type']!=args.prototype:continue
                if profile['game_id'] in selected_ids:raise ValueError('DUPLICATE_GAME_ID')
                selected_ids.add(profile['game_id'])
                if run_mode=='target':
                    entry=entry_for_profile(target_manifest,rel);target_entries[profile['game_id']]=entry
                    case='target.'+entry['id']+'.contract';global_plan.append({'test_case':case,'gate':'REQUIRED'})
                    if 'historical_regression' in entry.get('requirements',[]):global_plan.append({'test_case':'target.'+entry['id']+'.historical_regression','gate':'REQUIRED'})
                    write_json(out/'global_expected_cases.json',global_plan)
                    missing=validate_target_profile(profile,entry);proof='target_contract_'+entry['id']+'.json';write_json(out/proof,{'target':entry,'game_id':profile['game_id'],'qa_role':profile.get('qa_role','target'),'requirement_coverage':requirement_coverage(profile,entry),'required_agents':sorted(required_agents(profile,entry)),'missing':missing})
                    target_contracts[profile['game_id']]={'entry':entry,'proof':proof,'missing':missing}
                    results.append(e.result(case,'HARNESS_ERROR' if missing else 'PASS','TARGET_CONTRACT_INCOMPLETE' if missing else 'TARGET_CONTRACT_VALID',[proof],missing=missing))
                    if missing:continue
                write_json(out/(profile['game_id']+'_profile.json'),profile)
                session=Session(root,e,tools,profile);session.rec=rec;session.imported_baselines=imported;session.target_identity=prepared['identities'][entry['id']] if run_mode=='target' else None;session.binding_settings=settings;sessions.append(session);results+=session.execute(args.seed,{'faults':args.faults,'soak_seconds':args.soak_seconds,'required_agents':sorted(required_agents(profile,entry)) if run_mode=='target' else []})
                if run_mode=='target':
                    entry=target_entries[profile['game_id']]
                    if 'historical_regression' in entry.get('requirements',[]):
                        rows=[r for r in session.results if r['test_case'].startswith(profile['game_id']+'.__qa_regression.') and r['test_case'].endswith(('behavioral_regression','visual_regression'))]
                        proof='historical_regression_'+entry['id']+'.json';write_json(out/proof,{'baseline_origin':'USER_SPECIFIED_PREVIOUS_RUN' if imported else 'SAME_RUN_SELF_CHECK','comparison_cases':[{'test_case':r['test_case'],'status':r['status'],'reason_code':r['reason_code']} for r in rows]})
                        ok=bool(imported) and len(rows)>=2 and all(r['status']=='PASS' for r in rows)
                        results.append(e.result('target.'+entry['id']+'.historical_regression','PASS' if ok else ('FAIL' if imported else 'NOT_RUN'),'HISTORICAL_REGRESSION_VERIFIED' if ok else ('HISTORICAL_REGRESSION_FAILED' if imported else 'HISTORICAL_BASELINE_REQUIRED'),[proof],gate='REQUIRED'))
            except Exception as ex:
                name='profile_error_'+str(len(results))+'.txt';(out/name).write_text(traceback.format_exc(),encoding='utf-8');results.append(e.result('profile.'+rel,'HARNESS_ERROR','PROFILE_FAILURE',[name]))
        if not sessions:raise ValueError('NO_APPLICABLE_PROFILE')
    except Exception as ex:
        (out/'harness_error.txt').write_text(traceback.format_exc(),encoding='utf-8');results.append(e.result('run','HARNESS_ERROR','HARNESS_FAILURE',['harness_error.txt'],detail=str(ex)))
    finally:
        # A Session may have raised after recording useful verdicts.
        known={id(row) for row in results}
        for session in sessions:
            for row in session.results:
                if id(row) not in known:results.append(row);known.add(id(row))
        data={'run_id':run_id,'core_version':VERSION,'result_schema':SCHEMA,'start_time':start,'end_time':stamp(),'seed':args.seed,'results':results,'run_mode':run_mode,'target_qa_certified':False,'completion_certified':False,'human_test_performed':False,'supporting_diagnostics':[row for sess in sessions for row in getattr(sess,'supporting_diagnostics',[])],'qualification':'Automated QA evidence is not human satisfaction or product acceptance; review player/product gates separately.'}
        data['executed_target_ids']=sorted(target_entries[sess.p['game_id']]['id'] for sess in sessions if sess.p['game_id'] in target_entries)
        try:
            if rec:
                try:
                    video_data=rec.stop();write_json(out/'video.json',video_data);results.append(e.result('video','PASS','RECORDING_PROBED',['video.json','FULL_EVIDENCE/screen.mp4','FULL_EVIDENCE/screen.probe.json']))
                    rec.clip(out/'run_highlight.mp4',4,before=4,after=4)
                    e.event('highlight',file='run_highlight.mp4',offset=0)
                    for sess in sessions:
                        for case,at in sess.failure_times:
                            try:
                                name=case+'_failure.mp4';rec.clip(out/name,at);e.event('failure_clip',case,file=name,offset=at)
                            except Exception as ex:
                                results.append(e.result(case+'.clip','HARNESS_ERROR','FAILURE_CLIP_FAILED',detail=str(ex)))
                except Exception as ex:
                    write_json(out/'video_error.json',{'error':repr(ex)});results.append(e.result('video','HARNESS_ERROR','VIDEO_FAILED',['video_error.json']))
        except Exception as ex:
            finalization_issue(e,results,'recording.finalize','RECORDING_FINALIZE_FAILURE',ex)
        try:
            write_json(out/'reproduction.json',{'seed':args.seed,'run_mode':run_mode,'profiles':args.profile or ([t['profile'] for t in target_manifest.get('targets',[])] if target_manifest else []),'target_manifest':settings.get('paths',{}).get('target_manifest','QA_TARGETS.json') if run_mode=='target' else None,'command':['START_QA.cmd','-Seed',str(args.seed)],'replay':'CORE/replay.py --profile PROFILE --actions action.jsonl','resume_policy':'restart from pristine game copy; no state snapshot resume'})
            coverage={}
            for sess in sessions:coverage[sess.p['game_id']]={k:sorted(v) for k,v in sess.coverage.items()}
            write_json(out/'coverage.json',coverage)
            data['coverage']=coverage
            data['versions']={sess.p['game_id']:{'game':sess.p['game_version'],'profile':sess.p['profile_version'],'adapter':sess.p.get('adapter_version','1.0')} for sess in sessions}
            if run_mode=='target' and sessions:
                visual=[p.relative_to(out).as_posix() for p in sorted(out.rglob('*')) if p.is_file() and p.suffix.lower() in ('.bmp','.png','.jpg','.jpeg','.mp4') and 'WORK' not in p.parts]
                packet={'schema_version':1,'run_id':run_id,'automated_only':True,'human_satisfaction_claimed':False,'product_acceptance_claimed':False,'targets':[]}
                for sess in sessions:
                    entry=target_entries.get(sess.p['game_id'],{})
                    packet['targets'].append({'target_id':entry.get('id'),'profile':entry.get('profile'),'game_id':sess.p['game_id'],'game_version':sess.p['game_version'],'prototype_type':sess.p['prototype_type'],'requirements':entry.get('requirements',[]),'required_agents':sorted(required_agents(sess.p,entry)),'instructions':sess.p.get('instructions'),'controls':sess.p.get('controls'),'actions':sorted(sess.p.get('actions',{})),'goals':sess.p.get('goals',[]),'scenarios':[{'id':x.get('id'),'agent':x.get('agent'),'goal':x.get('goal')} for x in sess.p.get('scenarios',[])],'coverage':coverage.get(sess.p['game_id'],{})})
                packet['visual_evidence']=visual;write_json(out/'player_review_packet.json',packet);results.append(e.result('target.review_packet','PASS','PLAYER_REVIEW_EVIDENCE_PACKAGED',['player_review_packet.json'],gate='REQUIRED'))
            write_json(out/'full_evidence_index.json',[{'file':p.relative_to(out).as_posix(),'size':p.stat().st_size,'sha256':digest(p)} for p in sorted((out/'FULL_EVIDENCE').rglob('*')) if p.is_file()])
        except Exception as ex:
            finalization_issue(e,results,'metadata','METADATA_FINALIZE_FAILURE',ex)
        finally:
            try:
                audit_plan(e,results,global_plan,'global_expected_cases.json')
                for row in results:
                    if row['status']=='PASS' and (not row.get('evidence') or any(not inside(out,f).is_file() for f in row['evidence'])):row.update(status='HARNESS_ERROR',reason_code='FINAL_EVIDENCE_AUDIT_FAILED')
                required=[r['test_case'] for r in global_plan if r['gate']=='REQUIRED']+[c for sess in sessions for c in getattr(sess,'required_cases',[])]
                target_scope_ok=target_scope_satisfied(run_mode,sessions,target_entries,target_contracts) and prepared is not None and set(data['executed_target_ids'])==set(prepared['identities'])
                data['target_qa_certified']=certify(results,required,VERSION,os.name=='nt' and target_scope_ok)
                data['completion_certified']=data['target_qa_certified']
                data['prototype_results']=prototype_summary(sessions,results)
            except Exception as ex:
                finalization_issue(e,results,'plan.audit','PLAN_AUDIT_FAILURE',ex);data['completion_certified']=False
            finally:
                try:
                    from phase3_run_evidence import write_phase3_hq_evidence
                    hq_files=write_phase3_hq_evidence(e=e,sessions=sessions,results=results,run_mode=run_mode,prepared=prepared)
                    results.append(e.result('phase3.hq_evidence','PASS','PHASE3_HQ_EVIDENCE_WRITTEN',hq_files,gate='REQUIRED'))
                except Exception as ex:
                    name='phase3_hq_evidence_error.json';write_json(out/name,{'error':repr(ex)})
                    results.append(e.result('phase3.hq_evidence','HARNESS_ERROR','PHASE3_HQ_EVIDENCE_FAILED',[name],gate='REQUIRED'))
                data['overall']=overall(results)
                published=finalize_run(e,data,cleanup=tuple(sess.stop for sess in sessions),latest_path=results_dir/'latest.json',lock=lock if lock_owned else None,execution=execution_finalizer(root,prepared,settings,run_mode))
                data['overall']=published['overall']
                print('QA COMPLETE\nOverall Result: '+data['overall']+'\nResult ZIP Path: '+str(published.get('result_zip') or 'NOT_CREATED')+'\nResult Folder: '+str(out))
    return 0 if data['overall']=='PASS' and published.get('zip_created') else 2
if __name__=='__main__':raise SystemExit(main())


