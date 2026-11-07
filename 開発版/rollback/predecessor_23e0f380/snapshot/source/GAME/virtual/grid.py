from display import Game,serve
class Grid(Game):
    name='GRID RESCUE'
    def __init__(self,a):super().__init__(a);self.s.update(x=0,y=0)
    def on_key(self,n):
        if n==0xff53:self.s['x']=min(4,self.s['x']+1)
        if n==0xff51:self.s['x']=max(0,self.s['x']-1)
        if n==0xff54:self.s['y']=min(3,self.s['y']+1)
        if n==0xff52:self.s['y']=max(0,self.s['y']-1)
        if n==0xff0d:self.s['turn']+=1
        self.s['goal']=self.s['x']==3 and self.s['y']==2 and self.s['turn']>=1
    def draw(self,c):
        super().draw(c)
        for x in range(5):
            for y in range(4):c.rect(20+x*48,110+y*40,45,37,(55,70,95))
        c.rect(20+3*48,110+2*40,45,37,(30,180,70));c.rect(30+self.s['x']*48,118+self.s['y']*40,25,22,(240,200,20));c.text(280,140,'ARROWS',scale=3);c.text(280,165,'ENTER TURN',scale=2)
if __name__=='__main__':serve(Grid)
