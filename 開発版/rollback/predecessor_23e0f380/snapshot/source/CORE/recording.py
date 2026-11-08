"""Continuous offline video with ffmpeg; OBS functional probe uses its local WebSocket."""
import subprocess,time,os,json,socket,base64,hashlib,struct,uuid
from pathlib import Path

class Recorder:
    def __init__(self,ffmpeg,ffprobe,out,fps=10):self.ffmpeg=ffmpeg;self.ffprobe=ffprobe;self.out=Path(out);self.fps=fps;self.p=None;self.log=None;self.started=None
    def start(self):
        if os.name!='nt':raise OSError('WINDOWS_CAPTURE_REQUIRED')
        self.out.parent.mkdir(parents=True,exist_ok=True);self.log=self.out.with_suffix('.log').open('wb');self.started=time.monotonic()
        cmd=[self.ffmpeg,'-hide_banner','-y','-f','gdigrab','-framerate',str(self.fps),'-draw_mouse','1','-i','desktop','-vf','scale=1280:-2','-c:v','libx264','-preset','ultrafast','-crf','30','-pix_fmt','yuv420p',str(self.out)]
        self.p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=self.log,stderr=self.log)
        time.sleep(.7)
        if self.p.poll() is not None:raise OSError('VIDEO_START_FAILED')
    def stop(self):
        if self.p:
            if self.p.poll() is None:
                try:self.p.communicate(b'q\n',timeout=20)
                except subprocess.TimeoutExpired:self.p.kill();self.p.wait()
            rc=self.p.returncode
            if self.log:self.log.close()
            if rc or not self.out.exists():raise OSError('VIDEO_RECORDING_FAILED')
            p=subprocess.run([self.ffprobe,'-v','error','-show_format','-show_streams','-of','json',str(self.out)],capture_output=True,timeout=30)
            self.out.with_suffix('.probe.json').write_bytes(p.stdout)
            data=json.loads(p.stdout or b'{}');duration=float(data.get('format',{}).get('duration',0))
            if p.returncode or duration<max(.1,(time.monotonic()-self.started)*.85-1) or not any(x['codec_type']=='video' for x in data.get('streams',[])):raise OSError('VIDEO_VALIDATION_FAILED')
            return {'duration':duration,'expected':time.monotonic()-self.started,'path':str(self.out)}
    def clip(self,dst,at,before=4,after=6):
        start=max(0,at-before)
        r=subprocess.run([self.ffmpeg,'-y','-ss',str(start),'-i',str(self.out),'-t',str(before+after),'-an','-c:v','libx264','-preset','ultrafast','-crf','30',str(dst)],capture_output=True,timeout=90)
        if r.returncode or not Path(dst).exists() or Path(dst).stat().st_size<100:raise OSError('FAILURE_CLIP_FAILED')
        return start

