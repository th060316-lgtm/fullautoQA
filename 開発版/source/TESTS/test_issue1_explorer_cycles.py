"""Adversarial observation histories; synthetic, not browser acceptance evidence."""
import os,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(os.environ.get('FULLAUTOQA_TEST_SOURCE',Path(__file__).resolve().parents[1]))/'CORE'))
from agents import Agent
class ExplorerCycleTests(unittest.TestCase):
    def trace(self,seed):
        agent=Agent({'state_signature':['position'],'actions':{'advance':{},'back':{}}},{'agent':'Explorer','action_budget':32,'time_budget':999},seed)
        position=0;screen='initial-zero';trace=[]
        while not agent.exhausted() and position<4:
            before={'position':position};action=agent.choose(before,screen=screen);position=min(4,position+1) if action=='advance' else max(0,position-1);after_screen='screen-'+str(position)
            agent.feedback(before,{'position':position},action,screen_before=screen,screen_after=after_screen);trace.append((before['position'],action,position));screen=after_screen
        return position,trace,agent
    def test_successful_two_state_edges_cannot_starve_unknown_exit(self):
        position,trace,agent=self.trace(8);self.assertEqual(position,4,trace);self.assertEqual(agent.mode,'Explorer');self.assertLessEqual(len(trace),32)
    def test_identical_seed_and_observation_are_reproducible(self):self.assertEqual(self.trace(8)[:2],self.trace(8)[:2])
    def test_three_state_success_cycle_explores_unknown_exit(self):
        agent=Agent({'state_signature':['x'],'actions':{'cycle':{},'exit':{}}},{'agent':'Explorer','action_budget':32,'time_budget':999},3)
        for x in range(3):agent.obs_success[('s'+str(x),'cycle')]=4
        position=0
        while not agent.exhausted() and position!=3:
            before={'x':position};screen='s'+str(position);action=agent.choose(before,screen=screen)
            position=(position+1)%3 if action=='cycle' else 3 if position==2 else position
            agent.feedback(before,{'x':position},action,screen_before=screen,screen_after='s'+str(position))
        self.assertEqual(position,3);self.assertEqual(agent.mode,'Explorer')
    def test_observation_visit_and_attempt_memory_remains_bounded(self):
        agent=Agent({'actions':{'a':{},'b':{}}},{'agent':'Explorer','memory_limit':3,'action_budget':200,'time_budget':999},1)
        for n in range(100):agent.choose({},screen='screen'+str(n))
        self.assertLessEqual(len(agent.obs_visits),3);self.assertLessEqual(len(agent.obs_attempts),3);self.assertEqual(agent.total_actions,100)
if __name__=='__main__':unittest.main()
