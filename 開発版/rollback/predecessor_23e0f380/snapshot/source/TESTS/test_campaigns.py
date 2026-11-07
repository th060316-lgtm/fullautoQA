"""Portable regression checks. GUI integration is tested by actual Session runs."""
import unittest,tempfile,copy,struct,zipfile,sys,shutil,time,os
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from common import Evidence,read_json,write_json,result_zip
from campaigns import *
from regression import export_baseline,load_baseline,import_baseline,compare,masked_distance
from agents import Agent
from windows_runner import Session
ROOT=Path(__file__).resolve().parents[1]
class CampaignTests(unittest.TestCase):
 def setUp(self):self.p=read_json(ROOT/'VALIDATION_PROFILES/rfb_grid.json')
 def test_native_execute_calls_campaign_engine(self):
  with tempfile.TemporaryDirectory() as tmp:
   session=Session(ROOT,Evidence(tmp,'case'),None,self.p)
   with patch.object(session,'copy_game',return_value=Path(tmp)),patch.object(session,'technical',return_value=True),patch.object(session,'run_scenario',return_value=({'action_history':[]},[])),patch.object(session,'resource_analysis'),patch('windows_runner.execute_plans') as hooked:
    session.execute(71,{'faults':True});hooked.assert_called_once_with(session,71,{'faults':True})
 def test_every_native_profile_declares_six_fault_types(self):
  for path in (ROOT/'PROFILES').glob('*.json'):self.assertEqual({c['id'] for c in read_json(path)['qa_plan']['faults']},{'crash','stall','save','visual','loop','missing_asset'})
 def test_false_fault_pass_rejected(self):self.assertFalse(fault_detected([{'status':'PASS','reason_code':'OK'}],{'status':'FAIL','reason':'CRASH'}))
 def test_unrelated_harness_failure_not_hidden(self):self.assertFalse(fault_detected([{'status':'FAIL','reason_code':'CRASH'},{'status':'HARNESS_ERROR','reason_code':'SCREEN_CAPTURE_FAILED'}],{'status':'FAIL','reason':'CRASH'}))
 def test_fault_profile_is_restored_after_exception(self):
  with tempfile.TemporaryDirectory() as tmp:
   self.p['game_id']='arbitrary';s=Session(ROOT,Evidence(tmp,'case'),None,self.p)
   with patch.object(s,'run_scenario',side_effect=OSError('test')):
    with self.assertRaises(OSError):inject_faults(s,1)
   self.assertIs(s.p,self.p)
 def test_duration_thresholds_hour_and_day(self):
  for seconds in (3600,86400):
   with self.subTest(seconds=seconds):
    s=soak_scenario(self.p,seconds);self.assertGreater(s['time_budget'],seconds);self.assertFalse(soak_complete(seconds-.01,999999,s,True));self.assertTrue(soak_complete(seconds,999999,s,True));self.assertFalse(soak_complete(seconds,999999,s,False))
 def test_loop_only_soak(self):
  self.p['qa_plan']['soak']={'loops':200};s=soak_scenario(self.p);self.assertFalse(soak_complete(999,199,s,True));self.assertTrue(soak_complete(1,200,s,True))
 def test_duration_and_loops_are_both_required(self):
  s={'soak_seconds':20,'soak_loops':100};self.assertFalse(soak_complete(19,100,s,True));self.assertFalse(soak_complete(20,99,s,True));self.assertTrue(soak_complete(20,100,s,True))
 def test_invalid_targets_rejected(self):
  for value in (-1,float('nan'),float('inf')):
   with self.subTest(value=value):
    with self.assertRaises(ValueError):soak_scenario(self.p,value)
 def test_empty_target_rejected(self):
  self.p['qa_plan']['soak']={'seconds':0}
  with self.assertRaises(ValueError):soak_scenario(self.p)
 def test_bounded_memory_after_many_states(self):
  s=soak_scenario(self.p,3600);s['memory_limit']=32;a=Agent(self.p,s,1)
  for i in range(5000):a.choose({'position':i,'turn':i})
  self.assertEqual(a.total_actions,5000)
  for value in (a.history,a.memory,a.visited,a.failed,a.success):self.assertLessEqual(len(value),32)
 def test_budget_uses_total_instead_of_retained_actions(self):
  s=soak_scenario(self.p,3600);s.update(memory_limit=16,action_budget=30);a=Agent(self.p,s,1)
  for i in range(30):a.choose({'turn':i})
  self.assertTrue(a.exhausted());self.assertEqual(len(a.history),16)
 def test_duplicate_fault_ids_rejected(self):
  self.p['qa_plan']['faults'].append(self.p['qa_plan']['faults'][0])
  with self.assertRaisesRegex(ValueError,'DUPLICATE'):validate_campaigns(self.p)
 def test_empty_regression_fields_rejected(self):
  self.p['qa_plan']['regression']['state_fields']=[]
  with self.assertRaisesRegex(ValueError,'FIELDS'):validate_campaigns(self.p)
 def test_invalid_visual_masks_rejected(self):
  self.p['qa_plan']['regression']['visual_masks']=[[0,0,2,1]]
  with self.assertRaisesRegex(ValueError,'MASK'):validate_campaigns(self.p)
class RegressionTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.p=read_json(ROOT/'VALIDATION_PROFILES/rfb_grid.json');self.p['qa_plan']['regression']['performance_limits']={'startup_seconds':{'ratio':1.5,'absolute_tolerance':.1}};self.image=self.root/'image.bmp';self.bmp(self.image,(10,20,30));self.state={'goal':True,'score':0,'turn':1};self.base=self.root/'baseline_exports'/self.p['game_id']/'goal';self.data=export_baseline(self.base,self.p,'goal',7,self.state,['confirm'],[self.state],{'startup_seconds':1},self.image,'RECORDED_RUN_NOT_AUTO_APPROVED')
 def tearDown(self):self.tmp.cleanup()
 def bmp(self,path,color):
  data=bytes(color)*48*48;path.write_bytes(struct.pack('<2sIHHI',b'BM',54+len(data),0,0,54)+struct.pack('<IiiHHIIiiII',40,48,48,1,24,0,len(data),0,0,0,0)+data)
 def check(self,**changes):
  args=dict(baseline=self.data,p=self.p,state=self.state,actions=['confirm'],transitions=[self.state],performance={'startup_seconds':1},left_image=self.base/'screen.bmp',right_image=self.image);args.update(changes);return compare(**args)
 def test_roundtrip(self):self.assertEqual(load_baseline(self.base,self.p,'goal',7)['scope'],'RECORDED_RUN_NOT_AUTO_APPROVED')
 def test_three_axes_pass(self):self.assertEqual([r[1] for r in self.check()],['PASS']*3)
 def test_behavior_change_fails(self):self.assertEqual(self.check(state=dict(self.state,score=1))[0][2],'BEHAVIORAL_REGRESSION')
 def test_transition_change_fails(self):self.assertEqual(self.check(transitions=[dict(self.state,turn=0)])[0][1],'FAIL')
 def test_action_change_fails(self):self.assertEqual(self.check(actions=['other'])[0][1],'FAIL')
 def test_visual_change_fails(self):self.bmp(self.image,(200,100,100));self.assertEqual(self.check()[1][2],'VISUAL_REGRESSION')
 def test_resource_change_fails(self):self.assertEqual(self.check(performance={'startup_seconds':3})[2][2],'PERFORMANCE_REGRESSION')
 def test_new_game_version_can_use_old_baseline(self):
  p=copy.deepcopy(self.p);p['game_version']='2.0';self.assertEqual(load_baseline(self.base,p,'goal',7)['game_version'],self.p['game_version'])
 def test_seed_and_profile_identity_checked(self):
  for seed,game in [(8,self.p['game_id']),(7,'other')]:
   with self.subTest(seed=seed,game=game):
    p=copy.deepcopy(self.p);p['game_id']=game
    with self.assertRaisesRegex(ValueError,'IDENTITY'):load_baseline(self.base,p,'goal',seed)
 def test_fields_must_be_compatible(self):
  self.p['qa_plan']['regression']['state_fields']=['goal']
  with self.assertRaisesRegex(ValueError,'FIELDS'):load_baseline(self.base,self.p,'goal',7)
 def test_hash_tampering_rejected(self):
  (self.base/'screen.bmp').write_bytes(b'changed')
  with self.assertRaisesRegex(ValueError,'HASH'):load_baseline(self.base,self.p,'goal',7)
 def test_schema_mismatch_rejected(self):
  write_json(self.base/'bundle.json',{'schema_version':999})
  with self.assertRaisesRegex(ValueError,'SCHEMA'):load_baseline(self.base,self.p,'goal',7)
 def test_missing_metric_cannot_pass(self):
  with self.assertRaisesRegex(ValueError,'METRIC'):self.check(performance={})
 def test_missing_state_cannot_pass(self):
  with self.assertRaisesRegex(ValueError,'FIELD'):self.check(state={'goal':True})
 def test_whole_image_cannot_be_masked(self):
  with self.assertRaisesRegex(ValueError,'ALL_PIXELS'):masked_distance(self.image,self.image,[[0,0,1,1]])
 def test_previous_result_zip_is_self_contained(self):
  package=self.root/'previous.zip'
  with zipfile.ZipFile(package,'w') as z:
   for p in self.base.rglob('*'):
    if p.is_file():z.write(p,p.relative_to(self.root))
  imported=import_baseline(package,self.root/'new');shutil.rmtree(self.base);self.assertTrue(load_baseline(imported/self.p['game_id']/'goal',self.p,'goal',7))
 def test_import_cannot_escape(self):
  package=self.root/'bad.zip'
  with zipfile.ZipFile(package,'w') as z:z.writestr('baseline_exports/../../escape','bad')
  with self.assertRaises(ValueError):import_baseline(package,self.root/'new')
 def test_no_automatic_approval(self):self.assertFalse(self.data['human_approved'])
