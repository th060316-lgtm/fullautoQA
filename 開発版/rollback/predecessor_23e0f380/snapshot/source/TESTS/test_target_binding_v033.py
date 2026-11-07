import json,sys,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from targets import load_target_manifest,selected_profiles,validate_target_profile,requirement_coverage,required_agents,target_scope_satisfied,baseline_source

class TargetBindingV033Tests(unittest.TestCase):
    def setUp(self):
        self.t=tempfile.TemporaryDirectory();self.addCleanup(self.t.cleanup);self.root=Path(self.t.name)
        (self.root/'PROFILES').mkdir()
        self.settings={'paths':{'target_manifest':'QA_TARGETS.json'}}
    def profile(self,role=None,playable=True):
        p={
          'game_id':'game','game_version':'1','profile_version':'1','schema_version':1,
          'prototype_type':'playable' if playable else 'logic','launch':{},
          'actions':{'go':{'inputs':[]}},'goals':[{'id':'win','type':'reach_score','field':'score','op':'ge','value':1}],
          'scenarios':[{'id':'goal','agent':'Goal','sequence':['go'],'goal':'win','save_load':True,'verify_seed_replay':True},
                       {'id':'smoke','agent':'Smoke','sequence':['go']}],
          'tests':[{'id':'score','scenario':'goal','expect':{'field':'score','op':'ge','value':1}}],
          'observations':{},'instructions':'play','save':{'file':'save.json'},
          'qa_plan':{'soak':{'scenario':'smoke'},'regression':{'scenario':'goal','state_fields':['score']},'faults':[{'id':'crash','scenario':{'sequence':['go']},'expected':{'status':'FAIL','reason':'CRASH'}}]}
        }
        if role:p['qa_role']=role
        return p
    def write_manifest(self,requirements=None,profile='PROFILES/game.json',baseline=None):
        d={'schema_version':1,'baseline':baseline,'targets':[{'id':'game','profile':profile,'requirements':requirements or []}]}
        (self.root/'QA_TARGETS.json').write_text(json.dumps(d),encoding='utf-8');return d
    def test_no_target_manifest_is_explicit_error(self):
        with self.assertRaisesRegex(ValueError,'NO_TARGET_CONFIGURED'):load_target_manifest(self.root,self.settings)
    def test_manifest_selects_only_declared_target(self):
        d=self.write_manifest(profile='PROFILES/game.json')
        (self.root/'PROFILES/game.json').write_text('{}')
        (self.root/'PROFILES/fixture.json').write_text('{}')
        m=load_target_manifest(self.root,self.settings)
        self.assertEqual(selected_profiles(m),['PROFILES/game.json'])
    def test_selftest_profile_cannot_be_target(self):
        p=self.profile(role='selftest');entry={'id':'game','profile':'PROFILES/game.json','requirements':['goal']}
        self.assertIn('SELFTEST_PROFILE_CANNOT_BE_TARGET',validate_target_profile(p,entry))
    def test_declared_requirements_are_audited(self):
        p=self.profile();entry={'id':'game','profile':'PROFILES/game.json','requirements':['goal','save_load','soak','regression','historical_regression','faults','technical_tests','seed_replay','player_review_evidence']}
        cov=requirement_coverage(p,entry);self.assertTrue(all(cov.values()),cov);self.assertEqual(validate_target_profile(p,entry),[])
    def test_missing_requirement_blocks_contract(self):
        p=self.profile();p['qa_plan'].pop('soak');entry={'id':'game','profile':'PROFILES/game.json','requirements':['soak']}
        self.assertEqual(validate_target_profile(p,entry),['soak'])
    def test_agents_derive_from_profile_not_universal_four(self):
        p=self.profile();entry={'id':'game','profile':'PROFILES/game.json','requirements':[]}
        self.assertEqual(required_agents(p,entry),{'Goal','Smoke'})
    def test_explicit_agent_contract_is_supported(self):
        p=self.profile();entry={'id':'game','profile':'PROFILES/game.json','requirements':[],'required_agents':['Goal']}
        self.assertEqual(required_agents(p,entry),{'Goal'})
    def test_adhoc_never_satisfies_target_scope(self):
        p=self.profile();session=SimpleNamespace(p=p,coverage={'agents':{'Goal','Smoke'}});entry={'id':'game','profile':'PROFILES/game.json','requirements':[]}
        self.assertFalse(target_scope_satisfied('adhoc',[session],{'game':entry},{'game':{'missing':[]}}))
        self.assertTrue(target_scope_satisfied('target',[session],{'game':entry},{'game':{'missing':[]}}))
    def test_missing_required_agent_blocks_target_scope(self):
        p=self.profile();session=SimpleNamespace(p=p,coverage={'agents':{'Goal'}});entry={'id':'game','profile':'PROFILES/game.json','requirements':[]}
        self.assertFalse(target_scope_satisfied('target',[session],{'game':entry},{'game':{'missing':[]}}))
    def test_manifest_baseline_must_stay_inside_package(self):
        (self.root/'old.zip').write_bytes(b'x');m=self.write_manifest(baseline='old.zip')
        loaded=load_target_manifest(self.root,self.settings);self.assertEqual(baseline_source(self.root,loaded),self.root/'old.zip')
        self.write_manifest(baseline='../outside.zip')
        with self.assertRaisesRegex(ValueError,'PATH_ESCAPE'):load_target_manifest(self.root,self.settings)

if __name__=='__main__':unittest.main()
