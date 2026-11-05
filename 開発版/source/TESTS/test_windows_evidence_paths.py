import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
import common
from common import Evidence,inside,report,result_zip,tree_size,validate_result_zip

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

    @unittest.skipUnless(os.name=='nt','subst path spelling is Windows-only')
    def test_subst_operational_root_spelling_is_preserved(self):
        physical=self.root/'physical 日本語 space';physical.mkdir()
        file=physical/'sub'/'bridge.json';file.parent.mkdir();file.write_text('{}')
        drive=None
        for letter in reversed('DEFGHIJKLMNOPQRSTUVWXYZ'):
            candidate=letter+':'
            if not Path(candidate+'\\').exists():
                drive=candidate;break
        if drive is None:self.skipTest('No free drive letter for subst')
        subst=Path(os.environ.get('SystemRoot',r'C:\\Windows'))/'System32'/'subst.exe'
        subprocess.run([str(subst),drive,str(physical)],check=True,capture_output=True)
        try:
            alias=Path(drive+'\\')
            result=inside(alias,'sub/bridge.json')
            self.assertEqual(result.drive.upper(),drive.upper())
            self.assertTrue(result.is_file())
            with self.assertRaisesRegex(ValueError,'PATH_ESCAPE'):inside(alias,'../escape')
        finally:
            subprocess.run([str(subst),drive,'/d'],check=False,capture_output=True)

    def test_tree_size_tolerates_only_vanishing_excluded_files(self):
        stable=self.root/'proof.bin';stable.write_bytes(b'proof')
        work=self.root/'WORK'/'case'/'state.json';work.parent.mkdir(parents=True);work.write_bytes(b'transient')
        original=Path.stat
        def vanished(path,*args,**kwargs):
            if path==work:raise FileNotFoundError(str(path))
            return original(path,*args,**kwargs)
        with patch.object(Path,'stat',autospec=True,side_effect=vanished):
            self.assertEqual(tree_size(self.root,tolerate_excluded_vanish=True),stable.stat().st_size)
            self.assertEqual(tree_size(self.root,eligible_only=True,tolerate_excluded_vanish=True),stable.stat().st_size)

        def nonwork_missing(path,*args,**kwargs):
            if path==stable:raise FileNotFoundError(str(path))
            return original(path,*args,**kwargs)
        with patch.object(Path,'stat',autospec=True,side_effect=nonwork_missing):
            with self.assertRaises(FileNotFoundError):
                tree_size(self.root,tolerate_excluded_vanish=True)

        def work_permission(path,*args,**kwargs):
            if path==work:raise PermissionError(str(path))
            return original(path,*args,**kwargs)
        with patch.object(Path,'stat',autospec=True,side_effect=work_permission):
            with self.assertRaises(PermissionError):
                tree_size(self.root,tolerate_excluded_vanish=True)

    def test_manifest_records_vanishing_excluded_file_without_losing_certified_evidence(self):
        work=self.root/'WORK'/'case'/'state.json';work.parent.mkdir(parents=True);work.write_bytes(b'transient')
        proof=self.root/'proof.bin';proof.write_bytes(b'proof')
        ev=Evidence(self.root,'run')
        original=common.digest
        def digest_with_vanish(path):
            if Path(path)==work:raise FileNotFoundError(str(path))
            return original(path)
        with patch('common.digest',side_effect=digest_with_vanish):
            manifest=ev.manifest()
        self.assertTrue(any(row['file']=='proof.bin' for row in manifest))
        excluded=json.loads((self.root/'excluded_work_inventory.json').read_text(encoding='utf-8'))
        self.assertTrue(any(row['file']=='WORK/case/state.json' and row['reason']=='TRANSIENT_EXCLUDED_FILE_VANISHED' for row in excluded))

    def test_manifest_transient_permission_failure_still_raises(self):
        work=self.root/'WORK'/'case'/'state.json';work.parent.mkdir(parents=True);work.write_bytes(b'transient')
        ev=Evidence(self.root,'run')
        original=Path.stat
        def denied(path,*args,**kwargs):
            if path==work:raise PermissionError(str(path))
            return original(path,*args,**kwargs)
        with patch.object(Path,'stat',autospec=True,side_effect=denied):
            with self.assertRaises(PermissionError):
                ev.manifest()

    def test_manifest_certified_file_read_failure_still_raises(self):
        proof=self.root/'proof.bin';proof.write_bytes(b'proof')
        ev=Evidence(self.root,'run')
        original=common.digest
        def digest_failure(path):
            if Path(path)==proof:raise FileNotFoundError(str(path))
            return original(path)
        with patch('common.digest',side_effect=digest_failure):
            with self.assertRaises(FileNotFoundError):
                ev.manifest()

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
