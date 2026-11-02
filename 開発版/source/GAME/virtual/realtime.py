from display import Game,serve
class Runner(Game):
    name='REALTIME RUNNER'
    def __init__(self,a):super().__init__(a);self.s.update(x=10.0,failed=False,retry=0)
    def tick(self,dt):
        if self.args.fault in ('stall','loop') or self.s['failed']:return
        if ord('d') in self.held:self.s['x']=min(430,self.s['x']+dt*200)
        if ord('a') in self.held:self.s['x']=max(10,self.s['x']-dt*200)
        self.s['goal']=self.s['x']>=350
    def on_key(self,n):
        if n==ord('f'):self.s['failed']=True;self.s['scene']='failure'
        if n==ord('r'):self.s['failed']=False;self.s['retry']+=1;self.s['scene']='play'
        if n==0xff0d:self.s['score']+=1
    def draw(self,c):
        super().draw(c);c.rect(0,225,480,30,(60,70,80));c.rect(350,100,15,125,(30,180,70));c.rect(self.s['x'],180,20,40,(230,180,40));c.text(20,100,'HOLD D TO REACH FLAG',scale=2);c.text(20,270,'F FAILURE  R RETRY',scale=2)
if __name__=='__main__':serve(Runner)
