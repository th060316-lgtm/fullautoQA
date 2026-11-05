import copy,json,os,sys,tempfile,unittest,zipfile
from pathlib import Path
from run_series import OPERATION_LOG,compare_records,extract,origin_record,run_logged,summarize_execution_environment

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

    def test_controller_marker_is_scoped_to_child_environment(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);log=root/'child.log'
            env=os.environ.copy();env['FULLAUTOQA_AUTOMATED_CONTROLLER']='1'
            parent=os.environ.get('FULLAUTOQA_AUTOMATED_CONTROLLER')
            before=len(OPERATION_LOG)
            code=run_logged(
                [sys.executable,'-c',"import os;print(os.environ.get('FULLAUTOQA_AUTOMATED_CONTROLLER',''))"],
                root,log,timeout=30,env=env)
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

if __name__=='__main__':unittest.main()
