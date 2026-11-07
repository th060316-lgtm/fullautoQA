"""Wall-clock input timestamps, VFR video, bounded memory, no raw-frame accumulation."""
import json,subprocess,time,threading
from pathlib import Path
from common import write_json
class PipeFrameRecorder:
    def __init__(self,ffmpeg,ffprobe,out):
        self.ffmpeg=ffmpeg;self.ffprobe=ffprobe;self.out=Path(out);self.start=time.monotonic();self.lock=threading.RLock();self.p=None;self.log=None;self.count=0;self.first=None;self.last=None;self.maximum_gap=0
    def frame(self,path):
        with self.lock:
            now=time.monotonic()-self.start
            if self.last is not None and now-self.last<.3:return
            if self.p is None:
                self.out.parent.mkdir(parents=True,exist_ok=True);self.log=self.out.with_suffix('.encoder.log').open('wb');self.p=subprocess.Popen([self.ffmpeg,'-y','-hide_banner','-loglevel','error','-use_wallclock_as_timestamps','1','-f','image2pipe','-vcodec','bmp','-i','pipe:0','-fps_mode','vfr','-c:v','libx264','-preset','ultrafast','-crf','28','-pix_fmt','yuv420p',str(self.out)],stdin=subprocess.PIPE,stdout=self.log,stderr=self.log)
            if self.p.poll() is not None:raise OSError('VIDEO_ENCODER_EXITED')
            self.p.stdin.write(Path(path).read_bytes());self.p.stdin.flush()
            if self.first is None:self.first=now
            if self.last is not None:self.maximum_gap=max(self.maximum_gap,now-self.last)
            self.last=now;self.count+=1
    def finish(self):
        with self.lock:
            if not self.p or self.count<2:self.cancel();raise OSError('VIDEO_INSUFFICIENT_FRAMES')
            self.p.stdin.close()
            try:self.p.wait(timeout=30)
            except subprocess.TimeoutExpired:self.p.kill();self.p.wait();raise OSError('VIDEO_ENCODER_TIMEOUT')
            finally:
                if self.log:self.log.close()
            if self.p.returncode:raise OSError('VIDEO_ENCODER_FAILED')
            probe=subprocess.run([self.ffprobe,'-v','error','-show_format','-show_streams','-of','json',str(self.out)],capture_output=True,timeout=20);self.out.with_suffix('.probe.json').write_bytes(probe.stdout);data=json.loads(probe.stdout);duration=float(data.get('format',{}).get('duration',0));span=self.last-self.first
            if probe.returncode or not any(x['codec_type']=='video' for x in data.get('streams',[])) or duration<span*.85:raise OSError('VIDEO_TIMING_INVALID')
            write_json(self.out.with_suffix('.timeline.json'),{'frames':self.count,'duration':duration,'observed_span':span,'maximum_interframe_gap':self.maximum_gap,'capture_model':'actual captured BMP frames, wall-clock timestamps, VFR','raw_frames_retained':0});return data
    def cancel(self):
        if self.p and self.p.poll() is None:self.p.kill();self.p.wait(timeout=10)
        if self.log:self.log.close()
