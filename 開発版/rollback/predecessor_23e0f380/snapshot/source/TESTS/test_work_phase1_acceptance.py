import json,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from headquarters import HeadquartersSummary, DomainReport
from capability_contract import CapabilityContract
from target_identity import identity_components, load_bindings
from targets import load_target_manifest

class WorkPhase1AcceptanceTests(unittest.TestCase):
    def test_missing_headquarters_cannot_accept(self):
        summary=HeadquartersSummary([DomainReport('production','PASS')],generated_at='x')
        self.assertFalse(summary.accepted)
        self.assertEqual(summary.overall,'HARNESS_ERROR')
        self.assertEqual([d.status for d in summary.domains],['PASS','HARNESS_ERROR','HARNESS_ERROR'])

    def test_gate_summary_keeps_evidence(self):
        row={'test_case':'x','status':'FAIL','reason_code':'BROKEN','gate':'REQUIRED',
             'severity':'ERROR','evidence':['shot.png']}
        report=DomainReport.from_results('production',[row])
        self.assertEqual(report.gates[0]['evidence'],['shot.png'])
        self.assertEqual(report.gates[0]['severity'],'ERROR')

    def test_unchanged_optional_global_capability_is_not_fake_downgrade(self):
        c=CapabilityContract({'video':'target.declared'},
            declared={'available':['video'],'mandatory':[]},
            requirements={'game':[]},target_capabilities={'game':['video']})
        self.assertEqual(c.verify({'available':{'video'},'mandatory':set()},
                                  [{'id':'game','requirements':[],'required_capabilities':['video']}]),[])

    def test_target_capability_set_change_after_freeze_is_rejected(self):
        c=CapabilityContract({'video':'target.declared'},
            declared={'available':['video'],'mandatory':['video']},
            requirements={'game':[]},target_capabilities={'game':['video']})
        v=c.verify({'available':{'video'},'mandatory':{'video'}},
                   [{'id':'game','requirements':[],'required_capabilities':[]}])
        self.assertIn({'kind':'TARGET_CAPABILITY_SET_CHANGED','subject':'game'},v)

    def test_identity_changes_when_target_capabilities_change(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);(root/'p.json').write_text('{}')
            a={'id':'g','profile':'p.json','requirements':[],'required_capabilities':['video']}
            b=dict(a,required_capabilities=['screenshots'])
            self.assertNotEqual(identity_components(root,a),identity_components(root,b))

    def test_corrupt_binding_ledger_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);(root/'QA_BINDINGS.json').write_text('{"schema_version":999,"targets":{}}')
            with self.assertRaisesRegex(ValueError,'TARGET_BINDINGS_INVALID'):load_bindings(root)

    def test_duplicate_target_capability_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);(root/'p.json').write_text('{}')
            manifest={'schema_version':1,'targets':[{'id':'g','profile':'p.json',
                      'requirements':[],'required_capabilities':['video','video']}]}
            (root/'QA_TARGETS.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError,'TARGET_CAPABILITY_DUPLICATE'):
                load_target_manifest(root)

if __name__=='__main__':unittest.main()
