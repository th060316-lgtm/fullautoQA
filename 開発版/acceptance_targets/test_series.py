import copy,json,os,sys,tempfile,unittest,zipfile
from pathlib import Path
from run_series import (OPERATION_LOG,_series_review_payload,compare_records,
                        cross_run_reproducibility,extract,origin_record,run_logged,
                        series_hq_readback,summarize_execution_environment)

class SeriesIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.plan={'series':['A','B','A'],'historical_run_ids':['old']}
        self.frozen={label:{'target_id':label,'game_id':'game'+label,'profile_version':'1','profile_sha256':label*64,'fingerprint':label*64,'origin':{'commit':label}} for label in ('A','B')}
        self.rows=[{'target_key':label,'target':copy.deepcopy(self.frozen[label]),'candidate_sha256':'candidate','start_qa_exit_code':0,'required_nonpass':[],'archive_integrity':'PASS','diagnostic_archive':False,'foreign_target_evidence':False,'run_id':'run'+str(i),'fresh_extraction_id':'fresh'+str(i),'evidence_root':'evidence'+str(i),'execution_root':'root'+str(i)} for i,label in enumerate(self.plan['series'])]

    def result(self):return compare_records(self.rows,self.plan,self.frozen,'candidate')
    def test_clean_aba_is_only_technical_pass(self):
        d=self.result();self.assertEqual(d['technical_series_status'],'PASS');self.assertFalse(d['qa_complete']);self.assertEqual(d['product_acceptance'],'HOLD')
    def test_old_run_reuse_is_rejected(self):
        self.rows[2]['run_id']=self.rows[0]['run_id'];self.assertIn('NON_UNIQUE_RUN_ID',self.result()['failures'])
        self.rows[2]['run_id']='old';self.assertIn('HISTORICAL_RUN_REUSED',self.result()['failures'])
    def test_wrong_candidate_or_target_is_rejected(self):
        self.rows[2]['candidate_sha256']='different';self.rows[2]['target']=self.frozen['B'];d=self.result();self.assertIn('CANDIDATE_IDENTITY_MISMATCH',d['failures']);self.assertTrue(any(x.startswith('TARGET_BINDING_MISMATCH') for x in d['failures']))
    def test_shared_extraction_evidence_and_fresh_id_are_rejected(self):
        for key in ('execution_root','evidence_root','fresh_extraction_id'):
            with self.subTest(key=key):
                rows=copy.deepcopy(self.rows);rows[2][key]=rows[0][key]
                self.assertIn('NON_UNIQUE_'+key.upper(),compare_records(rows,self.plan,self.frozen,'candidate')['failures'])
    def test_required_error_or_foreign_evidence_cannot_pass(self):
        self.rows[1]['required_nonpass']=[{'status':'NOT_RUN'}];self.rows[2]['foreign_target_evidence']=True
        self.assertEqual(self.result()['technical_series_status'],'FAIL')
    def test_partial_series_fails(self):
        self.rows.pop();self.assertIn('SERIES_INCOMPLETE',self.result()['failures'])
    def test_archive_escape_and_duplicate_spelling_rejected(self):
        for names in (['../escape'],['x','X']):
            with tempfile.TemporaryDirectory() as td:
                archive=Path(td)/'bad.zip'
                with zipfile.ZipFile(archive,'w') as z:
                    for name in names:z.writestr(name,b'bad')
                with self.assertRaises(ValueError):extract(archive,Path(td)/'new')
    def test_extract_refuses_existing_directory(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(ValueError,'NOT_EMPTY'):extract('unused',td)
    def test_origin_names_are_normalized_without_inventing_identity(self):
        value=origin_record({'origin':{'repository':'r','commit':'c','source_tree_sha':'t','source_path':'game'}})
        self.assertEqual(value,{'repository':'r','commit':'c','source_tree':'t','selected_path':'game'})

    def test_cross_run_reproducibility_requires_same_candidate_target_and_distinct_extractions(self):
        def row(run_id, fresh_id, candidate='candidate', fingerprint='A'*64, digest='required-digest'):
            return {
                'run_id':run_id,
                'fresh_extraction_id':fresh_id,
                'target_key':'A',
                'target':{'fingerprint':fingerprint},
                'candidate_sha256':candidate,
                'required_case_digest':digest,
                'required_case_count':3,
                'required_nonpass':[],
            }
        good=cross_run_reproducibility([row('a1','fresh1'),row('a2','fresh2')])
        self.assertTrue(good['status'])
        self.assertEqual(good['scope'],'cross_run_same_target')

        reused=cross_run_reproducibility([row('a1','same'),row('a2','same')])
        self.assertFalse(reused['status'])
        self.assertIn('FRESH_EXTRACTION_NOT_INDEPENDENT',reused['reasons'])

        different_candidate=cross_run_reproducibility(
            [row('a1','fresh1',candidate='c1'),row('a2','fresh2',candidate='c2')])
        self.assertFalse(different_candidate['status'])
        self.assertIn('CANDIDATE_IDENTITY_DIVERGED',different_candidate['reasons'])

        different_target=cross_run_reproducibility(
            [row('a1','fresh1',fingerprint='A'*64),row('a2','fresh2',fingerprint='B'*64)])
        self.assertFalse(different_target['status'])
        self.assertIn('TARGET_IDENTITY_DIVERGED',different_target['reasons'])

    def test_controller_marker_is_scoped_to_child_environment(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);log=root/'child.log'
            env=os.environ.copy();env['FULLAUTOQA_AUTOMATED_CONTROLLER']='1'
            parent=os.environ.get('FULLAUTOQA_AUTOMATED_CONTROLLER')
            before=len(OPERATION_LOG)
            core_path=str(Path(__file__).resolve().parents[1]/'source'/'CORE')
            inserted=core_path not in sys.path
            if inserted:sys.path.insert(0,core_path)
            try:
                code=run_logged(
                    [sys.executable,'-c',"import os;print(os.environ.get('FULLAUTOQA_AUTOMATED_CONTROLLER',''))"],
                    root,log,timeout=30,env=env)
            finally:
                if inserted:sys.path.remove(core_path)
            self.assertEqual(code,0)
            self.assertEqual(log.read_text(encoding='utf-8').strip(),'1')
            self.assertEqual(os.environ.get('FULLAUTOQA_AUTOMATED_CONTROLLER'),parent)
            self.assertTrue(OPERATION_LOG[before]['automated_controller'])

    def test_series_environment_requires_all_runs_for_offline_and_nonadmin(self):
        plan={'series':['A','B','A']}
        obs={'admin_status':'STANDARD_USER',
             'network_observation':{'status':'MEASURED','up_adapter_count':0},
             'automated_controller_marker':True}
        records=[{'environment_observation':copy.deepcopy(obs)} for _ in range(3)]
        data=summarize_execution_environment(records,plan,{'os':'nt'})
        self.assertEqual(data['local_windows_offline'],'NO_UP_NON_LOOPBACK_INTERFACES_OBSERVED')
        self.assertEqual(data['non_admin_series'],'STANDARD_USER_ALL_RUNS')
        self.assertEqual(data['controller_only_series'],'AUTOMATED_CONTROLLER_ALL_RUNS')
        records[1]['environment_observation']['network_observation']['up_adapter_count']=1
        data=summarize_execution_environment(records,plan,{'os':'nt'})
        self.assertEqual(data['local_windows_offline'],'NOT_VERIFIED')

    def test_partial_series_never_claims_environment_completion(self):
        plan={'series':['A','B','A']}
        records=[{'environment_observation':{
            'admin_status':'STANDARD_USER',
            'network_observation':{'status':'MEASURED','up_adapter_count':0},
            'automated_controller_marker':True}}]
        data=summarize_execution_environment(records,plan,{'os':'nt'})
        self.assertEqual(data['local_windows_offline'],'NOT_VERIFIED')
        self.assertEqual(data['non_admin_series'],'NOT_VERIFIED')
        self.assertEqual(data['controller_only_series'],'NOT_VERIFIED')

    def test_series_review_manifest_binds_each_review_to_candidate_and_target(self):
        target={'fingerprint':'fp-a','game_id':'gameA'}
        review={'schema_version':1,'reviewer':{'kind':'human','id':'h1'},
                'human_test_performed':True,'sessions':[{'cold_start':True,
                'provenance':{'source':'human'},'phases':{'first_30_seconds':{
                'status':'PASS','evidence':['r.mp4']}}}]}
        manifest={'schema_version':1,'series_reviews':[{
            'index':1,'target_key':'A','candidate_sha256':'candidate',
            'target_fingerprint':'fp-a','game_id':'gameA','review':review}]}
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'reviews.json';path.write_text(json.dumps(manifest),encoding='utf-8')
            payload=_series_review_payload(path,1,'A','candidate',target)
            self.assertEqual(payload['series_binding']['target_key'],'A')
            with self.assertRaisesRegex(ValueError,'CANDIDATE_MISMATCH'):
                _series_review_payload(path,1,'A','other',target)
            self.assertIsNone(
                _series_review_payload(path,2,'B','candidate',
                                       {'fingerprint':'fp-b','game_id':'gameB'}))
            manifest['series_reviews'].append(dict(manifest['series_reviews'][0]))
            path.write_text(json.dumps(manifest),encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'BINDING_AMBIGUOUS'):
                _series_review_payload(path,1,'A','candidate',target)

    def test_series_hq_requires_every_run_not_only_the_last(self):
        def management(fp,offline=True):
            return {'evidence_kind':'real_game','measurements':{
                'cpu_percent':{'value':1,'unit':'percent'},'ram_mb':{'value':1,'unit':'mb'},
                'handles':{'value':1,'unit':'count'},'runtime_seconds':{'value':1,'unit':'seconds'},
                'disk_bytes':{'value':1,'unit':'bytes'},'evidence_bytes':{'value':1,'unit':'bytes'}},
                'performance_regression':False,
                'reproducibility':{'status':True,'scope':'same_run_seed_replay'},
                'fresh_run':True,'target_fingerprint':fp,'one_click':True,
                'manual_intervention':False,'no_admin':True,'offline':offline,
                'integrity':True,'residual_risk':[]}
        def sales(human=True):
            return {'evidence_kind':'real_human' if human else 'model_proxy',
                'reviewer':{'kind':'human' if human else 'model_proxy','id':'h1'},
                'human_test_performed':human,
                'review_evidence_source':'review_evidence/sales_review.json' if human else None,
                'audience_summary':{'status':'GENERATED','entries':[{
                    'what_game':'move','product_description':'move to a goal'}],
                    'description_contract':{'brand_price_independent':True}},
                'audience_summary_evidence':['audience_summary.json'],
                'sessions':[{'cold_start':True,'provenance':{'source':'fresh'},
                    'phases':{
                        'first_30_seconds':{'status':'PASS','evidence':['30.mp4']},
                        'first_5_minutes':{'status':'PASS','evidence':['5.mp4']},
                        'product_shelf_test':{'status':'PASS','evidence':['shelf.png']},
                        'communication_readability':{'status':'PASS','evidence':['notes.txt']}}}]}
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);records=[]
            for index,label in enumerate(['A','B','A'],1):
                slot=root/('Run'+str(index));slot.mkdir()
                fp='fp-a' if label=='A' else 'fp-b'
                with zipfile.ZipFile(slot/'RESULT_FOR_CHATGPT.zip','w') as z:
                    z.writestr('management_evidence.json',json.dumps(management(fp,offline=(index!=2))))
                    z.writestr('sales_evidence.json',json.dumps(sales(human=(index!=2))))
                records.append({'index':index,'target_key':label,'run_id':'run'+str(index),
                    'fresh_extraction_id':'fresh'+str(index),'candidate_sha256':'candidate',
                    'required_case_digest':'same','required_case_count':3,'required_nonpass':[],
                    'target':{'fingerprint':fp,'game_id':'game'+label},'evidence_root':str(slot)})
            result=series_hq_readback(records,root,expected_count=3)
            self.assertNotEqual(result['management']['status'],'PASS')
            self.assertNotEqual(result['sales']['status'],'PASS')
            self.assertEqual(len(result['management']['per_run']),3)
            self.assertEqual(len(result['sales']['per_run']),3)
            self.assertEqual(result['human_test'],'NOT_RUN')

    def test_sales_series_requires_each_distinct_target_not_duplicate_a_review(self):
        def management(fp):
            return {'evidence_kind':'real_game','measurements':{
                'cpu_percent':{'value':1,'unit':'percent'},'ram_mb':{'value':1,'unit':'mb'},
                'handles':{'value':1,'unit':'count'},'runtime_seconds':{'value':1,'unit':'seconds'},
                'disk_bytes':{'value':1,'unit':'bytes'},'evidence_bytes':{'value':1,'unit':'bytes'}},
                'performance_regression':False,'fresh_run':True,'target_fingerprint':fp,
                'one_click':True,'manual_intervention':False,'no_admin':True,'offline':True,
                'integrity':True,'residual_risk':[]}
        def sales(human):
            if not human:
                return {'evidence_kind':'model_proxy',
                        'reviewer':{'kind':'model_proxy','id':'auto'},
                        'human_test_performed':False,'sessions':[]}
            return {'evidence_kind':'real_human','reviewer':{'kind':'human','id':'h1'},
                    'human_test_performed':True,
                    'review_evidence_source':'review_evidence/sales_review.json',
                    'audience_summary':{'status':'GENERATED','entries':[{
                        'what_game':'move','product_description':'move to a goal'}],
                        'description_contract':{'brand_price_independent':True}},
                    'audience_summary_evidence':['audience_summary.json'],
                    'sessions':[{'cold_start':True,'provenance':{'source':'fresh'},
                        'phases':{
                            'first_30_seconds':{'status':'PASS','evidence':['30.mp4']},
                            'first_5_minutes':{'status':'PASS','evidence':['5.mp4']},
                            'product_shelf_test':{'status':'PASS','evidence':['shelf.png']},
                            'communication_readability':{'status':'PASS','evidence':['notes.txt']}}}]}
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);records=[]
            for index,label in enumerate(['A','B','A'],1):
                slot=root/('Run'+str(index));slot.mkdir()
                fp='fp-a' if label=='A' else 'fp-b'
                # A1 and B are reviewed; A3 is intentionally automated-only.
                human=index in (1,2)
                with zipfile.ZipFile(slot/'RESULT_FOR_CHATGPT.zip','w') as z:
                    z.writestr('management_evidence.json',json.dumps(management(fp)))
                    z.writestr('sales_evidence.json',json.dumps(sales(human)))
                records.append({'index':index,'target_key':label,'run_id':'run'+str(index),
                    'fresh_extraction_id':'fresh'+str(index),'candidate_sha256':'candidate',
                    'required_case_digest':'same','required_case_count':3,'required_nonpass':[],
                    'target':{'fingerprint':fp,'game_id':'game'+label},'evidence_root':str(slot)})
            result=series_hq_readback(records,root,expected_count=3)
            self.assertEqual(result['sales']['status'],'PASS')
            self.assertEqual(result['human_test'],'PASS')
            self.assertEqual(
                {row['target_key']:row['status'] for row in result['sales']['per_target']},
                {'A':'PASS','B':'PASS'})
            self.assertEqual(result['sales']['per_target'][0]['reviewed_run_ids'],['run1'])

if __name__=='__main__':unittest.main()
