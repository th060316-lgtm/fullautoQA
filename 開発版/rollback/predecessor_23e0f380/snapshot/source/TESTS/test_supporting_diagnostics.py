import hashlib,json,sys,tempfile,unittest,zipfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from common import Evidence,validate_result_zip,result_zip,write_json
from supporting_diagnostics import attach_diagnostics

class SupportingDiagnosticTests(unittest.TestCase):
    def test_historical_fail_is_preserved_without_a_verdict_or_new_gate(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);p=root/'old.json';p.write_text(json.dumps({'scope':'outside_target_acceptance_contract','historical_only':True,'classification':'diagnostic','status':'FAIL','origin':{'run_id':'old'}}))
            profile={'game_id':'arbitrary','supporting_diagnostics':[{'id':'old','scope':'outside_target_acceptance_contract','files':[{'path':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}]}]}
            e=Evidence(root/'run','new');rows=attach_diagnostics(root,e,profile)
            self.assertEqual(rows[0]['status'],'FAIL');self.assertFalse(rows[0]['affects_required_gate'])
            self.assertEqual((e.root/rows[0]['evidence'][0]).read_bytes(),p.read_bytes())
            event=json.loads((e.root/'events.jsonl').read_text());self.assertEqual(event['type'],'supporting_diagnostic');self.assertNotIn('gate',event)
            write_json(e.root/'result.json',{'run_id':'new','overall':'PASS','results':[],'supporting_diagnostics':rows});e.manifest()
            self.assertEqual(validate_result_zip(result_zip(e.root,True),True,'new')['overall'],'PASS')
    def test_changed_diagnostic_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);(root/'old.json').write_text('{}')
            profile={'game_id':'any','supporting_diagnostics':[{'id':'x','scope':'outside_target_acceptance_contract','files':[{'path':'old.json','sha256':'wrong'}]}]}
            with self.assertRaisesRegex(ValueError,'INTEGRITY_FAILURE'):attach_diagnostics(root,Evidence(root/'run','new'),profile)
    def test_diagnostic_cannot_be_declared_inside_required_contract(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(ValueError,'SCOPE_INVALID'):attach_diagnostics(Path(td),Evidence(Path(td)/'r','new'),{'supporting_diagnostics':[{'scope':'required'}]})
    def test_no_diagnostics_is_no_change(self):
        with tempfile.TemporaryDirectory() as td:self.assertEqual(attach_diagnostics(Path(td),Evidence(Path(td)/'r','new'),{}),[])

if __name__=='__main__':unittest.main()
