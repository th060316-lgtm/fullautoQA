"""Capability-selected real process, display/input and recording backends."""
import os,sys,socket,struct,subprocess,time,json,shutil,signal,threading
from pathlib import Path
from common import write_json
class ProcessSupervisor:
    def start(self,argv,cwd,stdout,stderr,env=None):
        self.p=subprocess.Popen(argv,cwd=cwd,stdout=stdout,stderr=stderr,env=env,start_new_session=os.name!='nt')
        self.job=None
        if os.name=='nt':
            from windows import Job
            self.job=Job();self.job.add(self.p)
        return self.p
    def metrics(self):
        if os.name=='nt':
            from windows import process_metrics
            return process_metrics(self.p.pid)
        base=self.proc_directory();m={'pid':self.p.pid,'exit_code':self.p.poll()}
        try:
            status=(base/'status').read_text();m['ram']=int(next(l.split()[1] for l in status.splitlines() if l.startswith('VmRSS:')))*1024
            fields=(base/'stat').read_text().split();m['cpu_seconds']=(int(fields[13])+int(fields[14]))/os.sysconf('SC_CLK_TCK');m['handles']=len(list((base/'fd').iterdir()))
        except (OSError,StopIteration):m['metrics_unavailable']=True
        return m
    def proc_directory(self):
        if getattr(self,'_proc_path',None) and self._proc_path.exists():return self._proc_path
        try:
            own=dict(line.split(':',1) for line in Path('/proc/self/status').read_text().splitlines());parent=int(own['Pid'])
            for candidate in Path('/proc').iterdir():
                if not candidate.name.isdigit():continue
                try:
                    info=dict(line.split(':',1) for line in (candidate/'status').read_text().splitlines());ids=[int(x) for x in info.get('NSpid',info['Pid']).split()]
                    if ids[-1]==self.p.pid and int(info['PPid'])==parent:self._proc_path=candidate;return candidate
                except (OSError,ValueError,KeyError):continue
        except (OSError,ValueError,KeyError):pass
        return Path('/proc/__qa_unresolved_process__')
    def stop(self):
        if getattr(self,'job',None):self.job.close()
        if getattr(self,'p',None):
            if os.name!='nt':
                try:os.killpg(self.p.pid,signal.SIGTERM)
                except ProcessLookupError:pass
            elif self.p.poll() is None:self.p.terminate()
            try:self.p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                if os.name!='nt':os.killpg(self.p.pid,signal.SIGKILL)
                else:self.p.kill()
                self.p.wait(timeout=5)
