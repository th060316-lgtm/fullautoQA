import os,sys,subprocess,time,json,traceback
from pathlib import Path
from common import *
from windows import Desktop,child_pids,process_metrics
from adapters import image_features
from ocr_backend import OculixOCR

def selftest(root,e,t,required_tools=()):
    root=Path(root);out=e.root;results=[];p=None;d=None;required_tools=set(required_tools or ())
    gate=lambda *ids:'REQUIRED' if any(i in required_tools for i in ids) else 'OPTIONAL'
    available=lambda key:getattr(t,'is_available',lambda x:x in t.paths)(key)
    try:
        stdout=(out/'selftest_input_stdout.log').open('wb');stderr=(out/'selftest_input_stderr.log').open('wb');state=out/'selftest_input_state.json'
        p=subprocess.Popen([t.get('python'),'-B','-E','-s',str(root/'CORE/harness_probe.py'),str(state)],stdout=stdout,stderr=stderr,cwd=root)
        d=Desktop();d.find(child_pids(p.pid),15);d.focus();time.sleep(.2);d.perform({'kind':'key','key':'A'});deadline=time.monotonic()+3
        while not state.exists() and time.monotonic()<deadline:time.sleep(.1)
        observed=read_json(state) if state.exists() else {};ok=observed.get('key','').lower()=='a'
        write_json(out/'selftest_input_assertion.json',{'observed':observed,'expected':'a','pid':p.pid})
        results.append(e.result('selftest.input','PASS' if ok else 'HARNESS_ERROR','INPUT_RECEIVED' if ok else 'INPUT_NOT_RECEIVED',['selftest_input_assertion.json']))
        d.capture(out/'selftest_screen.bmp');features=image_features(out/'selftest_screen.bmp');valid=len(features)==48*32*3 and len(set(features))>1
        results.append(e.result('selftest.screenshot','PASS' if valid else 'HARNESS_ERROR','NONEMPTY_CAPTURE' if valid else 'INVALID_SCREENSHOT',['selftest_screen.bmp']))
        metrics=process_metrics(p.pid);write_json(out/'selftest_process.json',metrics);results.append(e.result('selftest.process_monitor','PASS' if metrics.get('ram',0)>0 else 'HARNESS_ERROR','METRICS_OBSERVED' if metrics.get('ram',0)>0 else 'METRICS_UNAVAILABLE',['selftest_process.json']))
    except Exception:
        (out/'selftest_error.txt').write_text(traceback.format_exc(),encoding='utf-8');results.append(e.result('selftest.desktop','HARNESS_ERROR','SELFTEST_FAILED',['selftest_error.txt']))
    finally:
        if d:
            try:d.release()
            except Exception:pass
        if p:
            if p.poll() is None:
                try:subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),'/PID',str(p.pid),'/T','/F'],capture_output=True,timeout=10)
                except Exception:p.kill()
            stdout.close();stderr.close()

    r=subprocess.run([t.get('python'),'-B','-m','unittest','discover','-s',str(root/'TESTS'),'-p','test_*.py'],cwd=root,capture_output=True,timeout=60)
    (out/'selftest_core.log').write_bytes(r.stdout+r.stderr);results.append(e.result('selftest.core_contract','PASS' if r.returncode==0 else 'HARNESS_ERROR','CORE_TESTS_PASSED' if r.returncode==0 else 'CORE_TEST_FAILURE',['selftest_core.log']))

    if not available('ahk'):
        results.append(e.result('tool.ahk.functional','NOT_RUN','TOOL_NOT_PREPARED',gate=gate('ahk')))
    else:
        try:
            script=out/'selftest.ahk';proof=out/'ahk_proof.txt'
            script.write_text('#Requires AutoHotkey v2.0\nFileAppend("AHK_EXECUTED", A_Args[1], "UTF-8")\nExitApp\n',encoding='utf-8')
            r=subprocess.run([t.get('ahk'),'/ErrorStdOut',str(script),str(proof)],capture_output=True,timeout=15)
            (out/'ahk.log').write_bytes(r.stdout+r.stderr);ok=r.returncode==0 and proof.exists() and 'AHK_EXECUTED' in proof.read_text(encoding='utf-8-sig')
            results.append(e.result('tool.ahk.functional','PASS' if ok else 'HARNESS_ERROR','AHK_SCRIPT_EXECUTED' if ok else 'AHK_EXECUTION_FAILED',['ahk.log']+(['ahk_proof.txt'] if proof.exists() else []),gate=gate('ahk')))
        except Exception as ex:results.append(e.result('tool.ahk.functional','HARNESS_ERROR','AHK_EXECUTION_FAILED',detail=repr(ex),gate=gate('ahk')))

    if not (available('java') and available('oculix')):
        results.append(e.result('tool.oculix.linkage','NOT_RUN','TOOL_NOT_PREPARED',gate=gate('java','oculix')))
        results.append(e.result('tool.oculix.visual','NOT_RUN','TOOL_NOT_PREPARED',gate='OPTIONAL'))
        results.append(e.result('selftest.ocr','NOT_RUN','NO_VALIDATED_BACKEND',gate='OPTIONAL'))
    else:
        link_ok=False
        try:
            source=out/'OculixProbe.java';source.write_text('class OculixProbe { public static void main(String[] args) throws Exception { var u = new java.io.File(args[0]).toURI().toURL(); try(var c = new java.net.URLClassLoader(new java.net.URL[]{u})) { System.out.println(Class.forName("org.sikuli.ide.Sikulix", false, c).getName()); } } }',encoding='utf-8')
            r=subprocess.run([t.get('java'),str(source),t.get('oculix')],capture_output=True,timeout=30,cwd=out);(out/'oculix_probe.log').write_bytes(r.stdout+r.stderr)
            link_ok=r.returncode==0 and b'org.sikuli.ide.Sikulix' in r.stdout
            results.append(e.result('tool.oculix.linkage','PASS' if link_ok else 'HARNESS_ERROR','JAVA_JAR_CLASS_LINKED' if link_ok else 'OCULIX_LINK_FAILED',['oculix_probe.log'],gate=gate('java','oculix')))
        except Exception as ex:
            results.append(e.result('tool.oculix.linkage','HARNESS_ERROR','OCULIX_LINK_FAILED',detail=repr(ex),gate=gate('java','oculix')))

        if not link_ok:
            results.append(e.result('tool.oculix.visual','HARNESS_ERROR','OCULIX_LINK_FAILED',['oculix_probe.log'],gate='OPTIONAL'))
            results.append(e.result('selftest.ocr','HARNESS_ERROR','OCULIX_LINK_FAILED',['oculix_probe.log'],gate='OPTIONAL'))
        else:
            p2=None;d2=None;stdout2=None;stderr2=None
            try:
                state2=out/'oculix_visual_input_state.json'
                stdout2=(out/'oculix_visual_input_stdout.log').open('wb')
                stderr2=(out/'oculix_visual_input_stderr.log').open('wb')
                p2=subprocess.Popen([t.get('python'),'-B','-E','-s',str(root/'CORE/harness_probe.py'),str(state2)],stdout=stdout2,stderr=stderr2,cwd=root)
                d2=Desktop();d2.find(child_pids(p2.pid),15);d2.focus();time.sleep(.5)
                rect=d2.state().get('rect') or []
                if len(rect)!=4:raise OSError('OCULIX_TARGET_RECT_UNAVAILABLE')
                x,y,right,bottom=[int(v) for v in rect];w=right-x;h=bottom-y
                if w<=0 or h<=0:raise OSError('OCULIX_TARGET_RECT_INVALID')
                d2.capture(out/'oculix_visual_target.bmp')
                backend=OculixOCR(t,d2,out,interval_seconds=0)
                record=backend.read()
                text=record.get('text','')
                normalized=' '.join(text.upper().split())
                ok=record.get('status')=='PASS' and 'HARNESS' in normalized and 'TEST' in normalized
                write_json(out/'oculix_visual_assertion.json',{'rect':[x,y,right,bottom],'ocr_text':text,'required_tokens':['HARNESS','TEST'],'matched':ok,'backend_record':record})
                visual_evidence=list(record.get('evidence') or [])+['oculix_visual_assertion.json','oculix_visual_target.bmp']
                results.append(e.result('tool.oculix.visual','PASS' if ok else 'HARNESS_ERROR','OCULIX_OCR_TEXT_OBSERVED' if ok else 'OCULIX_OCR_QUALIFICATION_FAILED',visual_evidence,gate='OPTIONAL'))
                results.append(e.result('selftest.ocr','PASS' if ok else 'HARNESS_ERROR','OCR_BACKEND_VALIDATED' if ok else 'OCULIX_OCR_QUALIFICATION_FAILED',visual_evidence,gate='OPTIONAL',claim='Visible-window OCR capability only; not semantic game-state proof'))
            except Exception as ex:
                write_json(out/'oculix_visual_error.json',{'error':repr(ex)})
                results.append(e.result('tool.oculix.visual','HARNESS_ERROR','OCULIX_OCR_QUALIFICATION_FAILED',['oculix_visual_error.json'],detail=repr(ex),gate='OPTIONAL'))
                results.append(e.result('selftest.ocr','HARNESS_ERROR','OCULIX_OCR_QUALIFICATION_FAILED',['oculix_visual_error.json'],detail=repr(ex),gate='OPTIONAL'))
            finally:
                if d2:
                    try:d2.release()
                    except Exception:pass
                if p2 and p2.poll() is None:
                    try:subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),'/PID',str(p2.pid),'/T','/F'],capture_output=True,timeout=10)
                    except Exception:p2.kill()
                if stdout2:stdout2.close()
                if stderr2:stderr2.close()

    if not available('c'):
        results.append(e.result('tool.c.compile_execute','NOT_RUN','TOOL_NOT_PREPARED',gate=gate('c')))
    else:
        try:
            source=out/'c_probe.c';source.write_text('#include <stdio.h>\nint main(void){puts("C_RUNTIME_OK");return 0;}\n',encoding='ascii');exe=out/'c_probe.exe'
            r=subprocess.run([t.get('c'),str(source),'-o',str(exe)],capture_output=True,timeout=30)
            data=r.stdout+r.stderr
            if r.returncode==0:
                r=subprocess.run([str(exe)],capture_output=True,timeout=10);data+=r.stdout+r.stderr
            (out/'c_probe.log').write_bytes(data);ok=r.returncode==0 and b'C_RUNTIME_OK' in data
            results.append(e.result('tool.c.compile_execute','PASS' if ok else 'HARNESS_ERROR','C_COMPILED_AND_EXECUTED' if ok else 'C_EXECUTION_FAILED',['c_probe.log'],gate=gate('c')))
        except Exception as ex:results.append(e.result('tool.c.compile_execute','HARNESS_ERROR','C_EXECUTION_FAILED',detail=repr(ex),gate=gate('c')))
    return results