class WebSocket:
    def __init__(self,port=4457,password=None):
        self.s=socket.create_connection(('127.0.0.1',port),timeout=10);self.buffer=b'';key=base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f'GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        while b'\r\n\r\n' not in self.buffer:self.buffer+=self.s.recv(4096)
        header,self.buffer=self.buffer.split(b'\r\n\r\n',1)
        accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        if b' 101 ' not in header or accept not in header:raise OSError('OBS_WEBSOCKET_HANDSHAKE')
        hello=self.recv()
        identify={'rpcVersion':1,'eventSubscriptions':0}
        auth=hello.get('d',{}).get('authentication')
        if auth:
            if not password:raise OSError('OBS_AUTH_REQUIRED')
            secret=base64.b64encode(hashlib.sha256((password+auth['salt']).encode()).digest()).decode()
            identify['authentication']=base64.b64encode(hashlib.sha256((secret+auth['challenge']).encode()).digest()).decode()
        self.send({'op':1,'d':identify})
        if self.recv().get('op')!=2:raise OSError('OBS_IDENTIFY_FAILED')
    def exact(self,n):
        while len(self.buffer)<n:
            b=self.s.recv(max(4096,n-len(self.buffer)))
            if not b:raise OSError('OBS_SOCKET_CLOSED')
            self.buffer+=b
        out,self.buffer=self.buffer[:n],self.buffer[n:];return out
    def send(self,obj,opcode=1):
        data=json.dumps(obj).encode() if opcode==1 else obj;mask=os.urandom(4);n=len(data);header=bytes([0x80|opcode,0x80|(n if n<126 else 126 if n<65536 else 127)])
        if n>=126:header+=struct.pack('!H' if n<65536 else '!Q',n)
        self.s.sendall(header+mask+bytes(x^mask[i%4] for i,x in enumerate(data)))
    def recv(self):
        while True:
            a,b=self.exact(2);n=b&127
            if n==126:n=struct.unpack('!H',self.exact(2))[0]
            elif n==127:n=struct.unpack('!Q',self.exact(8))[0]
            if n>16*1024*1024:raise OSError('OBS_FRAME_LIMIT')
            mask=self.exact(4) if b&128 else None;data=self.exact(n)
            if mask:data=bytes(x^mask[i%4] for i,x in enumerate(data))
            if a&15==9:self.send(data,10);continue
            if a&15==8:raise OSError('OBS_CLOSED')
            if a&15==1:return json.loads(data)
    def call(self,kind,data=None):
        rid=str(uuid.uuid4());self.send({'op':6,'d':{'requestType':kind,'requestId':rid,'requestData':data or {}}})
        for _ in range(100):
            r=self.recv()
            if r.get('op')==7 and r['d']['requestId']==rid:
                if not r['d']['requestStatus']['result']:raise OSError('OBS_RPC:'+str(r))
                return r['d'].get('responseData',{})
        raise OSError('OBS_RPC_TIMEOUT')
    def close(self):self.s.close()

def obs_probe(exe,output):
    # Portable config is stored beside obs executable in its private tool tree.
    exe=Path(exe);home=exe.parents[2];(home/'portable_mode.txt').touch();cfg=home/'config/obs-studio';cfg.mkdir(parents=True,exist_ok=True)
    password=base64.urlsafe_b64encode(os.urandom(24)).decode()
    (cfg/'global.ini').write_text('[General]\nFirstRun=true\n[OBSWebSocket]\nServerEnabled=true\nServerPort=4457\nAuthRequired=true\nServerPassword='+password+'\nAlertsEnabled=false\n',encoding='utf-8')
    log=Path(output)/'obs.log';fp=log.open('wb');p=subprocess.Popen([str(exe),'--portable','--minimize-to-tray','--disable-shutdown-check'],cwd=exe.parent,stdout=fp,stderr=fp);ws=None
    try:
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            if p.poll() is not None:raise OSError('OBS_EXITED')
            try:ws=WebSocket(password=password);break
            except (OSError,TimeoutError):time.sleep(.5)
        if ws is None:raise OSError('OBS_UNAVAILABLE')
        scene='qa_'+uuid.uuid4().hex[:8];ws.call('CreateScene',{'sceneName':scene});ws.call('SetCurrentProgramScene',{'sceneName':scene})
        kinds=ws.call('GetInputKindList')['inputKinds'];kind=next((k for k in kinds if k.startswith('monitor_capture')),None)
        if not kind:raise OSError('OBS_SCREEN_CAPTURE_UNAVAILABLE')
        ws.call('CreateInput',{'sceneName':scene,'inputName':'qa_screen_'+scene,'inputKind':kind,'inputSettings':{'monitor':0,'capture_cursor':True},'sceneItemEnabled':True})
        ws.call('SetRecordDirectory',{'recordDirectory':str(Path(output).resolve())});ws.call('StartRecord');time.sleep(2);r=ws.call('StopRecord')
        path=Path(r['outputPath'])
        if not path.is_file() or path.stat().st_size<100:raise OSError('OBS_NO_VIDEO')
        return str(path)
    finally:
        if ws:
            try:ws.close()
            except OSError:pass
        if p.poll() is None:
            subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),'/PID',str(p.pid),'/T','/F'],capture_output=True,timeout=15)
        fp.close()

