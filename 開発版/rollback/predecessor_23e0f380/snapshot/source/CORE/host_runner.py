"""Actual RFB software-GUI validation; no mock state transitions in the harness."""
import os,sys,time,json,uuid,argparse,shutil,subprocess,traceback,copy,math
from pathlib import Path
from common import *
from backends import ProcessSupervisor,select_display,discover_tools,FrameRecorder,DisplaySampler
from agents import Agent,StallDetector
from adapters import image_features,image_distance
from profile import condition
from assets import inspect_assets,copy_game
from plans import fault_plan,goal_scenario,scenario_by_id
class RealRun:
    def __init__(self,root,out,seed,disable_capture=False):
        self.root=Path(root);self.e=Evidence(out,Path(out).name);self.seed=seed;self.disable_capture=disable_capture;self.results=[];self.tools=discover_tools(self.root);self.coverage={'agents':set(),'actions':set(),'states':set(),'profiles':set()};self.displays=[];self.supervisors=[];self.metrics=[];self.performance={};self.causal=[];self.video=None;self.required_cases=[];self.contexts={};self.profile_versions={};self.recording_preferences=[];self.failure_times=[]
        for name in ('action','state','process'):(self.e.root/(name+'.jsonl')).touch()
    def verdict(self,case,status,reason,files=(),gate='REQUIRED',**kw):
        r=self.e.result(case,status,reason,files,gate=gate,**kw);self.results.append(r)
        if status=='FAIL' and self.video:self.failure_times.append((r,time.monotonic()-self.video.start))
        if gate=='REQUIRED':self.required_cases.append(case)
        return r
    def screenshot(self,d,case,name):
        if self.disable_capture:raise OSError('CAPTURE_INTENTIONALLY_DISABLED')
        rel=case+'/'+name+'.bmp';target=self.e.root/rel;meta=d.capture(target);self.e.event('screenshot',case,file=rel,geometry=meta)
        if self.video:self.video.frame(target)
        return rel,image_features(target)
    def read(self,work):
        p=self.contexts[str(work)];observations=p.get('observations',{});rel=observations.get('bridge') if isinstance(observations,dict) else None
        rel=rel or p.get('bridge')
        if not rel:return {}
        try:return read_json(inside(work,rel))
        except (OSError,ValueError):return {}
    def act(self,d,p,name,case,reason):
        action=p['actions'][name];inputs=copy.deepcopy(action.get('inputs',[]))
        if 'target' in action:
            pos=d.locate_color(p['visual_targets'][action['target']]['rgb'])
            if pos is None:raise OSError('VISUAL_TARGET_NOT_FOUND:'+action['target'])
            inputs=[{'kind':'click','x':pos[0],'y':pos[1]}]
        transforms=[]
        for i in inputs:
            if i['kind']=='click':transforms.append({'normalized':[i['x'],i['y']],'dimensions':[d.width,d.height],'pixels':[round(i['x']*(d.width-1)),round(i['y']*(d.height-1))]})
            d.perform(i)
        self.coverage['actions'].add(name);self.e.event('action',case,agent=reason,action=name,input=inputs,target=action.get('target'),reason=reason,result='sent',coordinate_transforms=transforms,seed=self.seed)
    def scenario(self,p,s,tag=None,replay=None):
        case=p['game_id']+'.'+(tag or s['id']);work=self.e.root/'WORK'/case
        if work.exists():raise ValueError('SCENARIO_OUTPUT_COLLISION:'+case)
        self.contexts[str(work)]=p;copy_game(inside(self.root,p['source']),work,p,ignore=('__pycache__','.git'))
        if s.get('missing_asset'):
            missing=inside(work,s['missing_asset'])
            if missing.is_file():missing.unlink()
        assets=inspect_assets(work,p);asset_proof=case+'_assets.json';write_json(self.e.root/asset_proof,assets)
        if assets['missing']:
            self.verdict(case+'.assets','FAIL','MISSING_ASSET',[asset_proof]);return {'states':[],'history':[],'final':{},'case':case,'shots':[]}
        self.verdict(case+'.assets','PASS','ASSET_REFERENCES_EXIST',[asset_proof])
        values={**self.tools,'work':str(work),'root':str(self.root),'seed':str(self.seed),'endpoint':str(inside(work,p['display']['endpoint'])),'state':str(inside(work,p['observations']['bridge'])),'save':str(inside(work,p['save']['file'])) if p.get('save') else ''}
        cmd=[str(v).format_map(values) for v in p['launch']['argv']+p['launch'].get('extra_args',[])]
        out=(self.e.root/(case+'_stdout.log')).open('wb');err=(self.e.root/(case+'_stderr.log')).open('wb');supervisor=ProcessSupervisor();self.supervisors.append(supervisor);process=None;d=None;sampler=None;states=[];shots=[];last=None;start=time.monotonic();fault_seen=False;goal_seen=False;agent=Agent(p,s,self.seed);detector=StallDetector(s.get('stall_seconds',1.2));last_progress=time.monotonic();last_sig=None;history=[]
        try:
            process=supervisor.start(cmd,work,out,err);deadline=time.monotonic()+10
            while time.monotonic()<deadline and not inside(work,p['display']['endpoint']).exists():
                if process.poll() is not None:raise OSError('FIXTURE_LAUNCH_EXIT')
                time.sleep(.02)
            d=select_display(p,work,process);self.displays.append(d);focus=d.focus();write_json(self.e.root/(case+'_backend.json'),{'process_backend':'process groups' if os.name!='nt' else 'Windows Job','display_backend':'RFB 3.8','focus':focus,'capabilities':{'real_key_input':True,'real_pointer_input':True,'capture':not self.disable_capture,'color_target_localization':bool(p.get('visual_targets')),'ocr':False,'general_image_recognition':False,'game_specific_profile_required':True},'command':cmd,'pid':process.pid,'startup_seconds':time.monotonic()-start})
            first,features=self.screenshot(d,case,'start');shots.append(first)
            sampler=DisplaySampler(d,self.video,self.e.root/(case+'_recording_current.bmp'));sampler.start()
            self.performance[case]={'startup_seconds':time.monotonic()-start}
            self.verdict(case+'.launch','PASS','REAL_GAME_PROCESS_AND_DISPLAY',[case+'_backend.json',first]);self.coverage['agents'].add(s['agent']);self.coverage['profiles'].add(p['game_id'])
            iterations=0;loops_before=0
            while not agent.exhausted():
                if process.poll() is not None:
                    name=case+'_crash.json';write_json(self.e.root/name,{'pid':process.pid,'exit_code':process.returncode,'history':history});self.verdict(case+'.crash','FAIL','CRASH',[name]+shots[-1:],severity='CRITICAL');fault_seen=True;break
                if shutil.disk_usage(self.e.root).free<256*1024*1024:raise OSError('DISK_GUARD')
                before=self.read(work);sig=agent.signature(before);self.coverage['states'].add(sig);states.append(before)
                self.e.event('state',case,current_state=before,internal_state=before,scene=before.get('scene'),window={'backend':'RFB','size':[d.width,d.height]},goal_progress=condition(before,p['goals'][0]))
                metrics=supervisor.metrics();metrics['timestamp']=stamp();self.metrics.append(metrics);self.e.event('process',case,**metrics)
                if last_sig!=sig:last_progress=time.monotonic();last_sig=sig
                if condition(before,p['goals'][0]):
                    goal_seen=True
                    if s.get('stop_on_goal',True):break
                if replay is not None:
                    if iterations>=len(replay):break
                    name=replay[iterations];agent.history.append(name)
                else:name=agent.choose(before)
                if agent.loops>loops_before:
                    self.e.event('strategy_change',case,reason_code='ACTION_LOOP',fallback=agent.mode,loop_count=agent.loops);loops_before=agent.loops
                self.act(d,p,name,case,agent.mode);history.append(name);time.sleep(s.get('observe_delay',.035))
                after=self.read(work);states.append(after);agent.feedback(before,after,name);iterations+=1
                self.causal.append({'case':case,'state_before':before,'action':name,'state_after':after,'changed_fields':[k for k in after if before.get(k)!=after[k]],'sequence_index':iterations})
                try:
                    shot,features=self.screenshot(d,case,f'frame_{iterations:04d}');shots.append(shot)
                except (OSError,EOFError):
                    time.sleep(.05)
                    if process.poll() is not None:
                        info=case+'_crash.json';write_json(self.e.root/info,{'pid':process.pid,'exit_code':process.returncode,'history':history});self.verdict(case+'.crash','FAIL','CRASH',[info]+shots[-1:],severity='CRITICAL');fault_seen=True;break
                    raise
                stall=detector.observe(time.monotonic(),agent.signature(after),tuple(features),name,reaction=after.get('reaction'))
                if stall:
                    info=case+'_stall.json';write_json(self.e.root/info,{'state':after,'history':history,'signal':'state + reaction + varied actual input + elapsed time','fallback':agent.mode});self.verdict(case+'.stall','FAIL','SOFTLOCK',[info,shot],severity='MAJOR');fault_seen=True;break
            final=self.read(work);states.append(final);goal_seen=goal_seen or condition(final,p['goals'][0]);name=case+'_scenario.json';write_json(self.e.root/name,{'seed':self.seed,'state':final,'actions':history,'agent':agent.export(),'duration':time.monotonic()-start,'real_process':process.pid,'goal_observed':goal_seen})
            if not fault_seen:
                if s.get('goal'):
                    self.verdict(case+'.goal','PASS' if goal_seen else 'FAIL','GOAL_REACHED' if goal_seen else 'GOAL_NOT_REACHED',[name]+shots[-1:])
                else:self.verdict(case+'.execution','PASS' if history else 'FAIL','REAL_INPUT_EXECUTED' if history else 'NO_ACTIONS',[name]+shots[-1:])
                if s.get('save_load'):self.save_load(p,d,work,case)
                if s.get('retry_test'):
                    cfg=s['retry_test'];self.act(d,p,cfg['fail_action'],case,'failure_retry');time.sleep(.08);failed=self.read(work);self.act(d,p,cfg['retry_action'],case,'failure_retry');time.sleep(.08);recovered=self.read(work);proof=case+'_retry.json';write_json(self.e.root/proof,{'failed':failed,'recovered':recovered,'contract':cfg});self.verdict(case+'.retry','PASS' if condition(failed,cfg['failed']) and condition(recovered,cfg['recovered']) else 'FAIL','FAILURE_RETRY_VERIFIED',[proof])
                if s.get('baseline') or s.get('regression'):
                    self.regression(p,case,shots[-1],final,s)
                if s.get('soak'):
                    elapsed=time.monotonic()-start;proof=case+'_soak.json';write_json(self.e.root/proof,{'elapsed':elapsed,'required_seconds':s['time_budget'],'samples':len(states),'ram_samples':len(self.metrics)});ok=elapsed>=s['time_budget']*.95 and process.poll() is None;self.verdict(case+'.soak','PASS' if ok else 'FAIL','REAL_SOAK_COMPLETED' if ok else 'SOAK_INCOMPLETE',[proof]+shots[-1:])
            return {'states':states,'history':history,'final':final,'case':case,'shots':shots}
        except Exception as ex:
            name=case+'_error.txt';(self.e.root/name).write_text(traceback.format_exc());self.verdict(case,'HARNESS_ERROR','HARNESS_FAILURE',[name],detail=str(ex));return {'states':states,'history':history,'final':self.read(work),'case':case,'shots':shots}
        finally:
            if sampler:
                proof=case+'_continuous_capture.json';sampling=sampler.stop();write_json(self.e.root/proof,sampling)
                if sampling['error'] and process and process.poll() is None:self.verdict(case+'.continuous_capture','HARNESS_ERROR','RECORDING_CAPTURE_FAILED',[proof])
            if d:
                try:d.close()
                except Exception:pass
                self.displays.remove(d)
            supervisor.stop();self.e.event('process',case,pid=process.pid if process else None,event='stop',exit_code=process.poll() if process else None);out.close();err.close();self.supervisors.remove(supervisor)
    def save_load(self,p,d,work,case):
        cfg=p.get('save')
        if not cfg:self.verdict(case+'.save_load','NOT_RUN','SAVE_NOT_DECLARED',gate='UNSUPPORTED_FOR_PROFILE');return
        before=self.read(work);self.act(d,p,cfg['save_action'],case,'Save QA');time.sleep(.08);save=inside(work,cfg['file'])
        if not save.exists():
            info=case+'_save_error.json';write_json(self.e.root/info,{'save_exists':False,'observed':self.read(work)});self.verdict(case+'.save_load','FAIL','SAVE_FAIL',[info]);return
        original=save.read_bytes();saved=self.read(work);self.act(d,p,cfg['mutate_action'],case,'mutate after save');time.sleep(.08);mutated=self.read(work);self.act(d,p,cfg['load_action'],case,'Load QA');time.sleep(.08);restored=self.read(work);fields=cfg['state_fields'];ok=any(saved.get(k)!=mutated.get(k) for k in fields) and all(saved.get(k)==restored.get(k) for k in fields)
        proof=case+'_save_load.json';write_json(self.e.root/proof,{'saved':saved,'mutated':mutated,'restored':restored,'fields':fields});self.verdict(case+'.save_load','PASS' if ok else 'FAIL','STATE_RESTORED' if ok else 'SAVE_MISMATCH',[proof]);self.screenshot(d,case,'load')
        try:
            save.write_text('{invalid');self.act(d,p,cfg['load_action'],case,'Invalid save QA');time.sleep(.08);state=self.read(work);proof=case+'_invalid_save.json';write_json(self.e.root/proof,state);self.verdict(case+'.invalid_save','PASS' if condition(state,cfg['invalid_expected']) else 'FAIL','INVALID_SAVE_REJECTED' if condition(state,cfg['invalid_expected']) else 'INVALID_SAVE_NOT_REJECTED',[proof])
        finally:save.write_bytes(original)
    def regression(self,p,case,shot,state,s):
        cfg=p['qa_plan']['regression'];base=inside(self.root,cfg['shipped_baseline']) if s.get('shipped_baseline') else (self.e.root/'BASELINES'/p['game_id']);base.mkdir(parents=True,exist_ok=True)
        image=base/'normal.bmp';meta=base/'state.json'
        if s.get('baseline'):
            shutil.copy2(self.e.root/shot,image);write_json(meta,{'state':{k:state.get(k) for k in cfg['state_fields']},'performance_limits':{'startup_seconds':max(5,self.performance[case]['startup_seconds']*10)}});return
        if not image.exists() or not meta.exists():
            self.verdict(case+'.regression','HARNESS_ERROR','REQUIRED_BASELINE_MISSING');return
        distance=image_distance(image_features(image),image_features(self.e.root/shot));baseline=read_json(meta);expected=baseline.get('state',baseline);same=all(state.get(k)==v for k,v in expected.items());proof=case+'_regression.json';write_json(self.e.root/proof,{'visual_distance':distance,'tolerance':.04,'behavioral_expected':expected,'actual':state,'behavioral_equal':same})
        self.verdict(case+'.visual_regression','PASS' if distance<=cfg.get('visual_tolerance',.04) else 'FAIL','VISUAL_WITHIN_TOLERANCE' if distance<=cfg.get('visual_tolerance',.04) else 'VISUAL_REGRESSION',[proof,shot]+(['BASELINES/'+p['game_id']+'/normal.bmp'] if not s.get('shipped_baseline') else []))
        self.verdict(case+'.behavioral_regression','PASS' if same else 'FAIL','BASELINE_MATCH' if same else 'BEHAVIORAL_REGRESSION',[proof])
        limits=baseline.get('performance_limits',{});perf_ok=bool(limits) and all(self.performance.get(case,{}).get(k,float('inf'))<=v for k,v in limits.items());perf=case+'_performance_regression.json';write_json(self.e.root/perf,{'limits':limits,'actual':self.performance.get(case),'baseline_type':'shipped' if s.get('shipped_baseline') else 'same-run known-good'})
        self.verdict(case+'.performance_regression','PASS' if perf_ok else 'FAIL','PERFORMANCE_WITHIN_LIMIT' if perf_ok else 'PERFORMANCE_REGRESSION',[perf])
    def execute(self,profiles,faults=False,soak_seconds=None):
        self.selected_profiles=copy.deepcopy(profiles)
        ff=self.tools.get('ffmpeg');fp=self.tools.get('ffprobe')
        if not ff or not fp:
            self.verdict('required.video','HARNESS_ERROR','REQUIRED_CAPABILITY_UNAVAILABLE');return
        self.video=FrameRecorder(ff,fp,self.e.root/'video.mp4')
        write_json(self.e.root/'host_capabilities.json',{'os':sys.platform,'tools':self.tools,'backend':'RFB software virtual display','external_api':False,'windows_toolchain_verified':False,'windows_desktop_verified':False})
        self.verdict('host.discovery','PASS','BACKEND_CAPABILITIES_DISCOVERED',['host_capabilities.json'])
        for tool in ('python','ffmpeg','ffprobe'):
            cmd=[self.tools[tool],'-c','import sys;print(sys.version)'] if tool=='python' else [self.tools[tool],'-version']
            checked=subprocess.run(cmd,capture_output=True,timeout=15);name='host_tool_'+tool+'.log';(self.e.root/name).write_bytes(checked.stdout+checked.stderr);self.verdict('host.tool.'+tool,'PASS' if checked.returncode==0 else 'HARNESS_ERROR','HOST_TOOL_EXECUTED' if checked.returncode==0 else 'HOST_TOOL_FAILED',[name])
        for p in profiles:
            write_json(self.e.root/(p['game_id']+'_profile.json'),p)
            for s in p['scenarios']:
                first=self.scenario(p,s)
                if s.get('replay'):
                    second=self.scenario(p,s,tag=s['id']+'_same_seed_replay',replay=first['history']);fields=s.get('replay_fields',[]);ok=bool(fields) and all(k in first['final'] and k in second['final'] and first['final'][k]==second['final'][k] for k in fields);name=p['game_id']+'_seed_replay.json';write_json(self.e.root/name,{'seed':self.seed,'sequence':first['history'],'first':first['final'],'second':second['final'],'fields':fields});self.verdict(p['game_id']+'.seed_replay','PASS' if ok else 'FAIL','SEED_REPLAY_MATCH' if ok else 'SEED_REPLAY_MISMATCH',[name])
            plan=p.get('qa_plan',{})
            regression=plan.get('regression')
            if regression:
                goal=scenario_by_id(p,regression['scenario']);self.scenario(p,dict(goal,id='qa_baseline',baseline=True,save_load=False))
                self.scenario(p,dict(goal,id='qa_regression',regression=True,save_load=False))
                if regression.get('shipped_baseline'):
                    self.scenario(p,dict(goal,id='qa_shipped_regression',regression=True,shipped_baseline=True,save_load=False))
            soak=plan.get('soak')
            if soak:
                seconds=soak_seconds if soak_seconds is not None else soak['seconds']
                self.scenario(p,{'id':'qa_soak','agent':soak.get('agent','Random'),'time_budget':seconds,'action_budget':soak.get('action_budget',10000),'stop_on_goal':False,'soak':True,'observe_delay':soak.get('observe_delay',.08)})
            if faults:self.inject_faults(p)
        for name in ('ocr','gamepad'):
            self.verdict('optional.'+name,'NOT_RUN','CAPABILITY_UNSUPPORTED',gate='UNSUPPORTED_FOR_PROFILE')

    def inject_faults(self,profile):
        for config in fault_plan(profile):
            p=copy.deepcopy(profile);s=copy.deepcopy(config['scenario']);s['id']='qa_fault_'+config['id']
            p['actions'].update(config.get('actions',{}));p['launch']['extra_args']=list(p['launch'].get('extra_args',[]))+config.get('args',[])
            if config.get('missing_asset'):s['missing_asset']=config['missing_asset']
            start=len(self.results);self.scenario(p,s);observed=self.results[start:]
            for r in observed:r['gate']='INFORMATIONAL'
            expected=config['expected'];detected=any(r['status']==expected['status'] and r['reason_code']==expected['reason'] for r in observed)
            proof=profile['game_id']+'_injection_'+config['id']+'.json';write_json(self.e.root/proof,{'profile':profile['game_id'],'configuration':config,'detected':detected,'verdicts':observed})
            self.verdict(profile['game_id']+'.detector.'+config['id'],'PASS' if detected else 'FAIL','KNOWN_FAULT_DETECTED' if detected else 'KNOWN_FAULT_MISSED',[proof])
    def finish(self):
        for d in self.displays:
            try:d.close()
            except Exception:pass
        for p in self.supervisors:p.stop()
        if self.video:
            try:
                self.video.finish();self.verdict('required.video','PASS','VIDEO_STREAM_AND_TIMING_VALIDATED',['video.mp4','video.probe.json','video.timeline.json'])
                from recording import Recorder
                encoder=Recorder(self.video.ffmpeg,self.video.ffprobe,self.video.out)
                for index,(row,at) in enumerate(self.failure_times):
                    name='failure_clips/'+str(index).zfill(3)+'.mp4';target=self.e.root/name;target.parent.mkdir(parents=True,exist_ok=True);encoder.clip(target,at,before=1,after=2);row['evidence'].append(name);self.e.event('failure_clip',row['test_case'],file=name,video_offset=at)

            except Exception:
                (self.e.root/'video_error.txt').write_text(traceback.format_exc());self.verdict('required.video','HARNESS_ERROR','VIDEO_FAILED',['video_error.txt'])
        write_json(self.e.root/'causal_control_discovery.json',self.causal);write_json(self.e.root/'resource_samples.json',self.metrics);write_json(self.e.root/'reproduction.json',{'seed':self.seed,'backend':'rfb','profiles':sorted(self.coverage['profiles']),'command':'START_VALIDATION.sh --faults --soak-seconds 30','input_replay':'Semantic actions and actual input maps stored in action.jsonl and profile snapshots','requires_game_profile':True})
        # Last evidence audit prevents the reporting path from promoting absent files.
        for r in self.results:
            if r['status']=='PASS' and any(not inside(self.e.root,p).is_file() for p in r['evidence']):r['status']='HARNESS_ERROR';r['reason_code']='FINAL_EVIDENCE_MISSING'
        required=[r['test_case'] for r in self.results if r['gate']=='REQUIRED'];functional=certify(self.results,required,VERSION,True)
        data={'run_id':self.e.run_id,'core_version':VERSION,'overall':overall(self.results),'results':self.results,'coverage':{k:sorted(v) for k,v in self.coverage.items()},'functional_e2e_certified':functional,'completion_certified':certify(self.results,['windows.toolchain10','windows.fresh_e2e'],VERSION,os.name=='nt'),'certification_scope':'functional RFB fixtures; Windows product gates remain distinct','human_test_performed':False,'windows_e2e_executed':False,'unsupported':['OCR','audio','gamepad','arbitrary desktop discovery'],'required_game_profile':True}
        repro=self.e.root/'reproduction_assets'
        folders=['CORE']+sorted({p['source'] for p in self.contexts.values()})
        for folder in folders:
            shutil.copytree(inside(self.root,folder),repro/folder,ignore=shutil.ignore_patterns('__pycache__'),dirs_exist_ok=True)
        write_json(repro/'selected_profiles.json',getattr(self,'selected_profiles',[]))
        for i,p in enumerate(getattr(self,'selected_profiles',[])):write_json(repro/'VALIDATION_PROFILES'/('selected_'+str(i)+'.json'),p)
        for name in ('core_manifest.json','tool_manifest.json','python_manifest.json','git_runtime_manifest.json','capability_contract.json','acceptance_manifest.json','START_QA.cmd','BOOTSTRAP.ps1','START_VALIDATION.sh'):
            if (self.root/name).exists():shutil.copy2(self.root/name,repro/name)
        (repro/'REPRODUCE.txt').write_text('Requires an available Python 3 and FFmpeg/ffprobe as recorded in host_capabilities.json. Run python -B CORE/runner.py --backend rfb --faults --soak-seconds 30 from this directory. This is functional RFB reproduction, not Windows qualification.\n')
        report(self.e.root,data);self.e.manifest();result_zip(self.e.root);return data

