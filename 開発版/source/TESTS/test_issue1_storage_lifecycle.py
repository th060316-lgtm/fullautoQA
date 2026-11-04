import json,subprocess,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'CORE'))
from storage_qa import StorageInspector,run_storage_scenario,STORAGE_FEATURES,PathEscapeError
from profile import condition
class StorageLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name);self.data=self.root/'data';self.data.mkdir();(self.root/'corrupt.bin').write_bytes(b'not-json');(self.root/'old.json').write_text(json.dumps({'value':37,'version':1}));self.inspector=StorageInspector(self.data,['a.json','b.json']);self.start();self.addCleanup(self.stop)
    def start(self):self.process=subprocess.Popen([sys.executable,str(ROOT/'TESTS/fixtures/storage_process.py'),str(self.data)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    def stop(self):self.process.stdin.close();self.process.wait(timeout=5);self.process.stdout.close()
    def action(self,action):self.process.stdin.write(json.dumps({'action':action})+'\n');self.process.stdin.flush();return json.loads(self.process.stdout.readline())
    def observe(self):return self.action('observe')
    def restart(self):
        previous=self.process;self.stop();self.start();return {'before_pid':previous.pid,'after_pid':self.process.pid,'before_exited':previous.poll() is not None}
    def run_case(self,feature,steps,**extra):return run_storage_scenario(self.inspector,{'id':feature,'feature':feature,'supported':True,'steps':steps,**extra},act=self.action,observe=self.observe,restart=self.restart,fixture_root=self.root,condition=condition)
    def restore_steps(self):return [{'action':'change'},{'action':'save','role':'save'},{'snapshot':'saved'},{'action':'change','role':'mutate'},{'snapshot':'changed'},{'restart':True},{'action':'load','role':'load'},{'snapshot':'restored'},{'expect':{'field':'value','op':'eq','value':7}}]
    def test_real_child_save_change_restart_restore(self):
        result=self.run_case('restart_restore',self.restore_steps(),state_fields=['value']);self.assertEqual(result['status'],'PASS',result);self.assertTrue(result['restart_verified']);proof=result['steps'][5]['process'];self.assertNotEqual(proof['before_pid'],proof['after_pid'])
    def fault_steps(self,feature,expected):return [{'fixture':'corrupt.bin' if feature=='corrupt' else 'old.json','path':'a.json','role':'corrupt' if feature=='corrupt' else 'old_version'},{'action':'load','role':'load'},{'expect':expected}]
    def test_corrupt_storage_rejected_by_real_process(self):self.assertEqual(self.run_case('corrupt',self.fault_steps('corrupt',{'field':'error','op':'eq','value':'corrupt'}))['status'],'PASS')
    def test_old_version_and_migration(self):
        for feature in ('old_version','migration'):
            result=self.run_case(feature,self.fault_steps(feature,{'field':'value','op':'eq','value':37})+[{'expect':{'field':'version','op':'eq','value':2}}]);self.assertEqual(result['status'],'PASS',result);self.assertEqual(json.loads((self.data/'a.json').read_text())['version'],2)
    def test_two_slots_retain_different_values(self):
        result=self.run_case('multi_slot',[{'action':'change'},{'action':'save','role':'save','slot':'a'},{'action':'slot_b'},{'action':'change'},{'action':'save','role':'save','slot':'b'},{'action':'slot_a'},{'action':'load','role':'load','slot':'a'},{'expect':{'field':'value','op':'eq','value':7}},{'action':'slot_b'},{'action':'load','role':'load','slot':'b'},{'expect':{'field':'value','op':'eq','value':14}}]);self.assertEqual(result['status'],'PASS',result)
    def test_autosave_without_explicit_save(self):
        result=self.run_case('autosave',[{'action':'autosave','role':'autosave_trigger'},{'snapshot':'saved'},{'restart':True},{'action':'load'},{'expect':{'field':'value','op':'eq','value':11}}]);self.assertEqual(result['status'],'PASS',result)
    def test_unsupported_never_runs_or_passes(self):
        for feature in STORAGE_FEATURES:
            result=run_storage_scenario(self.inspector,{'feature':feature,'supported':False},act=lambda _:self.fail(),observe=lambda:self.fail(),restart=lambda:self.fail(),fixture_root=self.root,condition=condition);self.assertEqual(result['status'],'NOT_RUN')
    def test_restart_claim_without_pid_transition_cannot_pass(self):
        result=run_storage_scenario(self.inspector,{'feature':'restart_restore','supported':True,'state_fields':['value'],'steps':self.restore_steps()},act=self.action,observe=self.observe,restart=lambda:{'before_pid':1,'after_pid':1,'before_exited':False},fixture_root=self.root,condition=condition);self.assertNotEqual(result['status'],'PASS');self.assertIn('STORAGE_RESTART_UNVERIFIED',result['missing'])
    def test_fixture_outside_declared_storage_rejected(self):
        result=self.run_case('corrupt',[{'fixture':'corrupt.bin','path':'other.bin','role':'corrupt'}]);self.assertEqual(result['status'],'HARNESS_ERROR');self.assertFalse((self.data/'other.bin').exists())
    def test_late_symlink_rejected(self):
        outside=self.root/'outside.json';outside.write_text('foreign')
        try:(self.data/'a.json').symlink_to(outside)
        except OSError:self.skipTest('symlink unavailable')
        with self.assertRaises(PathEscapeError):self.inspector.snapshot()
    def test_supported_without_steps_is_not_run(self):self.assertEqual(self.run_case('migration',[])['status'],'NOT_RUN')
    def test_action_label_cannot_replace_real_corrupt_fixture_injection(self):
        result=self.run_case('corrupt',[{'action':'change','role':'corrupt'},{'action':'load','role':'load'},{'expect':{'field':'error','op':'eq','value':'corrupt'}}])
        self.assertNotEqual(result['status'],'PASS');self.assertIn('STORAGE_FAULT_OR_LOAD_NOT_EXECUTED',result['missing'])
    def test_wrong_expected_state_is_failure(self):self.assertEqual(self.run_case('corrupt',self.fault_steps('corrupt',{'field':'error','op':'eq','value':'different'}))['status'],'FAIL')
if __name__=='__main__':unittest.main()
