from collections import Counter,deque
import random, json, time
class Agent:
    def __init__(self,profile,scenario,seed):
        self.profile=profile; self.scenario=scenario; self.mode=scenario['agent']; self.seed=seed; self.rng=random.Random(seed)
        self.total_actions=0;self.history=[]; self.visited=Counter(); self.failed=Counter(); self.success=Counter(); self.retry_count=0; self.started=time.monotonic(); self.current_goal=scenario.get('goal'); self.memory={}; self.loops=0
    def signature(self,state):
        # Adapter/profile decides which changing values represent progress; wall clocks are excluded.
        fields=self.profile.get('state_signature',['scene','position','money','turn','branch','score'])
        return json.dumps({f:state.get(f) for f in fields},sort_keys=True)
    def choose(self,state):
        sig=self.signature(state); self.visited[sig]+=1
        allowed=[x for x in self.profile['actions'] if x not in self.profile.get('forbidden_actions',[]) and x not in ('save','load')]
        random_allowed=[x for x in self.profile.get('allowed_random_actions',allowed) if x in allowed]
        if not allowed:raise ValueError('NO_ALLOWED_ACTIONS')
        if len(self.history)>=8 and len(set(self.history[-8:]))<=2 and self.visited[sig]>=3:
            self.mode='Explorer'; self.loops+=1; self.retry_count+=1
        sequence=self.scenario.get('sequence',[])
        if self.mode=='Smoke' and len(self.history)<len(sequence):a=sequence[len(self.history)]
        elif self.mode=='Goal':
            policies=self.scenario.get('policy',[])
            from profile import condition
            a=next((x['action'] for x in policies if condition(state,x['when'])),None)
            if a is None and sequence and len(self.history)<len(sequence):a=sequence[len(self.history)]
            if a is None or self.visited[sig]>4:self.mode='Explorer';a=None
            if a is None:a=min(allowed,key=lambda x:self.failed[(sig,x)]+self.history.count(x))
        elif self.mode=='Random':a=self.rng.choice(random_allowed or allowed)
        elif self.mode=='Explorer':
            a=min(allowed,key=lambda x:(self.memory.get((sig,x),0),self.failed[(sig,x)],self.history.count(x),x))
        else:a=self.rng.choice(random_allowed or allowed)
        self.total_actions+=1
        self.memory[(sig,a)]=self.memory.get((sig,a),0)+1; self.history.append(a)
        if self.scenario.get('soak'):
            limit=self.scenario.get('memory_limit',1024)
            if len(self.history)>limit:del self.history[:-limit]
            for cache in (self.memory,self.visited,self.failed,self.success):
                while len(cache)>limit:del cache[next(iter(cache))]
        return a
    def feedback(self,before,after,action):
        key=(self.signature(before),action)
        (self.success if self.signature(before)!=self.signature(after) else self.failed)[key]+=1
    def exhausted(self):return (self.total_actions if self.scenario.get('soak') else len(self.history))>=self.scenario.get('action_budget',100) or time.monotonic()-self.started>=self.scenario.get('time_budget',60)
    def export(self):return {'total_actions':self.total_actions,'history_truncated':self.total_actions>len(self.history),'seed':self.seed,'mode':self.mode,'current_goal':self.current_goal,'action_history':self.history,'visited_state':dict(self.visited),'failed_action':{str(k):v for k,v in self.failed.items()},'success_action':{str(k):v for k,v in self.success.items()},'retry_count':self.retry_count,'loops':self.loops}

class StallDetector:
    def __init__(self,seconds=10):self.seconds=seconds;self.samples=deque(maxlen=200)
    def observe(self,now,state_sig,screen_sig,action,waiting=False,reaction=None):
        self.samples.append((now,state_sig,screen_sig,action,reaction))
        recent=[x for x in self.samples if now-x[0]<=self.seconds]
        if waiting or len(recent)<4 or recent[-1][0]-recent[0][0]<self.seconds*.9:return None
        state_static=len({x[1] for x in recent})==1
        screen_static=all(x[2] is not None for x in recent) and len({x[2] for x in recent})==1
        attempts=len({x[3] for x in recent if x[3]})>=2
        reaction_available=all(x[4] is not None for x in recent)
        no_reaction=reaction_available and len({x[4] for x in recent})==1
        if state_static and attempts and (no_reaction if reaction_available else screen_static):return 'SOFTLOCK'
        return None
