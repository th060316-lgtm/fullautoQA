import sys,unittest,tempfile
from pathlib import Path
from unittest.mock import Mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from agents import StallDetector
from windows_runner import Session
from common import Evidence

class SparseDetectorTests(unittest.TestCase):
    def test_sparse_static_observations_still_detect_stall(self):
        d=StallDetector(1.2)
        values=[d.observe(t,'stable',None,'right' if i%2 else 'down',reaction=0) for i,t in enumerate([0,1.7,3.4,5.1])]
        self.assertEqual(values,[None,None,None,'SOFTLOCK'])

    def test_progress_breaks_sparse_stall_interval(self):
        d=StallDetector(1)
        for i in range(6):self.assertIsNone(d.observe(i*2,str(i),None,'a' if i%2 else 'b',reaction=i))

    def test_waiting_resets_old_attempts(self):
        d=StallDetector(1)
        for i in range(3):d.observe(i*2,'same','screen','a' if i%2 else 'b',reaction=0)
        self.assertIsNone(d.observe(10,'same','screen','a',waiting=True,reaction=0))
        self.assertIsNone(d.observe(20,'same','screen','b',reaction=0))

    def test_single_action_or_missing_visual_is_not_softlock(self):
        for visual in (None,'screen'):
            d=StallDetector(1)
            for i in range(6):self.assertIsNone(d.observe(i*2,'same',visual,'a'))
        d=StallDetector(1)
        for i in range(6):self.assertIsNone(d.observe(i*2,'same',None,'a' if i%2 else 'b'))

    def test_late_exit_is_recorded_with_actual_return_code(self):
        with tempfile.TemporaryDirectory() as td:
            s=Session(Path(td),Evidence(td,'r'),None,{})
            s.shot=Mock(return_value=(None,None))
            process=Mock();process.poll.return_value=-1073741819
            self.assertTrue(s.crash_observed(process,'case',['trigger']))
            self.assertEqual(s.results[-1]['reason_code'],'CRASH')
            self.assertEqual(s.results[-1]['status'],'FAIL')
            self.assertTrue((Path(td)/'case_crash.json').is_file())
            process.poll.return_value=None
            self.assertFalse(s.crash_observed(process,'running',[]))
