import sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from storage_qa import StorageInspector,StorageQAError

class PersistedSaveStorageTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.root=Path(tmp.name)
        self.inspector=StorageInspector(self.root,['slot.bin'])
        self.before=self.inspector.snapshot()
        (self.root/'slot.bin').write_bytes(b'\x00\xffsaved binary data')
        self.saved=self.inspector.snapshot()

    def check(self,**kwargs):
        return self.inspector.check_persistence(self.before,self.saved,self.saved,self.saved,
            contract='persisted_save',**kwargs)

    def test_written_binary_save_plus_actual_mutation_and_restore_can_pass(self):
        self.assertEqual(self.check(state_mutated=True,state_restored=True)['status'],'PASS')

    def test_unchanged_bytes_without_observed_state_restore_cannot_pass(self):
        for mutated,restored in [(False,False),(True,False),(False,True)]:
            with self.subTest(mutated=mutated,restored=restored):
                self.assertNotEqual(self.check(state_mutated=mutated,state_restored=restored)['status'],'PASS')

    def test_no_save_write_cannot_pass(self):
        value=self.inspector.check_persistence(self.saved,self.saved,self.saved,self.saved,
            contract='persisted_save',state_mutated=True,state_restored=True)
        self.assertEqual(value['status'],'FAIL')

    def test_changed_disk_bytes_cannot_pass_as_persisted_save(self):
        (self.root/'slot.bin').write_bytes(b'tampered')
        changed=self.inspector.snapshot()
        value=self.inspector.check_persistence(self.before,self.saved,changed,changed,
            contract='persisted_save',state_mutated=True,state_restored=True)
        self.assertEqual(value['status'],'FAIL')

    def test_unknown_mode_fails_closed(self):
        with self.assertRaisesRegex(StorageQAError,'UNKNOWN_STORAGE_CONTRACT'):
            self.inspector.check_persistence(self.before,self.saved,self.saved,self.saved,contract='unknown')

    def test_existing_disk_restore_contract_still_requires_disk_mutation(self):
        value=self.inspector.check_persistence(self.before,self.saved,self.saved,self.saved)
        self.assertEqual(value['status'],'INCONCLUSIVE')
