import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'CORE'))
from target_intake import starter_profile,select_profile
from targets import load_target_manifest

class IntakeTests(unittest.TestCase):
    def profile(self):
        p=starter_profile('independent_game',['{runtime}','{work}']);p.pop('intake_status');return p
    def test_starter_unbound_and_selection_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);p=root/'draft.json';p.write_text(json.dumps(starter_profile('draft',['runtime'])))
            with self.assertRaisesRegex(ValueError,'STARTER_NOT_VALIDATED'):select_profile(root,p)
            self.assertFalse((root/'QA_TARGETS.json').exists())
    def test_external_profile_selection_and_readback(self):
        with tempfile.TemporaryDirectory() as td,tempfile.TemporaryDirectory() as ext:
            root=Path(td);(root/'GAME/independent_game').mkdir(parents=True)
            p=Path(ext)/'arbitrary.json';p.write_text(json.dumps(self.profile()));r=select_profile(root,p)
            self.assertTrue(r['manifest_readback_ok']);self.assertEqual(r['acceptance'],'NOT_RUN')
            self.assertEqual(r['files_created'],2)
            with self.assertRaisesRegex(ValueError,'SELECTION_EXISTS'):select_profile(root,p)
    def test_preserves_existing_requirements_and_configured_manifest(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);(root/'GAME/independent_game').mkdir(parents=True)
            p=root/'p.json';p.write_text(json.dumps(self.profile()))
            settings={'paths':{'target_manifest':'state/selection.json'}};(root/'acceptance_manifest.json').write_text(json.dumps(settings))
            r=select_profile(root,p);manifest=Path(r['manifest']);data=json.loads(manifest.read_text())
            data['targets'][0]['required_agents']=['Smoke'];data['targets'][0]['requirements']=['technical_tests']
            manifest.write_text(json.dumps(data))
            # A preserved stricter contract cannot silently disappear.
            with self.assertRaisesRegex(ValueError,'technical_tests'):select_profile(root,p,replace=True)
            self.assertEqual(json.loads(manifest.read_text()),data)
    def test_fixture_and_escape_have_no_manifest_side_effect(self):
        for change,reason in [({'qa_role':'fixture'},'FIXTURE'),({'source':'../outside'},'PATH_ESCAPE')]:
            with tempfile.TemporaryDirectory() as td:
                root=Path(td);(root/'GAME/independent_game').mkdir(parents=True);p=root/'p.json';data=self.profile();data.update(change);p.write_text(json.dumps(data))
                with self.assertRaisesRegex(ValueError,reason):select_profile(root,p)
                self.assertFalse((root/'QA_TARGETS.json').exists())
    def test_cli_arbitrary_root_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='different root ') as td:
            r=subprocess.run([sys.executable,str(ROOT/'CORE/target_intake.py'),'--root',td,'starter','--game-id','new_id','--launch-json','["{runtime}"]'],capture_output=True,text=True,check=True)
            self.assertFalse(json.loads(r.stdout)['bound']);self.assertFalse((Path(td)/'QA_TARGETS.json').exists())
if __name__=='__main__':unittest.main()
