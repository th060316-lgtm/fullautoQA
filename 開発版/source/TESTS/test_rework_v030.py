"""Regressions for the three independently confirmed v0.2 defects."""
import unittest,tempfile,sys,json,copy
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from assets import inspect_assets,copy_game
from recording import select_recording,tool_gate,tool_requirements
from common import overall
from plans import fault_plan
ROOT=Path(__file__).resolve().parents[1]
class ReworkTests(unittest.TestCase):
 def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
 def tearDown(self):self.tmp.cleanup()
 def write(self,n,text):p=self.root/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text);return p
 def test_runtime_save_is_not_asset_without_prior_file(self):
  self.write('fixture.gd','var p=ProjectSettings.globalize_path("res://qa_save.json")');self.assertEqual(inspect_assets(self.root,{})['missing'],[])
 def test_explicit_generated_save_reference_is_not_required(self):
  self.write('fixture.gd','var p=load("res://save/state.tres")');self.assertEqual(inspect_assets(self.root,{'generated_paths':['save/']})['missing'],[])
 def test_actual_script_import_is_required(self):
  self.write('fixture.gd','var p=preload("res://absent.png")');self.assertEqual(inspect_assets(self.root,{})['missing'],['absent.png'])
 def test_real_scene_asset_missing_still_fails(self):
  self.write('main.tscn','[ext_resource path="res://absent.tres"]');self.assertEqual(inspect_assets(self.root,{})['missing'],['absent.tres'])
 def test_explicit_required_cannot_be_silently_excluded(self):
  p={'required_assets':['save.json'],'generated_paths':['save.json']};self.assertEqual(inspect_assets(self.root,p)['missing'],['save.json'])
 def test_res_prefix_required_cannot_be_silently_excluded(self):
  p={'required_assets':['res://save.json'],'generated_paths':['save.json']};self.assertEqual(inspect_assets(self.root,p)['missing'],['save.json'])
 def test_copy_excludes_declared_runtime_output_not_game_asset(self):
  self.write('save.json','{}');self.write('texture.dat','asset');dst=self.root/'copied';copy_game(self.root,dst,{'generated_paths':['save.json']});self.assertFalse((dst/'save.json').exists());self.assertTrue((dst/'texture.dat').is_file())
 def test_no_fabricated_assets_for_existing_native_profiles(self):
  for f in (ROOT/'PROFILES').glob('*.json'):
   p=json.loads(f.read_text());self.assertEqual(inspect_assets(ROOT/p['source'],p)['missing'],[])
 def test_optional_tool_failure_cannot_poison_working_video(self):
  rows=[{'test_case':'video','status':'PASS','gate':'REQUIRED'},{'test_case':'OBS','status':'HARNESS_ERROR','gate':tool_gate('anything',{})}];self.assertEqual(overall(rows),'PASS')
 def test_explicit_required_tool_failure_blocks(self):
  requirements=tool_requirements({'required_tools':[{'id':'chosen','reason':'User requested this tool-specific interoperability test'}]});self.assertEqual(overall([{'status':'HARNESS_ERROR','gate':tool_gate('chosen',requirements)}]),'HARNESS_ERROR')
 def test_required_tool_without_reason_rejected(self):
  with self.assertRaises(ValueError):tool_requirements({'required_tools':[{'id':'chosen'}]})
 def test_backend_selection_falls_back_after_unavailable_backend(self):
  class Broken:
   def start(self):raise OSError('UNAVAILABLE')
  class Working:
   def start(self):self.started=True
  selected=select_recording({'first':Broken,'other':Working},self.root,['first','other']);self.assertEqual(selected.backend_name,'other');self.assertTrue(selected.started)
 def test_loss_of_all_video_backends_is_required_failure(self):
  with self.assertRaisesRegex(OSError,'REQUIRED_VIDEO'):select_recording({},self.root,['unknown'])
 def test_fault_plan_does_not_depend_on_game_id(self):
  p=json.loads((ROOT/'VALIDATION_PROFILES/rfb_realtime.json').read_text());a=fault_plan(p);p['game_id']='arbitrary_new_game';self.assertEqual(a,fault_plan(p))
 def test_every_profile_has_own_fault_contract(self):
  for path in (ROOT/'VALIDATION_PROFILES').glob('*.json'):
   p=json.loads(path.read_text());self.assertTrue(fault_plan(p));self.assertTrue(p['qa_plan']['regression']);self.assertTrue(p['qa_plan']['soak'])
 def test_reversed_profile_order_keeps_same_faults(self):
  profiles=[json.loads(p.read_text()) for p in (ROOT/'VALIDATION_PROFILES').glob('*.json')];a={p['game_id']:fault_plan(p) for p in profiles};b={p['game_id']:fault_plan(p) for p in reversed(profiles)};self.assertEqual(a,b)
if __name__=='__main__':unittest.main(verbosity=2)

class RoutingRegressions(unittest.TestCase):
 def test_explicit_native_backend_is_not_routed_to_rfb(self):
  from runner import route
  self.assertEqual(route(['--backend','windows'],ROOT,'nt'),'windows')
 def test_profile_order_does_not_change_backend(self):
  from runner import route
  a=['--profile','VALIDATION_PROFILES/rfb_grid.json','--profile','VALIDATION_PROFILES/rfb_realtime.json'];b=['--profile',a[3],'--profile',a[1]]
  self.assertEqual(route(a,ROOT,'nt'),route(b,ROOT,'nt'))
 def test_explicit_backend_must_match_profile(self):
  from runner import route
  with self.assertRaisesRegex(ValueError,'MISMATCH'):route(['--backend','windows','--profile','VALIDATION_PROFILES/rfb_realtime.json'],ROOT,'nt')
 def test_backend_can_be_selected_by_playable_profile_alone(self):
  from runner import route
  self.assertEqual(route(['--profile','VALIDATION_PROFILES/rfb_realtime.json'],ROOT,'nt'),'rfb')
 def test_runtime_bridge_and_endpoint_are_declared_outputs(self):
  from assets import runtime_paths
  p={'observations':{'bridge':'custom/state.json'},'display':{'endpoint':'custom/channel.json'},'save':{'file':'custom/data.json'}}
  self.assertEqual(runtime_paths(p),['custom/channel.json','custom/data.json','custom/state.json'])
