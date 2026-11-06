import importlib.util,json,time,struct,math
from pathlib import Path
from common import inside,read_json,write_json
from ocr_backend import OculixOCR

class Adapter:
    """Default black-box/optional file bridge adapter; physical actions use the selected real display/input backend."""
    version='1.2'
    def __init__(self,profile,context):
        self.profile=profile;self.context=context;self.desktop=context['desktop'];self.previous=None;self._ocr=None
    def _ocr_requested(self):
        observations=self.profile.get('observations')
        if isinstance(observations,(list,tuple,set)):
            return any(str(x).lower()=='ocr' for x in observations)
        if isinstance(observations,dict):
            return bool(observations.get('ocr'))
        return bool(self.profile.get('ocr'))
    def _ocr_supported(self):
        return self._ocr_requested() and OculixOCR.supported(self.context.get('tools'),self.desktop)
    def _ocr_backend(self):
        if self._ocr is None:
            interval=float(self.profile.get('ocr_interval_seconds',5.0))
            if not math.isfinite(interval) or not 0<=interval<=60:raise ValueError('OCR_INTERVAL_INVALID')
            evidence=getattr(self.context.get('evidence'),'root',self.context.get('work'))
            self._ocr=OculixOCR(self.context.get('tools'),self.desktop,evidence,interval_seconds=interval)
        return self._ocr
    def capabilities(self):
        result={'internal_state':bool(self.profile.get('bridge')),'ocr':self._ocr_supported(),'image_recognition':False,'window_automation':True,'save':bool(self.profile.get('save')),'replay':True,'audio':False,'gamepad':False,'adapter':True}
        capabilities=getattr(self.desktop,'capabilities',None)
        if self.profile.get('display',{}).get('kind')=='browser' and callable(capabilities):
            result['browser']=capabilities()
        return result
    def observe(self):
        s={};status={'internal_state':'NOT_CONFIGURED'}
        if self.profile.get('bridge'):
            timeout=float(self.profile.get('observation_read_timeout',.2))
            if not math.isfinite(timeout) or not 0<timeout<=5:raise ValueError('OBSERVATION_READ_TIMEOUT_INVALID')
            deadline=time.monotonic()+timeout;attempts=0
            while True:
                attempts+=1
                try:
                    # Resolve inside the retry: Windows replacement can briefly
                    # make GetFinalPathNameByHandle expose a different alias.
                    path=inside(self.context['work'],self.profile['bridge'])
                    s=read_json(path)
                    if not isinstance(s,dict):raise ValueError('OBSERVATION_BRIDGE_NOT_OBJECT')
                    status={'internal_state':'FRESH_READ','attempts':attempts,'source':self.profile['bridge']}
                    break
                except (OSError,json.JSONDecodeError,ValueError) as ex:
                    if isinstance(ex,ValueError) and not isinstance(ex,json.JSONDecodeError) and not str(ex).startswith('PATH_ESCAPE:'):raise
                    if time.monotonic()>=deadline:
                        if isinstance(ex,ValueError) and str(ex).startswith('PATH_ESCAPE:'):raise
                        raise OSError('OBSERVATION_BRIDGE_UNAVAILABLE:'+self.profile['bridge']) from ex
                    time.sleep(min(.005,max(0,deadline-time.monotonic())))
        ocr=None;external=None
        if self._ocr_supported():
            try:
                ocr=self._ocr_backend().read()
            except Exception as ex:
                name='ocr_adapter_error_'+str(time.monotonic_ns())+'.json'
                evidence=getattr(self.context.get('evidence'),'root',self.context.get('work'))
                write_json(Path(evidence)/name,{'error':repr(ex)})
                ocr={'status':'HARNESS_ERROR','reason_code':'OCR_OBSERVATION_FAILED','text':'','evidence':[name],'method':'oculix_region_text','claim_scope':'visible_window_text_only'}
            if ocr.get('status')=='PASS':
                external={'values':{'ocr_text':ocr.get('text','')},'provenance':{'method':ocr.get('method'),'claim_scope':ocr.get('claim_scope'),'evidence':list(ocr.get('evidence') or [])}}
        return {'observation_status':status,'internal_state':s,'numeric_state':{k:v for k,v in s.items() if isinstance(v,(int,float))},'scene':s.get('scene'),'menu':s.get('menu'),'object':s.get('objects'),'grid':s.get('grid'),'position':s.get('position'),'timer':s.get('timer'),'ocr':ocr,'external_observations':external,'audio':None,'window':self.desktop.state()}
    def act(self,name):
        action=self.profile['actions'][name]
        self.desktop.focus()
        if action.get('target'):
            locator=getattr(self.desktop,'locate_color',None)
            if not locator:raise OSError('VISUAL_TARGET_CAPABILITY_UNAVAILABLE')
            target=locator(self.profile['visual_targets'][action['target']]['rgb'])
            if target is None:raise OSError('VISUAL_TARGET_NOT_FOUND')
            self.desktop.perform({'kind':'click','x':target[0],'y':target[1]})
        for item in action.get('inputs',[]):self.desktop.perform(item)
    def close(self):
        if self._ocr is not None:self._ocr.close()

