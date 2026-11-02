import sys,tempfile,unittest,json,zipfile,struct,os,shutil
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from common import *
from profile import condition,load
from agents import Agent,StallDetector
from adapters import Navigation,image_features,image_distance
from release_manifest import create
ROOT=Path(__file__).resolve().parents[1]
class CoreTests(unittest.TestCase):
    def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.d=Path(self.tmp.name)
    def tearDown(self):self.tmp.cleanup()
    def fixture(self):return load(ROOT,ROOT/'PROFILES/fixture_grid.json')
    def test_profiles_validate(self):
        for p in (ROOT/'PROFILES').glob('*.json'):self.assertTrue(load(ROOT,p)['actions'])
    def test_schema_rejects_future(self):
        p=self.fixture();p['schema_version']=99;write_json(self.d/'p.json',p)
        with self.assertRaisesRegex(ValueError,'INCOMPATIBLE'):load(ROOT,self.d/'p.json')
    def test_condition_missing_is_not_success(self):self.assertFalse(condition({},dict(field='hp',op='eq',value=0)))
    def test_nested_numeric(self):self.assertTrue(condition({'pos':{'x':3}},dict(field='pos.x',op='ge',value=2)))
    def test_wrong_numeric_type_is_false(self):self.assertFalse(condition({'hp':'x'},dict(field='hp',op='gt',value=1)))
    def test_path_escape(self):
        with self.assertRaises(ValueError):inside(self.d,'../unsafe')
    def test_zip_rejects_traversal(self):
        with zipfile.ZipFile(self.d/'z.zip','w') as z:z.writestr('../bad','x')
        with self.assertRaises(ValueError):extract_zip(self.d/'z.zip',self.d/'out')
    def test_zip_rejects_windows_drive(self):
        with zipfile.ZipFile(self.d/'z.zip','w') as z:z.writestr('C:/bad','x')
        with self.assertRaises(ValueError):extract_zip(self.d/'z.zip',self.d/'out')
    def test_hash_changed(self):
        p=self.d/'data';p.write_text('a');a=digest(p);p.write_text('b');self.assertNotEqual(a,digest(p))
    def test_integrity_detects_extra_file(self):
        (self.d/'CORE').mkdir();(self.d/'CORE/a.py').write_text('a=1');create(self.d);self.assertEqual(verify_core(self.d),[]);(self.d/'CORE/b.py').write_text('b=1');self.assertTrue(verify_core(self.d))
    def test_integrity_detects_corruption(self):
        (self.d/'CORE').mkdir();(self.d/'CORE/a.py').write_text('a=1');create(self.d);(self.d/'CORE/a.py').write_text('a=2');self.assertTrue(verify_core(self.d))
    def test_capability_cannot_disappear(self):
        (self.d/'CORE').mkdir();create(self.d);m=read_json(self.d/'core_manifest.json');m['capabilities'].pop();write_json(self.d/'core_manifest.json',m);self.assertIn('CAPABILITY_REGRESSION',verify_core(self.d))
    def test_no_evidence_no_pass(self):self.assertEqual(Evidence(self.d,'run').result('x','PASS','ok')['status'],'HARNESS_ERROR')
    def test_missing_evidence_no_pass(self):self.assertEqual(Evidence(self.d,'run').result('x','PASS','ok',['missing'])['status'],'HARNESS_ERROR')
    def test_real_evidence_can_pass(self):
        (self.d/'x').write_text('observed');self.assertEqual(Evidence(self.d,'run').result('x','PASS','ok',['x'])['status'],'PASS')
    def test_harness_error_precedence(self):self.assertEqual(overall([{'status':'FAIL'},{'status':'HARNESS_ERROR'}]),'HARNESS_ERROR')
    def test_no_results_not_run(self):self.assertEqual(overall([]),'NOT_RUN')
    def test_random_seed_reproducible(self):
        p=self.fixture();s={'agent':'Random'};a=Agent(p,s,887);b=Agent(p,s,887)
        self.assertEqual([a.choose({'turn':i}) for i in range(50)],[b.choose({'turn':i}) for i in range(50)])
    def test_random_forbidden_never_used(self):
        p=self.fixture();p['forbidden_actions']=['confirm','move_right'];a=Agent(p,{'agent':'Random'},4)
        self.assertFalse(set(a.choose({'turn':i}) for i in range(50))&set(p['forbidden_actions']))
    def test_smoke_sequence(self):
        a=Agent(self.fixture(),{'agent':'Smoke','sequence':['cancel','confirm']},1);self.assertEqual(a.choose({}),'cancel');self.assertEqual(a.choose({}),'confirm')
    def test_goal_falls_back(self):
        a=Agent(self.fixture(),{'agent':'Goal'},1);a.choose({});self.assertEqual(a.mode,'Explorer')
    def test_loop_changes_strategy(self):
        a=Agent(self.fixture(),{'agent':'Goal'},1);a.history=['confirm']*8;a.visited[a.signature({})]=3;a.choose({});self.assertEqual(a.mode,'Explorer');self.assertEqual(a.loops,1)
    def test_explorer_visits_new_actions(self):
        a=Agent(self.fixture(),{'agent':'Explorer'},1);xs=[a.choose({}) for _ in range(5)];self.assertEqual(len(set(xs)),5)
    def test_agent_action_budget(self):
        a=Agent(self.fixture(),{'agent':'Random','action_budget':2},1);a.choose({});a.choose({});self.assertTrue(a.exhausted())
    def test_stall_multiple_signals(self):
        s=StallDetector(3);self.assertIsNone(s.observe(0,'x','screen','a'));self.assertIsNone(s.observe(1,'x','screen','b'));self.assertIsNone(s.observe(2,'x','screen','a'));self.assertEqual(s.observe(3,'x','screen','b'),'SOFTLOCK')
    def test_normal_wait_not_stall(self):
        s=StallDetector(3)
        for i in range(10):self.assertIsNone(s.observe(i,'x','screen','a' if i%2 else 'b',True))
    def test_animated_progress_not_stall(self):
        s=StallDetector(3)
        for i in range(10):self.assertIsNone(s.observe(i,str(i),'screen','a' if i%2 else 'b'))
    def test_stall_detects_animated_unresponsive_bridge(self):
        s=StallDetector(3)
        for i in range(3):self.assertIsNone(s.observe(i,'unchanged',str(i),'a' if i%2 else 'b',reaction=0))
        self.assertEqual(s.observe(3,'unchanged','animated','a',reaction=0),'SOFTLOCK')
    def test_responsive_static_screen_not_softlock(self):
        s=StallDetector(3)
        for i in range(10):self.assertIsNone(s.observe(i,'unchanged','screen','a' if i%2 else 'b',reaction=i))
    def test_navigation_graph(self):self.assertEqual(Navigation.route({'a':['b'],'b':['c']},'a','c'),['a','b','c'])
    def test_navigation_unreachable(self):self.assertEqual(Navigation.route({'a':[]},'a','c'),[])
    def test_hex_neighbors(self):self.assertEqual(len(Navigation.neighbors((0,0),'hex')),6)
    def test_vector_3d(self):self.assertAlmostEqual(sum(x*x for x in Navigation.direction([0,0,0],[2,2,2])),1)
    def bmp(self,path,rgb):
        w,h=4,4;bgr=bytes(reversed(rgb))*w*h;path.write_bytes(struct.pack('<2sIHHI',b'BM',54+len(bgr),0,0,54)+struct.pack('<IiiHHIIiiII',40,w,h,1,24,0,len(bgr),0,0,0,0)+bgr)
    def test_visual_comparison_tolerance(self):
        self.bmp(self.d/'a.bmp',(30,40,50));self.bmp(self.d/'b.bmp',(31,41,51));self.assertLess(image_distance(image_features(self.d/'a.bmp'),image_features(self.d/'b.bmp')),.01)
    def test_visual_change_detected(self):
        self.bmp(self.d/'a.bmp',(0,0,0));self.bmp(self.d/'b.bmp',(255,255,255));self.assertEqual(image_distance(image_features(self.d/'a.bmp'),image_features(self.d/'b.bmp')),1)
    def test_evidence_zip_includes_full_video_excludes_work(self):
        (self.d/'FULL_EVIDENCE').mkdir();(self.d/'FULL_EVIDENCE/video.mp4').write_bytes(b'video');(self.d/'WORK').mkdir();(self.d/'WORK/private').write_text('test');(self.d/'result.json').write_text('{}');result_zip(self.d)
        with zipfile.ZipFile(self.d/'RESULT_FOR_CHATGPT.zip') as z:self.assertEqual(z.namelist(),['FULL_EVIDENCE/video.mp4','result.json'])
    def test_evidence_manifest_hashes_and_event_link(self):
        e=Evidence(self.d,'r');(self.d/'a').write_text('evidence');event=e.event('screenshot','case',file='a');m=e.manifest();a=next(x for x in m if x['file']=='a');self.assertIn(event['event_id'],a['event_ids']);self.assertEqual(a['sha256'],digest(self.d/'a'))
    def test_report_escapes_html(self):
        report(self.d,{'run_id':'<script>','overall':'FAIL','results':[]});self.assertNotIn('<script>',(self.d/'report.html').read_text())
    @unittest.skipIf(os.name=='nt','Non-Windows negative gate test')
    def test_non_windows_never_claims_e2e_pass(self):
        import subprocess
        shutil.copytree(ROOT/'CORE',self.d/'CORE',ignore=shutil.ignore_patterns('__pycache__'));create(self.d)
        write_json(self.d/'QA_TARGETS.json',{'schema_version':1,'baseline':None,'targets':[{'id':'dummy','profile':'PROFILES/dummy.json','requirements':[]}]})
        r=subprocess.run([sys.executable,'-B',str(self.d/'CORE/runner.py'),'--root',str(self.d)],capture_output=True,text=True,timeout=20)
        self.assertEqual(r.returncode,2,r.stderr)
        latest=read_json(self.d/'RESULTS/latest.json');p=Path(latest['result_zip']);self.assertTrue(p.is_file())
        with zipfile.ZipFile(p) as z:data=json.loads(z.read('result.json'));self.assertEqual(data['overall'],'HARNESS_ERROR');self.assertFalse(data['completion_certified']);self.assertTrue(any(x['reason_code']=='WINDOWS_DESKTOP_REQUIRED' for x in data['results']))
    def test_optional_not_run_does_not_poison_pass(self):
        self.assertEqual(overall([{'status':'PASS','gate':'REQUIRED'},{'status':'NOT_RUN','gate':'OPTIONAL'}]),'PASS')
    def test_required_not_run_blocks_acceptance(self):
        self.assertEqual(overall([{'status':'PASS','gate':'REQUIRED'},{'status':'NOT_RUN','gate':'REQUIRED'}]),'HARNESS_ERROR')
    def test_certification_is_reachable_and_evidence_required(self):
        from common import certify
        rows=[{'test_case':'real_e2e','status':'PASS','evidence':['video.mp4']}]
        self.assertTrue(certify(rows,['real_e2e'],'0.2',True));self.assertFalse(certify(rows,['missing'],'0.2',True));self.assertFalse(certify(rows,['real_e2e'],'0.2',False))
    def test_unknown_status_rejected(self):
        with self.assertRaises(ValueError):Evidence(self.d,'r').result('a','OK','reason')
if __name__=='__main__':unittest.main(verbosity=2)
