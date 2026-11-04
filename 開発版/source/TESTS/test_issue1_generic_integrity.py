import hashlib,json,sys,tempfile,unittest,zipfile,os
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock
sys.path.insert(0,str(Path(os.environ.get('FULLAUTOQA_TEST_SOURCE',Path(__file__).resolve().parents[1]))/'CORE'))
from agents import Agent
from common import Evidence
from tools import Tools
from target_identity import TargetIdentity,check_result_binding

class GenericIntegrityTests(unittest.TestCase):
    def test_boolean_generation_cannot_impersonate_one(self):
        identity=TargetIdentity('T','target','f'*64,generation=1);recorded=identity.to_dict();recorded['generation']=True
        self.assertTrue(check_result_binding(identity,recorded))
    def test_random_lucky_goal_does_not_certify_goal_agent(self):
        agent=Agent({'actions':{'win':{}},'state_signature':['won']},{'agent':'Random','goal':'win'},7)
        action=agent.choose({'won':False});self.assertEqual(action,'win');agent.feedback({'won':False},{'won':True},action)
        result=agent.goal_assessment(True);self.assertNotEqual(result['status'],'PASS');self.assertTrue(result['goal_reached'])
    def test_deliberate_goal_policy_and_initial_goal_are_distinct(self):
        agent=Agent({'actions':{'win':{}},'state_signature':['won']},{'agent':'Goal','goal':'win','sequence':['win']},1)
        self.assertNotEqual(agent.goal_assessment(True)['status'],'PASS');agent.choose({'won':False});self.assertEqual(agent.goal_assessment(True)['status'],'PASS')
    def test_goal_then_explorer_or_random_terminal_action_never_certifies_goal_policy(self):
        for fallback in ('Explorer','Random'):
            agent=Agent({'actions':{'try':{},'win':{}},'state_signature':['won']},{'agent':'Goal','goal':'win','sequence':['try']},1)
            agent.choose({'won':False});self.assertEqual(agent.action_modes,['Goal']);agent.mode=fallback;agent.choose({'won':False})
            result=agent.goal_assessment(True);self.assertNotEqual(result['status'],'PASS');self.assertEqual(result['last_action_agent'],fallback)
    def test_goal_label_falling_back_before_first_action_is_not_goal_capability(self):
        from windows_runner import Session
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);e=Evidence(root/'E','run');state={'won':False}
            profile={'game_id':'g','bridge':'bridge.json','actions':{'win':{}},'goals':[{'id':'win','field':'won','op':'eq','value':True}],'state_signature':['won']}
            scenario={'id':'lucky','agent':'Goal','goal':'win','action_budget':2,'observation_delay':0}
            adapter=Mock();adapter.capabilities.return_value={};adapter.observe.side_effect=lambda:{'internal_state':dict(state),'window':{'focused':True,'exists':True}};adapter.act.side_effect=lambda _:state.update(won=True)
            process=SimpleNamespace(pid=123,poll=lambda:None);session=Session(root,e,None,profile);session.desktop=Mock();session.required_cases=['g.lucky.goal_agent']
            session.copy_game=Mock(return_value=root);session.start=Mock(return_value=(process,adapter));session.shot=Mock(return_value=(None,None));session.disk_guard=Mock();session.monitor=Mock();session.stop=Mock();session.checkpoint=Mock();session.behavioral_regression=Mock();(e.root/'g.lucky_stderr.log').write_text('')
            exported,_=session.run_scenario(scenario,7)
            self.assertEqual(next(r for r in session.results if r['test_case']=='g.lucky.goal')['status'],'PASS')
            self.assertNotIn('Goal',session.coverage['agents']);self.assertNotEqual(next(r for r in session.results if r['test_case']=='g.lucky.goal_agent')['status'],'PASS');self.assertEqual(next(r for r in session.results if r['test_case']=='g.lucky.goal_agent')['gate'],'REQUIRED');self.assertEqual(exported['actions_by_mode'],{'Explorer':1})
    def prepare(self,root,marker=None,replaced=False,symlink=False):
        (root/'PAYLOAD').mkdir();runtime=root/'RUNTIME/node';runtime.mkdir(parents=True);payload=root/'PAYLOAD/node.zip'
        with zipfile.ZipFile(payload,'w') as z:z.writestr('node.exe',b'correct')
        checksum=hashlib.sha256(payload.read_bytes()).hexdigest()
        if symlink:
            outside=root/'foreign.exe';outside.write_bytes(b'foreign');(runtime/'node.exe').symlink_to(outside)
        elif replaced:(runtime/'node.exe').write_bytes(b'changed')
        if marker is not None:(runtime/'extracted.json').write_text(json.dumps({'sha256':checksum if marker=='current' else '0'*64}))
        (root/'tool_manifest.json').write_text(json.dumps([{'id':'node','file':'node.zip','size':payload.stat().st_size,'sha256':checksum,'executable':'node.exe'}]))
        obj=Tools(root,Evidence(root/'E','run'));obj.prepare(required=['node']);return obj
    def test_stale_runtime_cache_marker_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            obj=self.prepare(Path(td),marker='stale',replaced=True);self.assertIn('node',obj.required_failures());self.assertNotIn('node',obj.paths)
    def test_matching_cache_marker_cannot_hide_replaced_executable(self):
        with tempfile.TemporaryDirectory() as td:
            obj=self.prepare(Path(td),marker='current',replaced=True);self.assertIn('node',obj.required_failures());self.assertNotIn('node',obj.paths)
    def test_runtime_executable_pointer_cannot_escape(self):
        with tempfile.TemporaryDirectory() as td:
            try:obj=self.prepare(Path(td),marker='current',symlink=True)
            except OSError:self.skipTest('symlink unavailable')
            self.assertIn('node',obj.required_failures());self.assertNotIn('node',obj.paths)
    def test_prepared_runtime_pointer_cannot_be_rebound(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);obj=self.prepare(root);self.assertIn('node',obj.paths);foreign=root/'foreign.exe';foreign.write_bytes(b'foreign');obj.paths['node']=str(foreign)
            with self.assertRaisesRegex(OSError,'RUNTIME_POINTER_CHANGED'):obj.get('node')

if __name__=='__main__':unittest.main()
