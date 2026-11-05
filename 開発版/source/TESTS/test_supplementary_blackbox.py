"""Generic recipe/parser unit checks, never real-game acceptance evidence."""
import importlib.util,json,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'CORE'))
import profile
s=importlib.util.spec_from_file_location('prepare_copy',ROOT/'SUPPLEMENTARY/blackbox/prepare_copy.py');prep=importlib.util.module_from_spec(s);s.loader.exec_module(prep)
class CopyTests(unittest.TestCase):
    def test_profile_is_bridge_less_and_runtime_explicit(self):
        p=profile.load(ROOT,next((ROOT/'SUPPLEMENTARY/blackbox').glob('*.json')))
        self.assertNotIn('bridge',p);self.assertEqual(p['tools_required'],['godot']);self.assertNotIn('ocr',p['observations'])
    def test_overlap_and_recipe_escape_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            src=Path(td)/'src';src.mkdir();(src/'f').write_text('a')
            with self.assertRaisesRegex(ValueError,'NONOVERLAPPING'):prep.prepare(src,src/'child',{'copy_recipe':{}})
            with self.assertRaisesRegex(ValueError,'PATH_ESCAPE'):prep.prepare(src,Path(td)/'copy',{'copy_recipe':{'remove':['../escape']}})
            self.assertEqual((src/'f').read_text(),'a');self.assertFalse((Path(td)/'copy').exists())
    def test_generic_recipe_preserves_original(self):
        with tempfile.TemporaryDirectory() as td:
            src=Path(td)/'src';src.mkdir();(src/'f').write_text('bridge\nkeep\n')
            r=prep.prepare(src,Path(td)/'copy',{'copy_recipe':{'replace':[{'file':'f','old':'bridge\n','new':'','expected_count':1}]}})
            self.assertTrue(r['source_read_only_unchanged']);self.assertEqual(r['changed'],['f'])
            self.assertEqual((src/'f').read_text(),'bridge\nkeep\n')
    def test_inventory_mismatch_fails_before_copy(self):
        with tempfile.TemporaryDirectory() as td:
            src=Path(td)/'src';src.mkdir();(src/'f').write_text('x');dest=Path(td)/'copy'
            with self.assertRaisesRegex(ValueError,'INVENTORY_MISMATCH'):prep.prepare(src,dest,{'copy_recipe':{'source_inventory_sha256':'0'*64}})
            self.assertFalse(dest.exists())
if __name__=='__main__':unittest.main()