class RFBDisplay:
    """Standard RFB 3.8 virtual-display client: real key/pointer events and raw pixels.
    Observation reads a separate optional bridge. Input never mutates bridge state.
    """
    def __init__(self,endpoint,timeout=10):
        self.lock=threading.RLock();meta=json.loads(Path(endpoint).read_text());self.s=socket.create_connection((meta['host'],meta['port']),timeout=timeout);self.s.settimeout(timeout);self.held=set()
        if self.exact(12)!=b'RFB 003.008\n':raise OSError('RFB_VERSION')
        self.s.sendall(b'RFB 003.008\n');n=self.exact(1)[0];kinds=self.exact(n)
        if 1 not in kinds:raise OSError('RFB_SECURITY_UNSUPPORTED')
        self.s.sendall(b'\1')
        if self.exact(4)!=b'\0\0\0\0':raise OSError('RFB_SECURITY_FAILED')
        self.s.sendall(b'\1');header=self.exact(24);self.width,self.height=struct.unpack_from('!HH',header);length=struct.unpack_from('!I',header,20)[0];self.title=self.exact(length).decode()
        self.s.sendall(struct.pack('!BBH',2,0,1)+struct.pack('!i',0));self.pixels=None
    def exact(self,n):
        b=bytearray()
        while len(b)<n:
            x=self.s.recv(n-len(b))
            if not x:raise OSError('RFB_DISPLAY_DISCONNECTED')
            b.extend(x)
        return bytes(b)
    def state(self):return {'exists':not self.s._closed,'focused':True,'backend':'RFB software display','native_window':False,'rect':[0,0,self.width,self.height],'title':self.title}
    def windows(self,pids):return []
    def focus(self):return {'verified':True,'method':'exclusive_virtual_display_connection','dpi':96,'monitor':'RFB virtual monitor','mode':'virtual_framebuffer','dimensions':[self.width,self.height]}
    def key(self,k,up=False):
        codes={'ENTER':0xff0d,'ESC':0xff1b,'SPACE':32,'TAB':0xff09,'LEFT':0xff51,'UP':0xff52,'RIGHT':0xff53,'DOWN':0xff54,'F5':0xffc2,'F9':0xffc6}
        n=codes.get(k.upper(),ord(k.lower()) if len(k)==1 else None)
        if n is None:raise ValueError('RFB_KEY:'+k)
        self.s.sendall(struct.pack('!BBHI',4,0 if up else 1,0,n))
        if up:self.held.discard(k)
        else:self.held.add(k)
    def point(self,x,y,mask=0):
        px=min(self.width-1,max(0,round(x*(self.width-1))));py=min(self.height-1,max(0,round(y*(self.height-1))))
        self.s.sendall(struct.pack('!BBHH',5,mask,px,py));return {'normalized':[x,y],'pixels':[px,py],'dimensions':[self.width,self.height]}
    def perform(self,i):
        with self.lock:return self._perform(i)
    def _perform(self,i):
        kind=i['kind']
        if kind in ('key','hold'):
            self.key(i['key'])
            try:time.sleep(i.get('duration',.04))
            finally:self.key(i['key'],True)
        elif kind in ('click','double_click'):
            for _ in range(2 if kind=='double_click' else 1):self.point(i['x'],i['y'],1);time.sleep(.02);self.point(i['x'],i['y'],0)
        elif kind=='move':self.point(i['x'],i['y'])
        elif kind=='wait':time.sleep(i.get('duration',.1))
        else:raise ValueError('RFB_INPUT_NOT_IMPLEMENTED:'+kind)
    def capture(self,path):
        with self.lock:return self._capture(path)
    def _capture(self,path):
        self.s.sendall(struct.pack('!BBHHHH',3,0,0,0,self.width,self.height));msg=self.exact(4)
        if msg[:1]!=b'\0':raise OSError('RFB_FRAME_FORMAT')
        count=struct.unpack('!H',msg[2:])[0]
        if count!=1:raise OSError('RFB_RECT_COUNT')
        x,y,w,h,enc=struct.unpack('!HHHHi',self.exact(12))
        if enc!=0 or (x,y,w,h)!=(0,0,self.width,self.height):raise OSError('RFB_RAW_FRAME_REQUIRED')
        pixels=self.exact(w*h*4);self.pixels=pixels
        # Received pixels are B,G,R,unused, little-endian RFB true colour.
        stride=(w*3+3)&~3;rows=[]
        for yy in range(h-1,-1,-1):
            row=pixels[yy*w*4:(yy+1)*w*4];rgb=bytearray(w*3)
            rgb[0::3]=row[0::4];rgb[1::3]=row[1::4];rgb[2::3]=row[2::4];rows.append(bytes(rgb)+b'\0'*(stride-w*3))
        data=b''.join(rows);Path(path).parent.mkdir(parents=True,exist_ok=True);Path(path).write_bytes(struct.pack('<2sIHHI',b'BM',54+len(data),0,0,54)+struct.pack('<IiiHHIIiiII',40,w,h,1,24,0,len(data),0,0,0,0)+data)
        return {'pixels':w*h,'dimensions':[w,h],'source':'RFB raw framebuffer','title':self.title}
    def locate_color(self,rgb):
        if self.pixels is None:raise OSError('CAPTURE_REQUIRED')
        b,g,r=rgb[2],rgb[1],rgb[0];pts=[]
        for yy in range(0,self.height,3):
            for xx in range(0,self.width,3):
                i=(yy*self.width+xx)*4
                if self.pixels[i:i+3]==bytes((b,g,r)):pts.append((xx,yy))
        if len(pts)<10:return None
        return (sum(x for x,y in pts)/len(pts)/self.width,sum(y for x,y in pts)/len(pts)/self.height)
    def release(self):
        for k in list(self.held):
            try:self.key(k,True)
            except OSError:pass
    def close(self):
        self.release();self.s.close()
class WindowDisplay:
    def __init__(self,pids):
        from windows import Desktop
        self.d=Desktop();self.d.find(pids)
    def focus(self):
        self.d.focus();time.sleep(.1);s=self.d.state()
        if not s.get('focused'):raise OSError('FOCUS_NOT_VERIFIED')
        return {'verified':True,'window':s,'method':'SendInput/BitBlt','dpi_awareness':'Windows system-aware; per-monitor qualification pending'}
    def perform(self,i):return self.d.perform(i)
    def capture(self,path):self.d.capture(path);return self.d.state()
    def release(self):self.d.release()
    def close(self):self.release()
def select_display(profile,work,process):
    kind=profile.get('display',{}).get('kind','windows')
    if kind=='rfb':return RFBDisplay(Path(work)/profile['display']['endpoint'])
    if kind=='windows' and os.name=='nt':
        from windows import child_pids
        return WindowDisplay(child_pids(process.pid))
    if kind=='browser':
        from browser_backend import select_browser_display
        return select_browser_display(profile,work,process)
    raise OSError('NO_SUPPORTED_DISPLAY_BACKEND')
