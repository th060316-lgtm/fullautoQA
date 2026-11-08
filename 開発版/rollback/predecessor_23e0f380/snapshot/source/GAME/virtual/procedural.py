from display import Game,serve
import random
class Dice(Game):
    name='SEEDED EXPEDITION'
    def __init__(self,a):super().__init__(a);self.rng=random.Random(a.seed);self.s.update(seed=a.seed,event=0)
    def on_key(self,n):
        if n==0xff0d:
            self.s['event']=self.rng.randint(1,6);self.s['score']+=self.s['event'];self.s['turn']+=1;self.s['goal']=self.s['turn']>=5
    def draw(self,c):
        super().draw(c);c.text(20,110,'ENTER ROLLS THE DICE',scale=3);c.text(80,180,'ROLL '+str(self.s['event']),scale=5)
if __name__=='__main__':serve(Dice)