def load_adapter(root,profile,context):
    if not profile.get('adapter'):return Adapter(profile,context)
    path=inside(root,profile['adapter'])
    if not path.is_relative_to((Path(root)/'GAME').resolve()):raise ValueError('ADAPTER_MUST_BE_GAME_SIDE')
    spec=importlib.util.spec_from_file_location('game_adapter_'+profile['game_id'],path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    a=m.create(profile,context)
    for method in ('capabilities','observe','act','close'):
        if not callable(getattr(a,method,None)):raise ValueError('ADAPTER_API:'+method)
    return a

def image_features(path):
    """48x32 RGB sampling of uncompressed 24-bit BMP, normalized to image dimensions."""
    data=Path(path).read_bytes()
    if data[:2]!=b'BM':raise ValueError('BMP_REQUIRED')
    offset=struct.unpack_from('<I',data,10)[0];w,h=struct.unpack_from('<ii',data,18);bits=struct.unpack_from('<H',data,28)[0]
    if bits!=24 or w<=0 or h==0:raise ValueError('BMP_FORMAT')
    stride=((w*3+3)//4)*4;out=[]
    for y in range(32):
        sy=min(abs(h)-1,int((y+.5)*abs(h)/32));sy=abs(h)-1-sy if h>0 else sy
        for x in range(48):
            sx=min(w-1,int((x+.5)*w/48));i=offset+sy*stride+sx*3;out.extend(data[i:i+3])
    return out

def image_distance(a,b):
    if len(a)!=len(b) or not a:raise ValueError('IMAGE_SHAPE')
    return sum(abs(x-y) for x,y in zip(a,b))/(255*len(a))

class Navigation:
    """Data-side planners: grid, axial hex, node/UI/menu graph; continuous vectors."""
    @staticmethod
    def route(graph,start,goal):
        from collections import deque
        q=deque([start]);parent={start:None}
        while q:
            n=q.popleft()
            if n==goal:
                result=[]
                while n is not None:result.append(n);n=parent[n]
                return list(reversed(result))
            for v in graph.get(n,[]):
                if v not in parent:parent[v]=n;q.append(v)
        return []
    @staticmethod
    def neighbors(cell,kind='grid'):
        x,y=cell;d=[(1,0),(-1,0),(0,1),(0,-1)]
        if kind=='hex':d += [(1,-1),(-1,1)]
        return [(x+a,y+b) for a,b in d]
    @staticmethod
    def direction(position,target):
        v=[b-a for a,b in zip(position,target)];norm=math.sqrt(sum(x*x for x in v));return [x/norm for x in v] if norm else v


