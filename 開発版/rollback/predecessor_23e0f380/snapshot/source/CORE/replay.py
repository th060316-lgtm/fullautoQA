"""Replay recorded semantic actions through the same physical input adapter."""
import argparse,json,sys
from pathlib import Path
from common import *
from profile import load
from tools import Tools
from runner import Session
from recording import Recorder

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--profile',required=True);ap.add_argument('--actions',required=True);ap.add_argument('--case',required=True);ap.add_argument('--seed',type=int,default=12345);args=ap.parse_args()
    root=Path(__file__).resolve().parents[1]
    if verify_core(root):raise SystemExit('CORE_INTEGRITY_FAILURE')
    if __import__('os').name!='nt':raise SystemExit('WINDOWS_DESKTOP_REQUIRED')
    p=load(root,inside(root,args.profile));actions=[json.loads(x)['action'] for x in Path(args.actions).read_text(encoding='utf-8').splitlines() if json.loads(x).get('test_case')==args.case]
    e=Evidence(root/'RESULTS'/('replay_'+uuid.uuid4().hex),'replay_'+uuid.uuid4().hex);(e.root/'FULL_EVIDENCE').mkdir();t=Tools(root,e);results=t.prepare();s=Session(root,e,t,p);r=Recorder(t.get('ffmpeg'),str(Path(t.get('ffmpeg')).with_name('ffprobe.exe')),e.root/'FULL_EVIDENCE/replay.mp4')
    try:
        r.start();s.rec=r;s.run_scenario({'id':'replay','agent':'Smoke','sequence':actions,'action_budget':max(1,len(actions)),'time_budget':3600},args.seed,replay=actions);results+=s.results
    finally:
        s.stop()
        try:r.stop();results.append(e.result('video','PASS','RECORDING_PROBED',['FULL_EVIDENCE/replay.mp4','FULL_EVIDENCE/replay.probe.json']))
        except Exception as ex:results.append(e.result('video','HARNESS_ERROR','VIDEO_FAILED',detail=str(ex)))
        report(e.root,{'run_id':e.run_id,'overall':overall(results),'results':results});e.manifest();result_zip(e.root)
if __name__=='__main__':main()
