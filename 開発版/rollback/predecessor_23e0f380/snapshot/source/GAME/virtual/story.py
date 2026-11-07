from display import Game,serve
class Story(Game):
    name='CROSSROADS STORY'
    def __init__(self,a):super().__init__(a);self.s.update(dialogue=0,branch='');self.buttons=[('north',(35,170,170,60)),('south',(260,170,170,60))]
    def on_key(self,n):
        if n==0xff0d:self.s['dialogue']+=1
        if n==ord('1'):self.on_click('north')
        if n==ord('2'):self.on_click('south')
        self.s['goal']=self.s['dialogue']>=3 and bool(self.s['branch'])
    def on_click(self,name):self.s['branch']=name;self.s['scene']='branch_'+name
    def draw(self,c):
        super().draw(c);c.text(20,100,'CHOOSE YOUR ROAD',scale=3)
        for (name,(x,y,w,h)),color in zip(self.buttons,[(40,150,110),(140,70,180)]):c.rect(x,y,w,h,color);c.text(x+12,y+22,name,scale=3)
        c.text(20,260,'ENTER ADVANCES DIALOGUE',scale=2)
if __name__=='__main__':serve(Story)