def tool_requirements(manifest):
    requirements={}
    for entry in manifest.get('required_tools',[]):
        if not isinstance(entry,dict) or not entry.get('id') or not entry.get('reason'):raise ValueError('REQUIRED_TOOL_REQUIRES_PRODUCT_JUSTIFICATION')
        requirements[entry['id']]=entry['reason']
    return requirements

def tool_gate(tool,requirements):return 'REQUIRED' if tool in requirements else 'OPTIONAL'

def select_recording(factories,output,preferences=None):
    """Try supported implementations; only loss of the video capability is fatal."""
    from common import write_json
    attempts=[]
    for name in preferences or list(factories):
        if name not in factories:
            attempts.append({'backend':name,'status':'UNAVAILABLE'});continue
        obj=None
        try:
            obj=factories[name]();obj.start();obj.backend_name=name
            attempts.append({'backend':name,'status':'SELECTED'});write_json(Path(output)/'recording_selection.json',{'attempts':attempts,'selected':name});return obj
        except Exception as ex:
            attempts.append({'backend':name,'status':'UNAVAILABLE','error':repr(ex)})
            if obj and hasattr(obj,'cancel'):
                try:obj.cancel()
                except Exception:pass
            elif obj and getattr(obj,'p',None) and obj.p.poll() is None:
                obj.p.kill();obj.p.wait(timeout=10)
    write_json(Path(output)/'recording_selection.json',{'attempts':attempts,'selected':None})
    raise OSError('REQUIRED_VIDEO_CAPABILITY_UNAVAILABLE')

class CapturedFrameRecorder:
    def __init__(self,ffmpeg,ffprobe,out,capture):
        from stream_video import PipeFrameRecorder as FrameRecorder
        import threading
        self.frames=FrameRecorder(ffmpeg,ffprobe,out);self.out=Path(out);self.capture=capture;self.event=threading.Event();self.thread=None;self.error=None;self.p=None;self.started=None
    def start(self):
        import threading
        self.started=time.monotonic();self.out.parent.mkdir(parents=True,exist_ok=True)
        # Prove a usable capture before selecting this backend.
        self.capture(self.out.parent/'recording_capture_probe.bmp');self.frames.frame(self.out.parent/'recording_capture_probe.bmp')
        def loop():
            try:
                while not self.event.wait(.35):
                    file=self.out.parent/'recording_current.bmp';self.capture(file);self.frames.frame(file)
            except Exception as ex:self.error=ex
        self.thread=threading.Thread(target=loop,daemon=True);self.thread.start()
    def cancel(self):
        self.event.set()
        if self.thread:
            self.thread.join(timeout=10)
            if self.thread.is_alive():self.frames.cancel();raise OSError('CAPTURE_WORKER_STUCK')
    def stop(self):
        self.cancel()
        if self.error:self.frames.cancel();raise OSError('CAPTURE_WORKER_FAILED:'+str(self.error))
        data=self.frames.finish();return {'duration':float(data['format']['duration']),'expected':time.monotonic()-self.started,'path':str(self.out),'backend':'captured_frames'}
    def clip(self,dst,at,before=4,after=6):
        # Reuse the existing bounded clip implementation.
        proxy=Recorder(self.frames.ffmpeg,self.frames.ffprobe,self.out);return proxy.clip(dst,at,before,after)

def threaded_desktop_recorder(ffmpeg,ffprobe,out):
    from windows import Desktop,U
    d=Desktop();d.hwnd=U.GetDesktopWindow()
    return CapturedFrameRecorder(ffmpeg,ffprobe,out,d.capture)
