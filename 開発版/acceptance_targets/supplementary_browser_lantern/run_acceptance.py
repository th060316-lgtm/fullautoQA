"""Real supplementary browser execution; deliberately separate from selftests/A-B-A."""
import argparse,functools,hashlib,http.server,json,os,platform,shutil,struct,sys,threading,time,traceback
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def write(path,value):Path(path).write_text(json.dumps(value,indent=2,ensure_ascii=False,default=str)+'\n',encoding='utf-8')

def visual(path):
    # Game-side visual contract: find the rendered gold tile, not JavaScript state.
    data=Path(path).read_bytes();offset=struct.unpack_from('<I',data,10)[0];width,height=struct.unpack_from('<ii',data,18);stride=(width*3+3)&~3;xs=[]
    for y in range(abs(height)):
        row=data[offset+y*stride:offset+(y+1)*stride];at=0
        while True:
            at=row.find(bytes([68,187,255]),at)
            if at<0:break
            if at%3==0:xs.append(at//3)
            at+=3
    if len(xs)<30:raise AssertionError('VISIBLE_LANTERN_NOT_FOUND')
    center=(min(xs)+max(xs))/2;position=round((center/width-.06)/(.88/5)-.5)
    if not 0<=position<=4:raise AssertionError('VISIBLE_LANTERN_POSITION_INVALID')
    return {'position':position,'goal':position==4,'source':'rendered gold tile centroid','centroid_x':center,'dimensions':[width,abs(height)]}

def execute(exe,out,target,extra):
    out.mkdir(parents=True,exist_ok=False);work=out/'work';work.mkdir();shutil.copy2(ROOT/'index.html',work/'index.html');user=work/'browser_user';endpoint=user/'DevToolsActivePort'
    argv=[str(exe),'--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--remote-debugging-port=0','--user-data-dir='+str(user),*extra,'about:blank']
    profile={'game_id':'supplementary_lantern_steps','version':'1.0.0','display':{'kind':'browser','transport':'cdp','target':target or 'index.html','endpoint':'browser_user/DevToolsActivePort','viewport':{'width':960,'height':640},'runtime':{'engine':'chromium-cdp','executable':str(exe),'sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'provenance':'explicit preprovisioned executable; no download'}},'launch':{'argv':argv},'state_signature':['position'],'actions':{'advance':{'inputs':[{'kind':'key','key':'RIGHT'}]},'back':{'inputs':[{'kind':'key','key':'LEFT'}]}},'allowed_random_actions':['advance','back']}
    write(out/'profile.json',profile);supervisor=ProcessSupervisor();display=None
    with (out/'stdout.log').open('wb') as stdout,(out/'stderr.log').open('wb') as stderr:
        process=supervisor.start(argv,work,stdout,stderr)
        try:
            deadline=time.monotonic()+30
            while not endpoint.exists():
                if process.poll() is not None:raise AssertionError('BROWSER_PROCESS_EXIT:'+str(process.returncode))
                if time.monotonic()>deadline:raise TimeoutError('BROWSER_START_TIMEOUT')
                time.sleep(.03)
            display=select_display(profile,work,process);display.focus();adapter=Adapter(profile,{'desktop':display,'work':work})
            result={'target':target or 'index.html','backend':display.state(),'start_process':supervisor.metrics(),'modes':{},'scope':'supplementary self-authored playable target; not fixture or final A/B acceptance'}
            for mode in ['Smoke','Goal','Explorer','Random']:
                display.perform({'kind':'key','key':'R'});time.sleep(.05)
                scenario={'agent':mode,'sequence':['advance']*4 if mode=='Smoke' else [],'policy':[{'when':{'field':'position','op':'lt','value':4},'action':'advance'}] if mode=='Goal' else [],'action_budget':32,'time_budget':120,'goal':{'position':4}}
                agent=Agent(profile,scenario,8);actions=[];screenshot=out/(mode+'_000.bmp');display.capture(screenshot);before=visual(screenshot);features=image_features(screenshot)
                while not agent.exhausted() and not before['goal']:
                    action=agent.choose(before,features);adapter.act(action);time.sleep(.04);screenshot=out/(mode+'_'+str(len(actions)+1).zfill(3)+'.bmp');display.capture(screenshot);after=visual(screenshot);new_features=image_features(screenshot);agent.feedback(before,after,action,features,new_features);actions.append({'action':action,'inputs':profile['actions'][action]['inputs'],'before':before,'after':after,'screenshot':screenshot.name});before,features=after,new_features
                row={'status':'PASS' if before['goal'] and agent.mode==mode else 'FAIL','configured_mode':mode,'executed_mode':agent.mode,'goal_observed':before['goal'],'goal_capability_evidence':mode=='Goal','agent_export':agent.export(),'actions':actions,'observation':'rendered pixels only; no state bridge'};result['modes'][mode]=row;write(out/(mode+'_actions.json'),row)
            display.perform({'kind':'key','key':'R'});time.sleep(.04);bounds=display.evaluate("(()=>{const r=document.querySelector('#right').getBoundingClientRect();return {x:(r.x+r.width/2)/innerWidth,y:(r.y+r.height/2)/innerHeight}})()")
            display.perform({'kind':'click',**bounds});display.capture(out/'pointer.bmp');result['pointer']={'coordinates':bounds,'after':visual(out/'pointer.bmp')}
            if result['pointer']['after']['position']!=1:raise AssertionError('POINTER_INPUT_NO_REACTION')
            result['end_process']=supervisor.metrics();result['backend_after']=display.state();result['status']='PASS' if all(r['status']=='PASS' for r in result['modes'].values()) else 'FAIL';write(out/'result.json',result)
            return result
        except Exception as ex:
            write(out/'failure.json',{'status':'HARNESS_ERROR','reason':repr(ex),'traceback':traceback.format_exc(),'pid':process.pid,'exit_code':process.poll(),'scope':'supplementary browser attempt; not PASS'})
            raise
        finally:
            try:
                if display:display.close()
            finally:
                supervisor.stop();write(out/'process_stop.json',{'pid':process.pid,'exit_code':process.poll(),'terminated':process.poll() is not None})

def main():
    global ProcessSupervisor,select_display,Adapter,image_features,Agent
    parser=argparse.ArgumentParser();parser.add_argument('--source-root',required=True);parser.add_argument('--browser',required=True);parser.add_argument('--out',required=True);parser.add_argument('--runtime-arg',action='append',default=[]);args=parser.parse_args();sys.path.insert(0,str(Path(args.source_root).resolve()/'CORE'))
    from backends import ProcessSupervisor,select_display
    from adapters import Adapter,image_features
    from agents import Agent
    exe=Path(args.browser).resolve();out=Path(args.out).resolve();out.mkdir(parents=True,exist_ok=False);server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(http.server.SimpleHTTPRequestHandler,directory=str(ROOT)));threading.Thread(target=server.serve_forever,daemon=True).start()
    summary={'scope':'supplementary independently authored playable Web target; not selftest, third-party game or final A-B-A','platform':platform.platform(),'source':{'version':'1.0.0','sha256':hashlib.sha256((ROOT/'index.html').read_bytes()).hexdigest()},'runtime_executable':str(exe),'runtime_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'windows_acceptance':'NOT_RUN' if os.name!='nt' else 'this run only'}
    try:
        results=[execute(exe,out/'file',None,args.runtime_arg),execute(exe,out/'loopback','http://127.0.0.1:'+str(server.server_port)+'/index.html',args.runtime_arg)];summary['targets']=[{'target':r['target'],'status':r['status'],'modes':{k:v['status'] for k,v in r['modes'].items()}} for r in results];summary['status']='PASS' if all(r['status']=='PASS' for r in results) else 'FAIL';write(out/'summary.json',summary);print(json.dumps(summary,indent=2));return 0 if summary['status']=='PASS' else 1
    except Exception as ex:
        summary.update(status='HARNESS_ERROR',reason=repr(ex));write(out/'summary.json',summary);raise
    finally:server.shutdown();server.server_close()
if __name__=='__main__':raise SystemExit(main())
