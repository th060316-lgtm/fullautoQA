"""Target identity and stale state defence: determinism, A -> B -> A, fixture safety."""
import json,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from targets import load_target_manifest,target_kind
from target_identity import (TargetIdentity,audit_results,bind_target,check_baseline_reuse,
                             check_result_binding,load_bindings)


class TargetIdentityTests(unittest.TestCase):
    def setUp(self):
        self.t=tempfile.TemporaryDirectory();self.addCleanup(self.t.cleanup);self.root=Path(self.t.name)
        (self.root/'PROFILES').mkdir();(self.root/'GAME').mkdir()
        self.write_profile('game',{'game_id':'game','game_version':'1'})
        self.write_game('a',b'game-a')
        self.entry={'id':'game','profile':'PROFILES/game.json','source':'GAME'}
        self.settings={'paths':{'target_manifest':'QA_TARGETS.json','target_bindings':'QA_BINDINGS.json'}}

    def write_profile(self,name,payload):
        (self.root/'PROFILES'/(name+'.json')).write_text(json.dumps(payload),encoding='utf-8')

    def write_game(self,name,data):
        (self.root/'GAME'/name).write_bytes(data)

    def bind(self,entry=None,profile=None):
        return bind_target(self.root,entry or self.entry,profile if profile is not None
                           else json.loads((self.root/'PROFILES'/'game.json').read_text(encoding='utf-8')),
                           settings=self.settings)

    def test_identity_is_deterministic_for_the_same_target(self):
        first=self.bind();second=self.bind()
        self.assertEqual(first.fingerprint,second.fingerprint)
        self.assertNotEqual(first.generation,second.generation)

    def test_identity_is_identical_in_two_identical_roots(self):
        other=Path(self.t.name)/'second'
        (other/'PROFILES').mkdir(parents=True);(other/'GAME').mkdir(parents=True)
        (other/'PROFILES'/'game.json').write_text((self.root/'PROFILES'/'game.json').read_text(encoding='utf-8'),encoding='utf-8')
        (other/'GAME'/'a').write_bytes(b'game-a')
        identity=bind_target(other,self.entry,None,settings=self.settings)
        self.assertEqual(identity.fingerprint,self.bind().fingerprint)

    def test_identity_changes_on_a_meaningful_target_change(self):
        before=self.bind().fingerprint
        self.write_profile('game',{'game_id':'game','game_version':'2'})
        self.assertNotEqual(before,self.bind().fingerprint)

    def test_identity_changes_when_the_source_changes(self):
        before=self.bind().fingerprint;self.write_game('a',b'game-a-modified')
        self.assertNotEqual(before,self.bind().fingerprint)

    def test_identity_changes_when_the_requirements_change(self):
        before=self.bind().fingerprint
        entry=dict(self.entry);entry['requirements']=['goal']
        self.assertNotEqual(before,self.bind(entry).fingerprint)

    def test_stale_result_of_the_previous_generation_is_rejected(self):
        first=self.bind();recorded=first.to_dict()
        self.write_game('a',b'game-b');second=self.bind()
        self.assertIn('STALE_TARGET_GENERATION',check_result_binding(second,recorded))

    def test_a_to_b_to_a_protects_against_a_stale_result(self):
        a1=self.bind();self.write_game('a',b'game-b');self.bind();self.write_game('a',b'game-a');a2=self.bind()
        self.assertEqual(a1.fingerprint,a2.fingerprint)
        self.assertGreater(a2.generation,a1.generation)
        self.assertIn('STALE_TARGET_GENERATION',check_result_binding(a2,a1.to_dict()))

    def test_a_to_b_to_a_protects_against_a_stale_baseline(self):
        a1=self.bind();self.write_game('a',b'game-b');self.bind();self.write_game('a',b'game-a');a2=self.bind()
        self.assertIn('STALE_BASELINE_LINEAGE_BROKEN',
                      check_baseline_reuse(a2,a1.to_dict(),root=self.root,settings=self.settings))

    def test_baseline_of_the_unchanged_target_stays_usable(self):
        a1=self.bind();a2=self.bind()
        self.assertEqual(a1.fingerprint,a2.fingerprint)
        self.assertEqual(check_baseline_reuse(a2,a1.to_dict(),root=self.root,settings=self.settings),[])

    def test_baseline_of_a_different_target_is_rejected(self):
        a1=self.bind();self.write_game('a',b'game-b');b=self.bind()
        self.assertIn('BASELINE_FINGERPRINT_MISMATCH',
                      check_baseline_reuse(b,a1.to_dict(),root=self.root,settings=self.settings))

    def test_baseline_without_a_ledger_fails_closed(self):
        a1=self.bind();(self.root/'QA_BINDINGS.json').unlink()
        self.assertIn('BASELINE_LINEAGE_UNVERIFIABLE',
                      check_baseline_reuse(a1,a1.to_dict(),root=self.root,settings=self.settings))

    def test_ledger_keeps_the_binding_history(self):
        self.bind();self.write_game('a',b'game-b');self.bind()
        history=load_bindings(self.root,self.settings)['targets']['game']['history']
        self.assertEqual(len(history),2)
        self.assertNotEqual(history[0]['fingerprint'],history[1]['fingerprint'])

    def test_fixture_identity_does_not_certify_a_real_target(self):
        entry=dict(self.entry);entry['kind']='fixture'
        identity=self.bind(entry)
        self.assertEqual(identity.kind,'fixture');self.assertFalse(identity.certifies_real_target)

    def test_selftest_identity_does_not_certify_a_real_target(self):
        profile=json.loads((self.root/'PROFILES'/'game.json').read_text(encoding='utf-8'))
        profile['qa_role']='selftest';identity=self.bind(self.entry,profile)
        self.assertEqual(identity.kind,'selftest');self.assertFalse(identity.certifies_real_target)

    def test_plain_target_certifies_a_real_target(self):
        identity=self.bind()
        self.assertEqual(identity.kind,'target');self.assertTrue(identity.certifies_real_target)
        self.assertEqual(target_kind({},self.entry),'target')

    def test_path_escape_protection_is_preserved(self):
        entry=dict(self.entry);entry['source']='../outside'
        with self.assertRaisesRegex(ValueError,'PATH_ESCAPE'):self.bind(entry)

    def test_manifest_rejects_an_unknown_target_kind(self):
        (self.root/'QA_TARGETS.json').write_text(json.dumps({'schema_version':1,'targets':[{'id':'game','profile':'PROFILES/game.json','kind':'weird'}]}),encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'TARGET_KIND_INVALID'):load_target_manifest(self.root,self.settings)

    def test_manifest_keeps_escape_protection_for_identity_paths(self):
        (self.root/'QA_TARGETS.json').write_text(json.dumps({'schema_version':1,'targets':[{'id':'game','profile':'PROFILES/game.json','source':'../outside'}]}),encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'PATH_ESCAPE'):load_target_manifest(self.root,self.settings)

    def test_identity_round_trips_through_json(self):
        identity=self.bind();restored=TargetIdentity.from_dict(json.loads(json.dumps(identity.to_dict())))
        self.assertEqual(restored.fingerprint,identity.fingerprint)
        self.assertEqual(restored.generation,identity.generation)

    def test_stale_results_are_audited_and_not_silently_reused(self):
        first=self.bind();results=self.root/'RESULTS';results.mkdir();(results/'run1').mkdir()
        (results/'run1'/'result.json').write_text(json.dumps({'overall':'PASS','target_identity':first.to_dict()}),encoding='utf-8')
        self.write_game('a',b'game-b');second=self.bind()
        findings=audit_results(self.root,second,results,self.settings)
        self.assertEqual(findings[0]['verdict'],'STALE')
        self.assertIn('STALE_TARGET_GENERATION',findings[0]['violations'])

if __name__=='__main__':unittest.main()
