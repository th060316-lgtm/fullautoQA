"""Execute windows_runner.Session over a real RFB GUI; no Session methods mocked.
This exercises native campaign control flow, but does not certify Windows APIs.
"""
import argparse,time,uuid,traceback,shutil
from pathlib import Path
from common import *
from tools import Tools
from backends import discover_tools
from stream_video import PipeFrameRecorder
from recording import Recorder
from regression import import_baseline
from windows_runner import Session,finalization_issue
from contracts import audit_plan,prototype_summary
from finalize import finalize_run
from coordinator import prepare_execution,preflight_execution,execution_finalizer
class VirtualRecording:
    def __init__(self,ff,probe,path):self.frames=PipeFrameRecorder(ff,probe,path);self.started=self.frames.start;self.p=None
    def frame(self,path):self.frames.frame(path)
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--root',default=str(Path(__file__).resolve().parents[1]));ap.add_argument('--backend',default='rfb');ap.add_argument('--prototype',choices=['logic','playable']);ap.add_argument('--disable-capture',action='store_true');ap.add_argument('--profile',action='append');ap.add_argument('--soak-seconds',type=float);ap.add_argument('--baseline');ap.add_argument('--seed',type=int,default=12345);ap.add_argument('--output');ap.add_argument('--faults',action=argparse.BooleanOptionalAction,default=True);args=ap.parse_args();root=Path(args.root).resolve();out=Path(args.output).resolve() if args.output else inside(root,read_json(root/'acceptance_manifest.json').get('paths',{}).get('results','RESULTS'))/('session_'+time.strftime('%Y%m%dT%H%M%S')+'_'+uuid.uuid4().hex[:6])
    if out.exists():raise ValueError('OUTPUT_MUST_NOT_EXIST')
    e=Evidence(out,out.name);results=[];sessions=[];video=None;profiles=[];prepared=None;settings=read_json(root/'acceptance_manifest.json')
    for kind in ('state','action','process'):(out/(kind+'.jsonl')).touch()
    latest=out.parent/'latest.json'
    global_plan=[{'test_case':'core','gate':'REQUIRED'},{'test_case':'video','gate':'REQUIRED'}]
    write_json(out/'global_expected_cases.json',global_plan)
    try:
        errors=verify_core(root);write_json(out/'core_check.json',{'errors':errors});results.append(e.result('core','PASS' if not errors else 'HARNESS_ERROR','CORE_INTEGRITY_VERIFIED' if not errors else 'CORE_INTEGRITY_FAILURE',['core_check.json']))
        if errors:raise ValueError('CORE_INTEGRITY_FAILURE')
        profiles=args.profile or [p.relative_to(root).as_posix() for p in sorted((root/'VALIDATION_PROFILES').glob('*.json'))]
        manifest={'schema_version':1,'targets':[{'id':str(i),'profile':rel,'kind':'fixture'} for i,rel in enumerate(profiles)]}
        prepared=prepare_execution(root,manifest,settings);results+=preflight_execution(e,prepared)
        t=Tools(root,e);t.paths={k:v for k,v in discover_tools().items() if v};video=VirtualRecording(t.get('ffmpeg'),t.get('ffprobe'),out/'video.mp4');imported=import_baseline(args.baseline,out) if args.baseline else None
        profiles=args.profile or [p.relative_to(root).as_posix() for p in sorted((root/'VALIDATION_PROFILES').glob('*.json'))];ids=set()
        for rel in profiles:
            p=read_json(inside(root,rel))
            if args.prototype and p['prototype_type']!=args.prototype:continue
            if p['game_id'] in ids:raise ValueError('DUPLICATE_GAME_ID')
            ids.add(p['game_id'])
            if p.get('display',{}).get('kind')!='rfb':raise ValueError('VALIDATION_REQUIRES_RFB_TRANSPORT')
            write_json(out/(p['game_id']+'_profile.json'),p);s=Session(root,e,t,p);s.rec=video;s.disable_capture=args.disable_capture;s.imported_baselines=imported;sessions.append(s);results+=s.execute(args.seed,{'faults':args.faults,'soak_seconds':args.soak_seconds})
        if not sessions:raise ValueError('NO_APPLICABLE_PROFILE')
    except Exception:
        (out/'error.txt').write_text(traceback.format_exc());results.append(e.result('run','HARNESS_ERROR','HARNESS_FAILURE',['error.txt']))
    finally:
        known={id(row) for row in results}
        for session in sessions:
            for row in session.results:
                if id(row) not in known:results.append(row);known.add(id(row))
        data={'run_id':e.run_id,'core_version':VERSION,'results':results,'completion_certified':False,'windows_e2e_executed':False,'execution_scope':'Actual native Session control flow over RFB; not Win32'}
        try:
            if video:
                try:
                    video.frames.finish();results.append(e.result('video','PASS','VIDEO_STREAM_AND_TIMING_VALIDATED',['video.mp4','video.probe.json','video.timeline.json']));proxy=Recorder(video.frames.ffmpeg,video.frames.ffprobe,video.frames.out)
                    for n,(case,at) in enumerate(x for s in sessions for x in s.failure_times):
                        name='failure_clips/'+str(n)+'.mp4';target=out/name;target.parent.mkdir(parents=True,exist_ok=True);proxy.clip(target,at,before=1,after=2);e.event('failure_clip',case,file=name,video_offset=at)
                except Exception:
                    (out/'video_error.txt').write_text(traceback.format_exc());results.append(e.result('video','HARNESS_ERROR','VIDEO_FAILED',['video_error.txt']))
        except Exception as ex:
            finalization_issue(e,results,'recording.finalize','RECORDING_FINALIZE_FAILURE',ex)
        try:
            latest=inside(root,read_json(root/'acceptance_manifest.json').get('paths',{}).get('results','RESULTS'))/'latest.json'
            write_json(out/'reproduction.json',{'seed':args.seed,'core_version':VERSION,'runner':'CORE/session_validation.py','profiles':profiles,'options':{'faults':args.faults,'soak_seconds':args.soak_seconds,'baseline':args.baseline},'scope':'Session control flow and actual RFB transport; Win32 not executed'})
            repro=out/'reproduction_assets'
            for folder in ['CORE']+sorted({s.p['source'] for s in sessions}):shutil.copytree(inside(root,folder),repro/folder,ignore=shutil.ignore_patterns('__pycache__'),dirs_exist_ok=True)
            for s in sessions:write_json(repro/'VALIDATION_PROFILES'/(s.p['game_id']+'.json'),s.p)
            write_json(out/'execution_scope.json',{'runner':'windows_runner.Session.execute','session_methods_mocked':False,'transport':'RFB 3.8 actual GUI','native_windows_executed':False,'seed':args.seed})
            data['coverage']={session.p['game_id']:{k:sorted(v) for k,v in session.coverage.items()} for session in sessions}
        except Exception as ex:
            finalization_issue(e,results,'metadata','METADATA_FINALIZE_FAILURE',ex)
        finally:
            try:
                audit_plan(e,results,global_plan,'global_expected_cases.json')
                for row in results:
                    if row['status']=='PASS' and (not row.get('evidence') or any(not inside(out,f).is_file() for f in row['evidence'])):row.update(status='HARNESS_ERROR',reason_code='FINAL_EVIDENCE_MISSING')
                required=[r['test_case'] for r in global_plan if r['gate']=='REQUIRED']+[case for session in sessions for case in getattr(session,'required_cases',[])]
                data['functional_cases_certified']=certify(results,required,VERSION,bool(sessions) and all(session.coverage['agents']=={'Smoke','Goal','Explorer','Random'} for session in sessions))
                data['prototype_results']=prototype_summary(sessions,results)
            except Exception as ex:
                finalization_issue(e,results,'plan.audit','PLAN_AUDIT_FAILURE',ex);data['functional_cases_certified']=False
            finally:
                data['overall']=overall(results)
                published=finalize_run(e,data,cleanup=tuple(session.stop for session in sessions),latest_path=latest,execution=execution_finalizer(root,prepared,settings,'fixture'))
                data['overall']=published['overall']
    print('QA COMPLETE\nOverall Result: '+data['overall']+'\nResult ZIP Path: '+str(published.get('result_zip') or 'NOT_CREATED')+'\nResult Folder: '+str(out));return 0 if data['overall']=='PASS' and published.get('zip_created') else 2
if __name__=='__main__':raise SystemExit(main())
