import hashlib,json,unittest
from pathlib import Path

class FinalTargetContractTests(unittest.TestCase):
    def test_legacy_diagnostic_is_retained_outside_formal_gate(self):
        root=Path(__file__).parent;p=json.loads((root/'profile.json').read_text(encoding='utf-8'))
        self.assertNotIn('MiniMaxIntegrationTest',{t['id'] for t in p['technical_tests']})
        self.assertTrue((root/'source/tests/MiniMaxIntegrationTest.gd').is_file())
        for item in p['supporting_diagnostics']:
            self.assertEqual(item['scope'],'outside_target_acceptance_contract')
            for row in item['files']:
                path=root/'diagnostics'/Path(row['path']).name
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),row['sha256'])
        record=json.loads((root/'diagnostics/MiniMaxIntegrationTest.json').read_text(encoding='utf-8'))
        self.assertEqual(record['status'],'FAIL');self.assertEqual(record['original_verdict']['status'],'FAIL')
    def test_current_formal_headless_acceptance_is_present(self):
        root=Path(__file__).parent;p=json.loads((root/'profile.json').read_text(encoding='utf-8'))
        ids={x['id'] for x in p['technical_tests']}
        self.assertTrue({'game_boot','core_integration','EconomicCoreIntegrationTest','HoldReleaseAcceptanceTest','WorkCompletionAcceptanceTest','WorldDynamicsAcceptanceTest','LongRunProfile','UIInteractionTest','DestructiveTest','FontSupportTest','economic_core_selftest'}<=ids)
        self.assertEqual(p['prototype_type'],'logic');self.assertNotIn('save',p)

if __name__=='__main__':unittest.main()