def discover_tools(root=None):
    if os.name=='nt' and root:
        from common import read_json,inside,extract_zip,digest
        root=Path(root);manifest=read_json(root/'tool_manifest.json');entry=next(x for x in manifest if x['id']=='ffmpeg');dst=root/'RUNTIME/ffmpeg';paths=list(dst.rglob('ffmpeg.exe')) if dst.exists() else []
        if not paths:
            src=root/'PAYLOAD'/entry['file']
            if digest(src)!=entry['sha256']:raise OSError('FFMPEG_PAYLOAD_HASH')
            extract_zip(src,dst);paths=list(dst.rglob('ffmpeg.exe'))
        return {'python':sys.executable,'ffmpeg':str(paths[0]),'ffprobe':str(paths[0].with_name('ffprobe.exe')),'git':str(root/'RUNTIME/git/git.exe')}
    return {'python':sys.executable,'ffmpeg':shutil.which('ffmpeg'),'ffprobe':shutil.which('ffprobe'),'git':shutil.which('git'),'java':shutil.which('java'),'node':shutil.which('node'),'c':shutil.which('gcc')}
class FrameRecorder:
    """Record actual observed virtual-display frames with monotonic timing."""
    def __init__(self,ffmpeg,ffprobe,out):self.ffmpeg=ffmpeg;self.ffprobe=ffprobe;self.out=Path(out);self.frames=[];self.start=time.monotonic();self.next_frame=0;self.lock=threading.RLock()
    def frame(self,p):
        with self.lock:return self._frame(p)
    def _frame(self,p):
        n=len(self.frames);now=time.monotonic()-self.start
        if not self.frames or now-self.frames[-1][1]>=.3:
            dst=self.out.parent/'video_frames'/f'{n:06}.bmp';dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dst);self.frames.append((dst,now))
    def finish(self):
        if len(self.frames)<2:raise OSError('VIDEO_INSUFFICIENT_FRAMES')
        seq=self.out.with_suffix('.ffconcat');lines=['ffconcat version 1.0']
        for i,(p,t) in enumerate(self.frames):
            lines += ["file '"+str(p.resolve()).replace("'","'\\''")+"'",'duration '+str(max(.02,(self.frames[i+1][1] if i+1<len(self.frames) else time.monotonic()-self.start)-t))]
        lines += ["file '"+str(self.frames[-1][0].resolve())+"'"];seq.write_text('\n'.join(lines)+'\n')
        cmd=[self.ffmpeg,'-y','-v','error','-safe','0','-f','concat','-i',str(seq),'-vsync','vfr','-c:v','libx264','-preset','ultrafast','-crf','28','-pix_fmt','yuv420p',str(self.out)]
        r=subprocess.run(cmd,capture_output=True,timeout=120);self.out.with_suffix('.encoder.log').write_bytes(r.stdout+r.stderr)
        if r.returncode:raise OSError('VIDEO_ENCODE_FAILED')
        probe=subprocess.run([self.ffprobe,'-v','error','-show_format','-show_streams','-of','json',str(self.out)],capture_output=True,timeout=30);self.out.with_suffix('.probe.json').write_bytes(probe.stdout)
        data=json.loads(probe.stdout);duration=float(data.get('format',{}).get('duration',0));expected=self.frames[-1][1]-self.frames[0][1]
        if probe.returncode or not any(s['codec_type']=='video' for s in data.get('streams',[])) or duration<expected*.9:raise OSError('VIDEO_VALIDATION_FAILED')
        write_json(self.out.with_suffix('.timeline.json'),{'frames':len(self.frames),'duration':duration,'observed_span':expected,'capture_model':'actual RFB framebuffer sampled during gameplay; VFR recording','maximum_interframe_gap':max(b[1]-a[1] for a,b in zip(self.frames,self.frames[1:]))})
        shutil.rmtree(self.out.parent/'video_frames');return data

class DisplaySampler:
    """Independent timed observation while the active GUI runs, including waits."""
    def __init__(self,display,recorder,path,interval=.35):
        self.display=display;self.recorder=recorder;self.path=Path(path);self.interval=interval;self.event=threading.Event();self.error=None;self.count=0;self.times=[]
    def start(self):
        def loop():
            try:
                while not self.event.wait(self.interval):
                    self.display.capture(self.path);self.recorder.frame(self.path);self.count+=1;self.times.append(time.monotonic())
            except Exception as ex:self.error=repr(ex)
        self.thread=threading.Thread(target=loop,daemon=True);self.thread.start()
    def stop(self):
        self.event.set();self.thread.join(timeout=12)
        if self.thread.is_alive():raise OSError('RECORDING_CAPTURE_WORKER_STUCK')
        return {'samples':self.count,'interval':self.interval,'times_monotonic':self.times,'error':self.error,'source':'actual active GUI framebuffer, independent of agent actions'}