class RuntimeTests(unittest.TestCase):
 def test_result_zip_replaces_only_after_crc_validation(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp)/'run';p.mkdir();(p/'result.json').write_text('{}');(p/'RESULT_FOR_CHATGPT.zip').write_bytes(b'partial');result_zip(p)
   with zipfile.ZipFile(p/'RESULT_FOR_CHATGPT.zip') as z:self.assertIsNone(z.testzip());self.assertEqual(z.namelist(),['result.json'])
   self.assertEqual(list(Path(tmp).glob('*.tmp.zip')),[])
 @unittest.skipIf(os.name=='nt','Linux namespace-specific monitor')
 def test_real_child_process_monitor(self):
  from backends import ProcessSupervisor
  s=ProcessSupervisor()
  with tempfile.TemporaryFile() as log:
   try:s.start([sys.executable,'-c','import time;time.sleep(3)'],'.',log,log);time.sleep(.05);self.assertGreater(s.metrics().get('ram',0),0)
   finally:s.stop()
 @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'),'Host encoder unavailable')
 def test_streaming_video_needs_no_raw_frame_directory(self):
  from stream_video import PipeFrameRecorder
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp);image=p/'frame.bmp';data=bytes([10,20,30])*48*48;image.write_bytes(struct.pack('<2sIHHI',b'BM',54+len(data),0,0,54)+struct.pack('<IiiHHIIiiII',40,48,48,1,24,0,len(data),0,0,0,0)+data);rec=PipeFrameRecorder(shutil.which('ffmpeg'),shutil.which('ffprobe'),p/'video.mp4')
   try:
    for _ in range(4):rec.frame(image);time.sleep(.35)
    rec.finish();m=read_json(p/'video.timeline.json');self.assertEqual(m['raw_frames_retained'],0);self.assertGreater(m['duration'],.8);self.assertFalse((p/'video_frames').exists())
   finally:rec.cancel()

class ResourceEvidenceTests(unittest.TestCase):
 def evaluate(self,metrics):
  with tempfile.TemporaryDirectory() as tmp:
   s=Session(ROOT,Evidence(tmp,'resource'),None,read_json(ROOT/'VALIDATION_PROFILES/rfb_grid.json'));s.metrics=metrics;s.resource_analysis();return s.results[0]
 def test_samples_across_different_pids_cannot_be_combined(self):self.assertEqual(self.evaluate([{'pid':i,'ram':100} for i in range(20)])['status'],'INCONCLUSIVE')
 def test_unavailable_metrics_cannot_pass(self):self.assertEqual(self.evaluate([{'pid':1,'metrics_unavailable':True} for _ in range(20)])['status'],'INCONCLUSIVE')
 def test_stable_single_pid_has_observed_evidence(self):self.assertEqual(self.evaluate([{'pid':1,'ram':100,'handles':3} for _ in range(20)])['status'],'PASS')
 def test_handle_growth_detected_without_ram_growth(self):self.assertEqual(self.evaluate([{'pid':1,'ram':100,'handles':i*30} for i in range(20)])['reason_code'],'LEAK_CANDIDATE')
