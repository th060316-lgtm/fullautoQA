from __future__ import annotations
import hashlib, json, os, sys, tempfile, unittest, zipfile
from unittest.mock import patch
from pathlib import Path
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'CORE'))
sys.path.insert(0,str(ROOT/'scripts'))

from common import Evidence,validate_result_zip
from target_intake import validate_profile_structure, tool_ids_from_profile, summarize_discovered
import phase3_run_evidence
from phase3_run_evidence import build_management_evidence, build_sales_evidence
from management_evaluator import evaluate_management
from sales_evaluator import evaluate_sales
from package_integrity import check_core_manifest
from tools import Tools

class Ctx:
    def __init__(self,root,extras):
        self.root=Path(root);self.results=[];self.settings={};self.extras=extras

class Phase3IntegratedTests(unittest.TestCase):
    def profile(self):
        return {
            'game_id':'g','game_version':'1','profile_version':'1','schema_version':1,
            'prototype_type':'playable','launch':{'argv':['{godot}','--path','{work}']},
            'actions':{'confirm':{'inputs':[{'kind':'key','key':'ENTER'}]}},
            'goals':[],'scenarios':[{'id':'s','agent':'Smoke'}],'tests':[],
            'observations':{},'instructions':'x'
        }

    def test_profile_schema_matches_authoritative_shape(self):
        self.assertEqual(validate_profile_structure(self.profile()),[])

    def test_profile_tool_tokens_become_required(self):
        self.assertEqual(tool_ids_from_profile(self.profile(),{'python','godot','ffmpeg'}),['godot'])

    def test_discovery_never_autobinds(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'p.json';p.write_text(json.dumps(self.profile()),encoding='utf-8')
            rows=summarize_discovered([Path(td)])
            self.assertEqual(len(rows),1)
            self.assertFalse(rows[0]['auto_bound'])

    def test_optional_tool_failure_is_optional_gate(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);(root/'PAYLOAD').mkdir();(root/'RUNTIME/python').mkdir(parents=True)
            py=root/'PAYLOAD/python.bin';py.write_bytes(b'python')
            (root/'RUNTIME/python/python.exe').write_bytes(b'exe')
            ff=root/'PAYLOAD/ffmpeg.bin';ff.write_bytes(b'bad')
            manifest=[
                {'id':'python','file':'python.bin','size':len(b'python'),
                 'sha256':hashlib.sha256(b'python').hexdigest(),'executable':'python.exe'},
                {'id':'ffmpeg','file':'ffmpeg.bin','size':999,'sha256':'0'*64,'executable':'ffmpeg.exe'},
            ]
            (root/'tool_manifest.json').write_text(json.dumps(manifest),encoding='utf-8')
            ev=Evidence(root/'E','run')
            obj=Tools(root,ev)
            rows=obj.prepare(required=['python'],optional=['ffmpeg'])
            ffrows=[r for r in rows if r['test_case']=='tool.ffmpeg']
            self.assertTrue(ffrows)
            self.assertEqual(ffrows[-1]['gate'],'OPTIONAL')
            self.assertEqual(ffrows[-1]['status'],'HARNESS_ERROR')
            self.assertNotIn('ffmpeg',obj.required_failures())

    def test_management_adapter_requires_real_launch_before_real_game_kind(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            (root/'g_resources.json').write_text('[]',encoding='utf-8')
            (root/'core_check.json').write_text('{}',encoding='utf-8')
            (root/'launch.bmp').write_bytes(b'x')
            sess=SimpleNamespace(p={'game_id':'g'},metrics=[
                {'pid':1,'ram':100*1024*1024,'handles':20,'cpu_seconds':1.0,'sample_time':10.0},
                {'pid':1,'ram':120*1024*1024,'handles':25,'cpu_seconds':2.0,'sample_time':20.0},
            ])
            prepared={'identity_snapshot':json.dumps({'T':{
                'certifies_real_target':True,'generation':3,'fingerprint':'abc'}})}
            results=[
                {'test_case':'preflight.core','status':'PASS','evidence':['core_check.json'],'gate':'REQUIRED'},
                {'test_case':'g.s.launch','status':'PASS','evidence':['launch.bmp'],'gate':'REQUIRED'},
            ]
            ev=Evidence(root,'run-phase3')
            data=build_management_evidence(e=ev,sessions=[sess],results=results,
                                           run_mode='target',prepared=prepared)
            report=evaluate_management(Ctx(root,{'management_evidence':data}))
            self.assertEqual(report.readback['evidence_kind'],'real_game')
            self.assertTrue(report.readback['evidence_present'])
            self.assertTrue(report.readback['measurements']['ram_mb']['available'])
            self.assertNotEqual(report.reason_code,'MANAGEMENT_EVALUATION_NOT_PERFORMED')
            self.assertTrue((root/'phase3_environment.json').is_file())
            self.assertTrue((root/'phase3_preseal_integrity.json').is_file())

    def test_network_observation_has_no_optional_python_module_dependency(self):
        source=(ROOT/'CORE/phase3_run_evidence.py').read_text(encoding='utf-8')
        self.assertNotIn('import psutil',source)
        fake_os=SimpleNamespace(name='nt',environ={'SystemRoot':r'C:\\Windows'})
        measured=SimpleNamespace(
            returncode=0,
            stdout='[{"name":"Loopback","addresses":["127.0.0.1"]},{"name":"Ethernet","addresses":["192.0.2.10","fe80::1"]}]',
            stderr=''
        )
        with patch.object(phase3_run_evidence,'os',fake_os), \
             patch.object(phase3_run_evidence.Path,'is_file',return_value=True), \
             patch.object(phase3_run_evidence.subprocess,'run',return_value=measured) as run:
            data=phase3_run_evidence._network_adapter_snapshot()
        self.assertEqual(data['status'],'MEASURED')
        self.assertEqual(data['up_adapter_count'],1)
        self.assertEqual(data['up_adapters'],['Ethernet'])
        self.assertEqual(data['method'],'windows_powershell_up_adapters_with_nonloopback_ip')
        self.assertIn('powershell.exe',str(run.call_args.args[0][0]).lower())

        disconnected=SimpleNamespace(returncode=0,stdout='[]',stderr='')
        with patch.object(phase3_run_evidence,'os',fake_os), \
             patch.object(phase3_run_evidence.Path,'is_file',return_value=True), \
             patch.object(phase3_run_evidence.subprocess,'run',return_value=disconnected):
            data=phase3_run_evidence._network_adapter_snapshot()
        self.assertEqual(data['status'],'MEASURED')
        self.assertEqual(data['up_adapter_count'],0)

        failed=SimpleNamespace(returncode=1,stdout='',stderr='query failed')
        with patch.object(phase3_run_evidence,'os',fake_os), \
             patch.object(phase3_run_evidence.Path,'is_file',return_value=True), \
             patch.object(phase3_run_evidence.subprocess,'run',return_value=failed):
            data=phase3_run_evidence._network_adapter_snapshot()
        self.assertEqual(data['status'],'NOT_MEASURED')
        self.assertEqual(data['reason'],'WINDOWS_NETWORK_QUERY_FAILED')

    def test_phase3_measurements_use_shared_transient_safe_tree_scan(self):
        source=(ROOT/'CORE/phase3_run_evidence.py').read_text(encoding='utf-8')
        self.assertIn('tree_size(root, tolerate_excluded_vanish=True)',source)
        self.assertIn('tree_size(root, eligible_only=True, tolerate_excluded_vanish=True)',source)

    def test_management_controller_and_offline_signals_require_observation(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            (root/'core_check.json').write_text('{}',encoding='utf-8')
            (root/'launch.bmp').write_bytes(b'x')
            sess=SimpleNamespace(p={'game_id':'g'},metrics=[])
            prepared={'identity_snapshot':json.dumps({'T':{
                'certifies_real_target':True,'generation':3,'fingerprint':'abc'}})}
            results=[
                {'test_case':'preflight.core','status':'PASS','evidence':['core_check.json'],'gate':'REQUIRED'},
                {'test_case':'g.s.launch','status':'PASS','evidence':['launch.bmp'],'gate':'REQUIRED'},
            ]
            ev=Evidence(root,'run-phase3')
            old=os.environ.get('FULLAUTOQA_AUTOMATED_CONTROLLER')
            os.environ['FULLAUTOQA_AUTOMATED_CONTROLLER']='1'
            try:
                with patch('phase3_run_evidence._network_adapter_snapshot',
                           return_value={'status':'MEASURED','up_adapter_count':0}):
                    data=build_management_evidence(
                        e=ev,sessions=[sess],results=results,run_mode='target',prepared=prepared)
            finally:
                if old is None:os.environ.pop('FULLAUTOQA_AUTOMATED_CONTROLLER',None)
                else:os.environ['FULLAUTOQA_AUTOMATED_CONTROLLER']=old
            self.assertFalse(data['manual_intervention']['status'])
            self.assertTrue(data['offline']['status'])
            environment=json.loads((root/'phase3_environment.json').read_text(encoding='utf-8'))
            self.assertTrue(environment['automated_controller_marker'])
            self.assertEqual(environment['network_observation']['up_adapter_count'],0)

    def test_management_offline_signal_absent_when_adapter_is_up(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            (root/'core_check.json').write_text('{}',encoding='utf-8')
            (root/'launch.bmp').write_bytes(b'x')
            sess=SimpleNamespace(p={'game_id':'g'},metrics=[])
            prepared={'identity_snapshot':json.dumps({'T':{
                'certifies_real_target':True,'generation':3,'fingerprint':'abc'}})}
            results=[
                {'test_case':'preflight.core','status':'PASS','evidence':['core_check.json'],'gate':'REQUIRED'},
                {'test_case':'g.s.launch','status':'PASS','evidence':['launch.bmp'],'gate':'REQUIRED'},
            ]
            ev=Evidence(root,'run-phase3')
            with patch('phase3_run_evidence._network_adapter_snapshot',
                       return_value={'status':'MEASURED','up_adapter_count':1}):
                data=build_management_evidence(
                    e=ev,sessions=[sess],results=results,run_mode='target',prepared=prepared)
            self.assertNotIn('offline',data)

    def test_target_identity_without_launch_is_not_real_game(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            sess=SimpleNamespace(p={'game_id':'g'},metrics=[])
            prepared={'identity_snapshot':json.dumps({'T':{
                'certifies_real_target':True,'generation':3,'fingerprint':'abc'}})}
            ev=Evidence(root,'run-phase3')
            data=build_management_evidence(e=ev,sessions=[sess],results=[],
                                           run_mode='target',prepared=prepared)
            self.assertEqual(data['evidence_kind'],'unknown')

    def test_management_integrity_not_claimed_when_pass_evidence_is_missing(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            (root/'core_check.json').write_text('{}',encoding='utf-8')
            sess=SimpleNamespace(p={'game_id':'g'},metrics=[])
            prepared={'identity_snapshot':json.dumps({'T':{
                'certifies_real_target':True,'generation':3,'fingerprint':'abc'}})}
            results=[
                {'test_case':'preflight.core','status':'PASS','evidence':['core_check.json'],'gate':'REQUIRED'},
                {'test_case':'g.s.launch','status':'PASS','evidence':[],'gate':'REQUIRED'},
            ]
            ev=Evidence(root,'run-phase3')
            data=build_management_evidence(e=ev,sessions=[sess],results=results,
                                           run_mode='target',prepared=prepared)
            self.assertNotIn('integrity',data)
            audit=json.loads((root/'phase3_preseal_integrity.json').read_text(encoding='utf-8'))
            self.assertFalse(audit['ok'])
            self.assertTrue(any(x.startswith('PASS_WITHOUT_EVIDENCE:g.s.launch') for x in audit['problems']))

    def test_sales_recording_is_observation_not_positive_review(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);(root/'FULL_EVIDENCE').mkdir()
            (root/'FULL_EVIDENCE/screen.mp4').write_bytes(b'video')
            sess=SimpleNamespace(p={'game_id':'g'},metrics=[
                {'sample_time':0.0},{'sample_time':310.0}
            ])
            ev=Evidence(root,'run-phase3')
            keys=('FULLAUTOQA_START_QA','FULLAUTOQA_FRESH_EXTRACTION','FULLAUTOQA_FRESH_EXTRACTION_ID')
            old={k:os.environ.get(k) for k in keys}
            os.environ['FULLAUTOQA_START_QA']='1'
            os.environ['FULLAUTOQA_FRESH_EXTRACTION']='1'
            os.environ['FULLAUTOQA_FRESH_EXTRACTION_ID']='build-123'
            try:
                data=build_sales_evidence(e=ev,sessions=[sess],results=[],run_mode='target')
            finally:
                for k,v in old.items():
                    if v is None:os.environ.pop(k,None)
                    else:os.environ[k]=v
            report=evaluate_sales(Ctx(root,{'sales_evidence':data}))
            self.assertEqual(report.readback['reviewer']['kind'],'model_proxy')
            self.assertFalse(report.readback['human_test_performed'])
            self.assertTrue(report.readback['sessions'][0]['cold_start'])
            gates={x['name']:x['status'] for x in report.readback['gate_status']}
            self.assertEqual(gates['sales.first_30_seconds'],'NOT_RUN')
            self.assertEqual(gates['sales.first_5_minutes'],'NOT_RUN')
            self.assertNotEqual(report.status,'PASS')

    def test_fresh_flag_without_marker_identity_is_not_cold_start(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            sess=SimpleNamespace(p={'game_id':'g'},metrics=[])
            ev=Evidence(root,'run-phase3')
            keys=('FULLAUTOQA_FRESH_EXTRACTION','FULLAUTOQA_FRESH_EXTRACTION_ID')
            old={k:os.environ.get(k) for k in keys}
            os.environ['FULLAUTOQA_FRESH_EXTRACTION']='1'
            os.environ.pop('FULLAUTOQA_FRESH_EXTRACTION_ID',None)
            try:
                data=build_sales_evidence(e=ev,sessions=[sess],results=[],run_mode='target')
            finally:
                for k,v in old.items():
                    if v is None:os.environ.pop(k,None)
                    else:os.environ[k]=v
            self.assertFalse(data['sessions'][0]['cold_start'])

    def test_result_zip_expected_run_id_rejects_foreign_archive(self):
        with tempfile.TemporaryDirectory() as td:
            zpath=Path(td)/'r.zip'
            with zipfile.ZipFile(zpath,'w') as z:
                z.writestr('result.json',json.dumps({'run_id':'OTHER','results':[]}))
            with self.assertRaisesRegex(OSError,'RESULT_RUN_ID_MISMATCH'):
                validate_result_zip(zpath,expected_run_id='EXPECTED')

    def test_manifest_schema_fields_are_required(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);(root/'CORE').mkdir()
            f=root/'CORE/x.py';f.write_text('x=1',encoding='utf-8')
            h=hashlib.sha256(f.read_bytes()).hexdigest()
            (root/'core_manifest.json').write_text(json.dumps({
                'files':[{'path':'CORE/x.py','size':f.stat().st_size,'sha256':h}]
            }),encoding='utf-8')
            errs=check_core_manifest(root)
            self.assertIn('CORE_MANIFEST_REQUIRED_FIELD_MISSING:capabilities',errs)

    def test_deferred_tool_preparation_is_a_preparation_pass(self):
        src=(ROOT/'CORE/tools.py').read_text(encoding='utf-8')
        self.assertIn('TOOL_PREPARED_FUNCTIONAL_PROBE_DEFERRED',src)
        self.assertNotIn('"FUNCTIONAL_PROBE_REQUIRED"',src)

    def test_overlay_replaces_all_source_directories_except_runtime_payload_results(self):
        overlay=(ROOT/'scripts/PHASE3_OVERLAY_REBUILD.ps1').read_text(encoding='utf-8')
        self.assertIn("$preserveDirs=@('RUNTIME','PAYLOAD','RESULTS')",overlay)
        self.assertIn("Get-ChildItem -LiteralPath $src -Directory",overlay)
        self.assertIn("$regen=Join-Path $work 'scripts\\PHASE3_REGEN_MANIFEST.ps1'",overlay)
        self.assertIn("$freshIntegrity=Join-Path $freshRoot 'scripts\\package_integrity.py'",overlay)
        self.assertIn("FRESH_INTEGRITY_SCRIPT_MISSING",overlay)
        self.assertNotIn("`n  & $freshPython",overlay)

    def test_overlay_and_regen_contracts(self):
        overlay=(ROOT/'scripts/PHASE3_OVERLAY_REBUILD.ps1').read_text(encoding='utf-8')
        regen=(ROOT/'scripts/PHASE3_REGEN_MANIFEST.ps1').read_text(encoding='utf-8')
        self.assertIn('PHASE3_REGEN_MANIFEST.ps1',overlay)
        self.assertIn('PHASE3_FRESH_EXTRACTION.marker',overlay)
        self.assertIn('CANDIDATE_NAME_INVALID',overlay)
        self.assertIn('OUTPUT_INSIDE_DONOR_TREE',overlay)
        self.assertLess(overlay.index("throw 'OUTPUT_INSIDE_DONOR_TREE'"),
                        overlay.index("New-Item -ItemType Directory -Path $OutputDir"))
        self.assertNotIn('core_version = "phase3-overlay"',overlay)
        self.assertIn("'-B' '-E' '-s'",regen)
        self.assertNotIn("'-I' $release",regen)
        start=(ROOT/'START_QA.cmd').read_text(encoding='utf-8')
        self.assertIn('FULLAUTOQA_FRESH_EXTRACTION',start)
        self.assertIn('FULLAUTOQA_FRESH_EXTRACTION_ID',start)
        self.assertIn('PHASE3_FRESH_EXTRACTION.marker',start)
        self.assertIn('if not "%FULLAUTOQA_FRESH_EXTRACTION_ID%"==""',start)

if __name__=='__main__': unittest.main()
