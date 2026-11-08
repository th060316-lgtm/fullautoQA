import json,tempfile,unittest
from pathlib import Path
from run_target import authoritative_result

class PublicationBindingTests(unittest.TestCase):
    def test_recovery_companion_does_not_become_a_second_run(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);results=root/'RESULTS';primary=results/'run'/'RESULT_FOR_CHATGPT.zip';primary.parent.mkdir(parents=True);primary.write_bytes(b'primary')
            recovery=results/'run_recovery'/'RESULT_FOR_CHATGPT.zip';recovery.parent.mkdir();recovery.write_bytes(b'companion')
            (results/'latest.json').write_text(json.dumps({'run_id':'run','result_zip':str(primary)}))
            self.assertEqual(authoritative_result(root,set()),primary)
            with self.assertRaisesRegex(ValueError,'STALE'):authoritative_result(root,{'run'})
            (results/'latest.json').write_text(json.dumps({'run_id':'run','result_zip':str(recovery)}))
            with self.assertRaisesRegex(ValueError,'BINDING_MISMATCH'):authoritative_result(root,set())

if __name__=='__main__':unittest.main()
