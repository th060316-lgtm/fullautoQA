"""Recovery fix review: preserve successful certification; revoke every top-level
boolean certification after finalization errors. Five perspectives reviewed by
one AI (not five independent reviewers): authority unchanged, scope bounded,
user-visible status consistent, additive future flags covered, archived proof
tested. This is a candidate correction, not product acceptance.
"""
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
import common
import finalize

class CertificationRecoveryTests(unittest.TestCase):
    def run_case(self, failure=None):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)/'run';e=common.Evidence(root,'certification-test')
            (root/'proof.txt').write_text('observed')
            flags={'completion_certified':True,'target_qa_certified':True,
                   'functional_cases_certified':True,'future_certified':True}
            data=dict(run_id=e.run_id,overall='PASS',results=[e.result('smoke','PASS','OBSERVED',['proof.txt'])],**flags)
            def broken():raise RuntimeError('injected cleanup failure')
            if failure=='archive':
                original=finalize.result_zip
                count=0
                def fail_first(*args,**kwargs):
                    nonlocal count
                    count+=1
                    if count==1:raise RuntimeError('injected publication failure')
                    return original(*args,**kwargs)
                with patch('finalize.result_zip',side_effect=fail_first):
                    outcome=finalize.finalize_run(e,data)
            else:
                outcome=finalize.finalize_run(e,data,cleanup=[broken] if failure else [])
            self.assertTrue(outcome['zip_created'])
            with zipfile.ZipFile(outcome['result_zip']) as z:
                self.assertIsNone(z.testzip())
                archived=json.loads(z.read('result.json'))
            return data,archived

    def test_cleanup_failure_revokes_present_and_future_certification(self):
        data,archived=self.run_case('cleanup')
        for result in (data,archived):
            self.assertEqual(result['overall'],'HARNESS_ERROR')
            self.assertFalse(any(v for k,v in result.items() if k.endswith('_certified') and isinstance(v,bool)))

    def test_diagnostic_archive_does_not_certify_target(self):
        data,archived=self.run_case('archive')
        self.assertTrue(archived['diagnostic_archive'])
        self.assertIs(archived['target_qa_certified'],False)
        self.assertIs(data['target_qa_certified'],False)

    def test_successful_run_keeps_certification(self):
        data,archived=self.run_case()
        for result in (data,archived):
            self.assertEqual(result['overall'],'PASS')
            self.assertIs(result['target_qa_certified'],True)
            self.assertIs(result['future_certified'],True)
