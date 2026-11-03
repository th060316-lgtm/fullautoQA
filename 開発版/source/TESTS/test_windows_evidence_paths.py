import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from common import Evidence,inside,report,result_zip,validate_result_zip

class WindowsEvidencePathTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.root=Path(tmp.name)

    def test_filesystem_identity_resolves_alias_without_lexical_containment(self):
        file=self.root/'sub'/'bridge.json';file.parent.mkdir();file.write_text('{}')
        # Model the inconsistent spelling check; actual filesystem identity must win.
        with patch.object(Path,'is_relative_to',return_value=False):
            self.assertEqual(inside(self.root,'sub/bridge.json'),file.resolve())

    def test_identity_fallback_still_rejects_escape(self):
        with patch.object(Path,'is_relative_to',return_value=False):
            with self.assertRaisesRegex(ValueError,'PATH_ESCAPE'):inside(self.root,'../escape')

    def test_resolved_symlink_outside_root_is_rejected(self):
        with tempfile.TemporaryDirectory() as outside:
            link=self.root/'external'
            try:link.symlink_to(outside,target_is_directory=True)
            except OSError:self.skipTest('Symlink creation not permitted by host')
            with self.assertRaisesRegex(ValueError,'PATH_ESCAPE'):inside(self.root,'external/secret')

    def test_windows_reference_survives_manifest_and_result_zip(self):
        path=self.root/'baseline_exports'/'target'/'screen.bmp';path.parent.mkdir(parents=True);path.write_bytes(b'pixels')
        ev=Evidence(self.root,'run')
        row=ev.result('regression','PASS','VERIFIED',[r'baseline_exports\target\screen.bmp'])
        self.assertEqual(row['evidence'],['baseline_exports/target/screen.bmp'])
        ev.event('screenshot',file=r'baseline_exports\target\screen.bmp')
        report(self.root,{'run_id':'run','overall':'PASS','results':[row]})
        ev.manifest();archive=result_zip(self.root,True)
        self.assertEqual(validate_result_zip(archive,True,'run')['overall'],'PASS')


    def test_regular_replaced_leaf_is_not_resolved_by_handle(self):
        file=self.root/'bridge.json';file.write_text('{}')
        original=Path.resolve
        def noisy(path,*args,**kwargs):
            if path.name==file.name:raise OSError('transient leaf handle path')
            return original(path,*args,**kwargs)
        with patch.object(Path,'resolve',autospec=True,side_effect=noisy):
            self.assertTrue(inside(self.root,'bridge.json').samefile(file))

    def test_file_symlink_to_outside_is_still_rejected(self):
        with tempfile.TemporaryDirectory() as outside:
            target=Path(outside)/'secret';target.write_text('secret')
            link=self.root/'bridge.json'
            try:link.symlink_to(target)
            except OSError:self.skipTest('Symlink creation not permitted by host')
            with self.assertRaisesRegex(ValueError,'PATH_ESCAPE'):inside(self.root,'bridge.json')
