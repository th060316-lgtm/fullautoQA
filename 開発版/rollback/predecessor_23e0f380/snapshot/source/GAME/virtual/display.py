"""Real software-rendered game display exported over standard RFB 3.8.
A VNC viewer can control this display. No direct state-mutation command exists.
"""
import socket,struct,time,json,argparse,os,select
from pathlib import Path
FONT={'A':['010','101','111','101','101'],'B':['110','101','110','101','110'],'C':['011','100','100','100','011'],'D':['110','101','101','101','110'],'E':['111','100','110','100','111'],'F':['111','100','110','100','100'],'G':['011','100','101','101','011'],'H':['101','101','111','101','101'],'I':['111','010','010','010','111'],'J':['001','001','001','101','010'],'K':['101','101','110','101','101'],'L':['100','100','100','100','111'],'M':['101','111','111','101','101'],'N':['101','111','111','111','101'],'O':['010','101','101','101','010'],'P':['110','101','110','100','100'],'Q':['010','101','101','111','011'],'R':['110','101','110','101','101'],'S':['011','100','010','001','110'],'T':['111','010','010','010','010'],'U':['101','101','101','101','111'],'V':['101','101','101','101','010'],'W':['101','101','111','111','101'],'X':['101','101','010','101','101'],'Y':['101','101','010','010','010'],'Z':['111','001','010','100','111'],'0':['111','101','101','101','111'],'1':['010','110','010','010','111'],'2':['110','001','010','100','111'],'3':['110','001','010','001','110'],'4':['101','101','111','001','001'],'5':['111','100','110','001','110'],'6':['011','100','111','101','111'],'7':['111','001','010','010','010'],'8':['111','101','111','101','111'],'9':['111','101','111','001','110'],' ':['000']*5,'-':['000','000','111','000','000'],':':['000','010','000','010','000']}
class Canvas:
    def __init__(self,w=480,h=300):self.w=w;self.h=h;self.buf=bytearray(w*h*4)
    def rect(self,x,y,w,h,color):
        x,y,w,h=map(int,(x,y,w,h));x=max(0,x);y=max(0,y);w=min(self.w-x,w);h=min(self.h-y,h)
        if w<=0 or h<=0:return
        row=bytes((color[2],color[1],color[0],0))*w
        for yy in range(y,y+h):self.buf[(yy*self.w+x)*4:(yy*self.w+x+w)*4]=row
    def text(self,x,y,text,color=(240,240,240),scale=3):
        for i,ch in enumerate(str(text).upper()):
            for yy,row in enumerate(FONT.get(ch,FONT[' '])):
                for xx,v in enumerate(row):
                    if v=='1':self.rect(x+i*4*scale+xx*scale,y+yy*scale,scale,scale,color)
class Game:
    name='Fixture';kind='generic'
    def __init__(self,args):self.args=args;self.s={'reaction':0,'goal':False,'scene':'play','turn':0,'score':0};self.held=set();self.save_path=Path(args.save);self.buttons=[]
    def publish(self):
        if self.args.fault=='behavior':self.s['score']=999
        p=Path(self.args.state);tmp=p.with_suffix('.tmp');tmp.write_text(json.dumps(self.s),encoding='utf-8');os.replace(tmp,p)
    def key(self,n,down):
        if not down:self.held.discard(n);return
        self.held.add(n)
        if self.args.fault=='crash' and n==ord('q'):os._exit(17)
        if self.args.fault in ('stall','loop'):return
        self.s['reaction']+=1
        if n==0xffc2:
            if self.args.fault=='save':self.s['save_failed']=True;return
            self.save_path.write_text(json.dumps(self.s));self.s['saved']=True;return
        if n==0xffc6:
            try:
                d=json.loads(self.save_path.read_text());self.s=d;self.s['loaded']=True
            except (OSError,ValueError):self.s['load_error']=True
            return
        self.on_key(n)
    def pointer(self,x,y,mask):
        if mask&1 and self.args.fault not in ('stall','loop'):
            self.s['reaction']+=1
            for name,b in self.buttons:
                xx,yy,w,h=b
                if xx<=x<xx+w and yy<=y<yy+h:self.on_click(name)
    def on_key(self,n):pass
    def on_click(self,name):pass
    def tick(self,dt):pass
    def draw(self,c):
        bg=(130,25,25) if self.args.fault=='visual' else (15,25,45);c.rect(0,0,c.w,c.h,bg);c.text(15,12,self.name);c.text(15,40,'SCORE '+str(self.s['score'])+' TURN '+str(self.s['turn']),scale=2);c.text(15,65,'GOAL '+str(int(self.s['goal'])),scale=2)
def exact(s,n):
    b=b''
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x:raise EOFError()
        b+=x
    return b
def serve(game_type):
    ap=argparse.ArgumentParser();ap.add_argument('--endpoint',required=True);ap.add_argument('--state',required=True);ap.add_argument('--seed',type=int,default=12345);ap.add_argument('--fault',default='');ap.add_argument('--save',default='save.json');a=ap.parse_args();g=game_type(a);c=Canvas();server=socket.socket();server.bind(('127.0.0.1',0));server.listen(1)
    if a.fault=='slow_start':time.sleep(1.2)
    Path(a.endpoint).parent.mkdir(parents=True,exist_ok=True);Path(a.state).parent.mkdir(parents=True,exist_ok=True);Path(a.save).parent.mkdir(parents=True,exist_ok=True);Path(a.endpoint).write_text(json.dumps({'host':'127.0.0.1','port':server.getsockname()[1],'protocol':'RFB 3.8','width':c.w,'height':c.h}));g.publish()
    s,_=server.accept();s.settimeout(5);s.sendall(b'RFB 003.008\n');assert exact(s,12)==b'RFB 003.008\n';s.sendall(b'\1\1');assert exact(s,1)==b'\1';s.sendall(b'\0'*4);exact(s,1)
    name=g.name.encode();pf=struct.pack('!BBBBHHHBBBxxx',32,24,0,1,255,255,255,16,8,0);s.sendall(struct.pack('!HH',c.w,c.h)+pf+struct.pack('!I',len(name))+name);last=time.monotonic()
    try:
        while True:
            now=time.monotonic();g.tick(min(.1,now-last));last=now;g.publish()
            if not select.select([s],[],[],.01)[0]:continue
            typ=exact(s,1)[0]
            if typ==2:
                h=exact(s,3);n=struct.unpack('!H',h[1:])[0];exact(s,n*4)
            elif typ==3:
                exact(s,9);g.draw(c);s.sendall(b'\0\0\0\1'+struct.pack('!HHHHi',0,0,c.w,c.h,0)+c.buf)
            elif typ==4:
                b=exact(s,7);down=b[0];n=struct.unpack('!I',b[3:])[0];g.key(n,bool(down))
            elif typ==5:
                b=exact(s,5);mask,x,y=struct.unpack('!BHH',b);g.pointer(x,y,mask)
            elif typ==6:
                b=exact(s,7);exact(s,struct.unpack('!I',b[3:])[0])
            else:raise ValueError('UNSUPPORTED_RFB_CLIENT_MESSAGE:'+str(typ))
    except (EOFError,ConnectionError,BrokenPipeError):pass
    finally:s.close();server.close()
