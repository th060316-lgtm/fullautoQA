"""Contract and in-process runner tests; no real-game acceptance is claimed."""
import importlib.util,json,sys,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'CORE'))
from common import Evidence
from observations import observation_condition,predicate_evidence,validate_profile_observation_sources
from windows_runner import Session

class ObservationTests(unittest.TestCase):
    def observation(self):
        return {'internal_state':{},'external_observations':{'values':{'count':1},
            'provenance':{'method':'unit_measurement','evidence':['frame.bmp'],'claim_scope':'pixel_change_only'}}}
    def test_external_is_never_a_legacy_internal_predicate(self):
        obs=self.observation();predicate={'field':'count','op':'ge','value':1}
        self.assertFalse(observation_condition(obs,predicate))
        predicate['observation_source']='external_observations'
        self.assertTrue(observation_condition(obs,predicate))
        proof=predicate_evidence(obs,predicate)
        self.assertNotIn('state',proof);self.assertEqual(proof['semantic_game_outcome'],'UNVERIFIED')
    def test_missing_provenance_or_evidence_cannot_pass(self):
        predicate={'observation_source':'external_observations','field':'count','op':'ge','value':1}
        obs=self.observation();obs['external_observations'].pop('provenance')
        with self.assertRaisesRegex(ValueError,'PROVENANCE'):observation_condition(obs,predicate)
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(ValueError,'EVIDENCE_MISSING'):observation_condition(self.observation(),predicate,td)
            (Path(td)/'frame.bmp').write_bytes(b'unit');self.assertTrue(observation_condition(self.observation(),predicate,td))
    def test_external_game_goal_and_unknown_source_rejected(self):
        with self.assertRaisesRegex(ValueError,'NOT_GAME_GOAL'):
            validate_profile_observation_sources({'goals':[{'observation_source':'external_observations'}]})
        with self.assertRaisesRegex(ValueError,'SOURCE_UNKNOWN'):
            observation_condition(self.observation(),{'observation_source':'typo'})
    def test_visual_adapter_keeps_internal_state_empty(self):
        spec=importlib.util.spec_from_file_location('visual_adapter',ROOT/'GAME/supplementary/blackbox_visual_adapter.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        with tempfile.TemporaryDirectory() as td:
            a=m.VisualAdapter({'blackbox':{}},{'desktop':SimpleNamespace(state=lambda:{'exists':True}),'evidence':Evidence(td,'unit'),'tools':SimpleNamespace(paths={})})
            a.changes=3;a.records=[{'before':'a.bmp','after':'b.bmp'}]
            obs=a.observe();self.assertFalse(a.capabilities()['internal_state']);self.assertEqual(obs['internal_state'],{})
            self.assertEqual(obs['external_observations']['values']['visible_response_count'],3)
    def test_runner_predicate_sources_and_evidence_remain_separate(self):
        for external in (False,True):
            with self.subTest(external=external),tempfile.TemporaryDirectory() as td:
                root=Path(td);e=Evidence(root/'run','unit');(e.root/'frame.bmp').write_bytes(b'unit observation')
                predicate={'field':'count','op':'ge','value':1}
                if external:predicate['observation_source']='external_observations'
                p={'game_id':'unit','actions':{'ping':{'inputs':[]}},'goals':[],'tests':[{'id':'check','scenario':'s','expect':predicate}]}
                obs=self.observation() if external else {'internal_state':{'count':1}}
                obs.update({'window':{'exists':True,'focused':True},'scene':None,'ocr':None})
                adapter=SimpleNamespace(observe=lambda:obs,act=lambda _:None,capabilities=lambda:{'internal_state':not external},close=lambda:None)
                session=Session(root,e,None,p)
                session.copy_game=lambda _:root
                def start(*_):
                    for suffix in ('stdout','stderr'):(e.root/('unit.s_'+suffix+'.log')).write_text('')
                    return SimpleNamespace(poll=lambda:None),adapter
                session.start=start;session.disk_guard=lambda:None;session.monitor=lambda *_:None
                session.shot=lambda *_args,**_kw:('frame.bmp',[0]);session.observe_features=lambda *_:[0]
                session.stop=lambda:None;session.checkpoint=lambda *_:None;session.behavioral_regression=lambda *_:None
                session.run_scenario({'id':'s','agent':'Smoke','sequence':['ping'],'action_budget':1,'time_budget':5,'observation_delay':0},1)
                row=next(x for x in session.results if x['test_case']=='unit.s.check')
                self.assertEqual(row['status'],'PASS');self.assertEqual(row['reason_code'],'EXTERNAL_OBSERVATION_CHECK' if external else 'EXPECTED_STATE')
                self.assertFalse(any(x['reason_code']=='GOAL_REACHED' for x in session.results))
                proof=json.loads((e.root/'unit.s_check.json').read_text())
                if external:
                    self.assertNotIn('state',proof);self.assertEqual(proof['semantic_game_outcome'],'UNVERIFIED')
                    state_event=next(json.loads(x) for x in (e.root/'state.jsonl').read_text().splitlines())
                    self.assertEqual(state_event['internal_state'],{});self.assertIn('external_observations',state_event)
                else:self.assertEqual(proof['state'],{'count':1})
if __name__=='__main__':unittest.main()
