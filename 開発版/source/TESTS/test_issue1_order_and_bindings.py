import hashlib,json,sys,tempfile,unittest,zipfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from common import Evidence,write_json,result_zip,digest
from capability_contract import CapabilityContract
from target_identity import bind_target,check_baseline_reuse,check_result_binding,validate_bound_result_zip,validate_latest_pointer,load_bindings
from contracts import profile_plan
from regression import export_baseline,load_baseline
from tools import Tools
class OrderAndBindingTests(unittest.TestCase):
    def setup_root(self,root):
        (root/'PROFILES').mkdir(parents=True);(root/'PAYLOAD').mkdir();payload=root/'PAYLOAD/node.zip'
        with zipfile.ZipFile(payload,'w') as z:z.writestr(zipfile.ZipInfo('node.exe',(2020,1,1,0,0,0)),b'deterministic-runtime')
        write_json(root/'tool_manifest.json',[{'id':'node','file':'node.zip','size':payload.stat().st_size,'sha256':digest(payload),'executable':'node.exe'}]);write_json(root/'capability_contract.json',{'mandatory_capabilities':[{'id':'game_launch','required':True},{'id':'save_load','required':True}]});profiles={};entries={}
        for name in ('A','B'):
            (root/name).mkdir();(root/name/'game.bin').write_text(name)
            p={'game_id':name,'game_version':'1','profile_version':'1','prototype_type':'logic','actions':{'go':{}},'goals':[{'id':'win','field':'value','op':'eq','value':1}],'scenarios':[{'id':'goal','agent':'Goal','goal':'win'}],'source':name,'qa_plan':{'faults_enabled':False,'regression':{'scenario':'goal','state_fields':['value']}}}
            profiles[name]=p;write_json(root/'PROFILES'/(name+'.json'),p);entries[name]={'id':name,'profile':'PROFILES/'+name+'.json','source':name,'requirements':['goal'],'required_capabilities':['game_launch'] if name=='B' else []}
        return profiles,entries
    def archive(self,root,identity,run_id='current',key='A'):
        e=Evidence(root/'RESULTS'/key,run_id);(e.root/'proof').write_text('fixture');write_json(e.root/'result.json',{'run_id':run_id,'overall':'PASS','results':[e.result('case','PASS','FIXTURE',['proof'])],'target_identity':{key:identity}});e.manifest();return result_zip(e.root,True)
    def execute_order(self,root,order):
        profiles,entries=self.setup_root(root);out={'contract':CapabilityContract.freeze(root,[entries[k] for k in order],frozen_at='fixed').to_dict(),'profiles':{}}
        for key in order:
            p=profiles[key];identity=bind_target(root,entries[key],p,observed_at='fixed');e=Evidence(root/'tool_evidence'/key,key);tools=Tools(root,e);tools.prepare(required=['node']);image=root/'image.bmp';image.write_bytes(b'image');base=root/'BASELINES'/key
            export_baseline(base,p,'goal',1,{'value':1},['go'],[{'value':1}],{},image,'FIXTURE',identity);loaded=load_baseline(base,p,'goal',1,identity,root);archive=self.archive(root,identity.to_dict(),key+'-run',key);write_json(root/'RESULTS/latest.json',{'run_id':key+'-run','result_zip':str(archive)})
            valid=validate_latest_pointer(root/'RESULTS','latest.json',key+'-run',{key:identity});out['profiles'][key]={'required':sorted(r['test_case'] for r in profile_plan(p,{'faults':False}) if r['gate']=='REQUIRED'),'binding':identity.to_dict(),'baseline':loaded,'cache':json.loads((root/'RUNTIME/node/extracted.json').read_text()),'runtime':digest(root/'RUNTIME/node/node.exe'),'latest_bound_to_profile':valid==archive,'tool_statuses':[(r['test_case'],r['status'],r['gate']) for r in tools.results]}
        return out
    def test_reverse_order_required_binding_baseline_cache_runtime_latest(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);self.assertEqual(self.execute_order(root/'AB',['A','B']),self.execute_order(root/'BA',['B','A']))
    def test_stale_latest_foreign_result_and_forged_target_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);profiles,entries=self.setup_root(root);identity=bind_target(root,entries['A'],profiles['A']);archive=self.archive(root,identity.to_dict());write_json(root/'RESULTS/latest.json',{'run_id':'old','result_zip':str(archive)})
            with self.assertRaisesRegex(ValueError,'LATEST_RUN_ID_MISMATCH'):validate_latest_pointer(root/'RESULTS','latest.json','current',{'A':identity})
            with self.assertRaisesRegex(OSError,'RESULT_RUN_ID_MISMATCH'):validate_bound_result_zip(archive,'another',{'A':identity})
            forged=identity.to_dict();forged['fingerprint']='0'*64;archive=self.archive(root,forged)
            with self.assertRaisesRegex(ValueError,'TARGET_BINDING_REJECTED'):validate_bound_result_zip(archive,'current',{'A':identity})
    def test_target_identity_component_certificate_and_type_injections_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);profiles,entries=self.setup_root(root);identity=bind_target(root,entries['A'],profiles['A'])
            for field,value in [('generation',True),('schema_version',True),('components',{'source_digest':'forged'}),('certifies_real_target',False),('ledger_persisted',False),('target_id','B'),('kind','fixture')]:
                recorded=identity.to_dict();recorded[field]=value;self.assertTrue(check_result_binding(identity,recorded),(field,value))
    def test_boolean_ledger_generation_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);profiles,entries=self.setup_root(root);bind_target(root,entries['A'],profiles['A']);ledger=load_bindings(root);ledger['targets']['A']['history'][0]['generation']=True;write_json(root/'QA_BINDINGS.json',ledger)
            with self.assertRaisesRegex(ValueError,'TARGET_BINDINGS_INVALID'):load_bindings(root)
    def test_a_b_a_stale_baseline_rejected_with_or_without_ledger(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);profiles,entries=self.setup_root(root);first=bind_target(root,entries['A'],profiles['A']);(root/'A/game.bin').write_text('B');bind_target(root,entries['A'],profiles['A']);(root/'A/game.bin').write_text('A');current=bind_target(root,entries['A'],profiles['A'])
            self.assertIn('STALE_BASELINE_LINEAGE_BROKEN',check_baseline_reuse(current,first.to_dict(),root));self.assertIn('BASELINE_LINEAGE_UNVERIFIABLE',check_baseline_reuse(current,first.to_dict()))
    def test_duplicate_baseline_manifest_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);profiles,_=self.setup_root(root);image=root/'image.bmp';image.write_bytes(b'image');base=root/'baseline';export_baseline(base,profiles['A'],'goal',1,{'value':1},[],[],{},image,'FIXTURE');manifest=json.loads((base/'bundle.json').read_text());manifest['files'].append(dict(manifest['files'][0]));write_json(base/'bundle.json',manifest)
            with self.assertRaisesRegex(ValueError,'BASELINE_FILE_SET'):load_baseline(base,profiles['A'],'goal',1)
    def test_goal_policy_required_only_when_requested_by_frozen_contract(self):
        with tempfile.TemporaryDirectory() as td:
            profiles,_=self.setup_root(Path(td));p=profiles['A'];case='A.goal.goal_agent'
            self.assertNotIn(case,[r['test_case'] for r in profile_plan(p,{'faults':False})])
            self.assertIn({'test_case':case,'gate':'REQUIRED'},profile_plan(p,{'faults':False,'required_agents':['Goal']}))
            p['scenarios'][0]['agent']='Random'
            self.assertNotIn(case,[r['test_case'] for r in profile_plan(p,{'faults':False,'required_agents':['Goal']})])
    def test_required_storage_row_frozen_before_execution(self):
        with tempfile.TemporaryDirectory() as td:
            profiles,_=self.setup_root(Path(td));p=profiles['A'];p['save']={'file':'save.json'};p['scenarios'][0]['save_load']=True;p['storage']={'scenarios':[{'id':'restore','feature':'restart_restore','supported':False,'required':True}]}
            self.assertIn({'test_case':'A.goal.storage.restore','gate':'REQUIRED'},profile_plan(p,{'faults':False}))
if __name__=='__main__':unittest.main()