def legacy_main():
    ap=argparse.ArgumentParser();ap.add_argument('--backend',default='auto');ap.add_argument('--prototype',choices=['logic','playable']);ap.add_argument('--root',default=str(Path(__file__).resolve().parents[1]));ap.add_argument('--seed',type=int,default=12345);ap.add_argument('--faults',action='store_true');ap.add_argument('--profile',action='append');ap.add_argument('--soak-seconds',type=float,default=None);ap.add_argument('--disable-capture',action='store_true');ap.add_argument('--output');args=ap.parse_args();root=Path(args.root).resolve();run_id='rfb_'+time.strftime('%Y%m%dT%H%M%S')+'_'+uuid.uuid4().hex[:6];out=Path(args.output).resolve() if args.output else inside(root,read_json(root/'acceptance_manifest.json').get('paths',{}).get('results','RESULTS'))/run_id
    if out.exists():raise SystemExit('OUTPUT_MUST_NOT_EXIST')
    run=RealRun(root,out,args.seed,args.disable_capture)
    try:
        errors=verify_core(root);write_json(out/'core_check.json',{'errors':errors,'version':VERSION})
        if errors:run.verdict('required.core','HARNESS_ERROR','CORE_INTEGRITY_FAILURE',['core_check.json'])
        else:
            run.verdict('required.core','PASS','CORE_INTEGRITY_VERIFIED',['core_check.json']);profiles=[read_json(root/p) for p in args.profile] if args.profile else [read_json(p) for p in sorted((root/'VALIDATION_PROFILES').glob('*.json'))];profiles=[p for p in profiles if not args.prototype or p['prototype_type']==args.prototype]
            if not profiles:raise ValueError('NO_APPLICABLE_PROFILE')
            if len({p['game_id'] for p in profiles})!=len(profiles):raise ValueError('DUPLICATE_GAME_ID')
            run.execute(profiles,args.faults,args.soak_seconds)
    except Exception:
        (out/'harness_error.txt').write_text(traceback.format_exc());run.verdict('run','HARNESS_ERROR','HARNESS_FAILURE',['harness_error.txt'])
    finally:data=run.finish();write_json(inside(root,read_json(root/'acceptance_manifest.json').get('paths',{}).get('results','RESULTS'))/'latest.json',{'run_id':run_id,'result_zip':str(out/'RESULT_FOR_CHATGPT.zip'),'overall':data['overall']})
    print('QA COMPLETE\nOverall Result: '+data['overall']+'\nResult ZIP Path: '+str(out/'RESULT_FOR_CHATGPT.zip'));return 0 if data['overall']=='PASS' else 2
def main():
    from session_validation import main as run
    return run()
if __name__=='__main__':raise SystemExit(main())
