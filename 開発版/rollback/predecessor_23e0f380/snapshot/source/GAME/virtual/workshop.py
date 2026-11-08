from display import Game,serve
class Workshop(Game):
    name='WORKSHOP MARKET'
    def __init__(self,a):
        super().__init__(a);self.s.update(money=100,factories=0,stock=0,sold=0);self.buttons=[('build',(20,120,130,60)),('turn',(175,120,130,60)),('sell',(330,120,130,60))]
    def on_click(self,name):
        if name=='build' and self.s['money']>=20:self.s['money']-=20;self.s['factories']+=1
        if name=='turn':self.s['turn']+=1;self.s['stock']+=self.s['factories']
        if name=='sell':self.s['sold']+=self.s['stock'];self.s['money']+=self.s['stock']*10;self.s['stock']=0
        self.s['goal']=self.s['sold']>=4 and self.s['turn']>=2;self.s['score']=self.s['sold']
    def on_key(self,n):
        if n==0xff0d:self.on_click('turn')
    def draw(self,c):
        super().draw(c)
        for (name,(x,y,w,h)),color in zip(self.buttons,[(30,170,60),(30,90,200),(200,100,20)]):c.rect(x,y,w,h,color);c.text(x+10,y+20,name,scale=3)
        c.text(15,205,'MONEY '+str(self.s['money']),scale=3);c.text(15,235,'STOCK '+str(self.s['stock'])+' SOLD '+str(self.s['sold']),scale=3)
if __name__=='__main__':serve(Workshop)
