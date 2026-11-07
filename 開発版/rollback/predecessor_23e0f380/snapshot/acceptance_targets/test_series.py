import copy,json,tempfile,unittest,zipfile
from pathlib import Path
from run_series import compare_records,extract,origin_record

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

if __name__=='__main__':unittest.main()
