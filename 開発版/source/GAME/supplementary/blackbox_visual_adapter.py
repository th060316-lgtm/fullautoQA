"""External screenshot measurements only; no game bridge or semantic inference."""
import json
import struct
import subprocess
import time
from pathlib import Path


def crop_pixels(path,region):
    data=Path(path).read_bytes()
    if data[:2]!=b'BM':raise ValueError('BMP_REQUIRED')
    offset=struct.unpack_from('<I',data,10)[0];w,h=struct.unpack_from('<ii',data,18)
    if struct.unpack_from('<H',data,28)[0]!=24 or w<=0 or h==0:raise ValueError('BMP_FORMAT')
    x0,y0,x1,y1=region
    if not 0<=x0<x1<=1 or not 0<=y0<y1<=1:raise ValueError('CROP_REGION')
    stride=((w*3+3)//4)*4;out=bytearray()
    for y in range(int(y0*abs(h)),int(y1*abs(h))):
        sy=abs(h)-1-y if h>0 else y
        out.extend(data[offset+sy*stride+int(x0*w)*3:offset+sy*stride+int(x1*w)*3])
    if not out:raise ValueError('EMPTY_CROP')
    return bytes(out)


class VisualAdapter:
    def __init__(self,profile,context):
        self.p=profile;self.d=context['desktop'];self.e=context['evidence']
        self.records=[];self.changes=0;self.counter=0
        self.ocr_executable=context['tools'].paths.get(profile.get('blackbox',{}).get('ocr_tool_id',''))
    def capabilities(self):
        return {'internal_state':False,'ocr':bool(self.ocr_executable),'image_recognition':False,
            'window_automation':True,'save':False,'replay':True,'audio':False,'gamepad':False,'adapter':True}
    def capture(self,tag):
        self.counter+=1;name='blackbox_%05d_%s.bmp'%(self.counter,tag)
        self.d.capture(self.e.root/name);self.e.event('screenshot',file=name,event='external_observation');return name
    def observe(self):
        ocr=None;status='NOT_RUN'
        if self.ocr_executable:
            name=self.capture('ocr');result=subprocess.run([str(self.ocr_executable),str(self.e.root/name),'stdout'],capture_output=True,text=True,timeout=15)
            status='PASS' if result.returncode==0 else 'HARNESS_ERROR'
            ocr={'status':status,'text':result.stdout,'stderr':result.stderr,'source':name,'method':'explicit_tesseract_executable'}
        return {'internal_state':{'external_visual_response_count':self.changes},'numeric_state':{},
            'scene':None,'window':self.d.state(),'ocr':ocr,
            'observation_status':{'internal_state':'NOT_CONFIGURED','ocr':status,
                'condition_value_origin':'external screenshot crop measurements'},
            'external_visual_measurements':self.records}
    def act(self,name):
        cfg=self.p['blackbox'];before=self.capture(name+'_before');self.d.focus()
        for item in self.p['actions'][name].get('inputs',[]):self.d.perform(item)
        time.sleep(cfg['response_wait_seconds']);after=self.capture(name+'_after')
        a=crop_pixels(self.e.root/before,cfg['response_region']);b=crop_pixels(self.e.root/after,cfg['response_region'])
        distance=sum(abs(x-y) for x,y in zip(a,b))/(255*len(a)) if len(a)==len(b) else None
        changed=distance is not None and distance>=cfg['minimum_pixel_distance']
        if changed:self.changes+=1
        row={'action':name,'before':before,'after':after,'normalized_pixel_distance':distance,
            'region':cfg['response_region'],'threshold':cfg['minimum_pixel_distance'],
            'visible_change':changed,'semantic_game_outcome':'UNVERIFIED','ocr_used_for_change':False}
        self.records.append(row);proof='blackbox_response_%05d.json'%self.counter
        (self.e.root/proof).write_text(json.dumps(row,indent=2),encoding='utf-8');self.e.event('external_visual_response',file=proof,**row)
    def close(self):pass


def create(profile,context):return VisualAdapter(profile,context)
