"""Independent regression checks for audit findings; no Windows APIs are simulated."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'CORE'))
import common
import finalize
from assets import inspect_assets
from contracts import profile_plan, audit_plan


class AuditRegressionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / '日本語 空白' / 'run'
        self.e = common.Evidence(self.root, 'audit-run')

    def data(self):
        (self.root / 'proof.txt').write_text('observed', encoding='utf-8')
        row = self.e.result('game.smoke', 'PASS', 'OBSERVED', ['proof.txt'])
        return dict(run_id=self.e.run_id, overall='PASS', results=[row], completion_certified=True)

    def sealed(self):
        data = self.data()
        common.report(self.root, data)
        self.e.manifest()
        return common.result_zip(self.root, require_manifest=True)

    def profile(self):
        return dict(game_id='example', goals=[dict(id='win')], tests=[],
                    scenarios=[dict(id='smoke', goal='win', agent='Smoke', sequence=['go'])],
                    actions={'go': {}}, qa_plan={'faults_enabled': False})

    def test_manifest_and_zip_use_same_exclusions_and_all_hashes(self):
        for name in ('WORK/a.txt', 'video_frames/a.bmp', 'proof-extra.txt'):
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b'payload')
        archive = self.sealed()
        with zipfile.ZipFile(archive) as z:
            names = set(z.namelist())
            self.assertNotIn('WORK/a.txt', names)
            self.assertNotIn('video_frames/a.bmp', names)
            manifest = json.loads(z.read('evidence_manifest.json'))
            self.assertEqual({r['file'] for r in manifest}, names - {'evidence_manifest.json'})
            for row in manifest:
                content = z.read(row['file'])
                self.assertEqual(len(content), row['size'])
                self.assertEqual(hashlib.sha256(content).hexdigest(), row['sha256'])
            excluded = json.loads(z.read('excluded_work_inventory.json'))
            self.assertTrue({'WORK/a.txt', 'video_frames/a.bmp'} <= {r['file'] for r in excluded})
        common.validate_result_zip(archive, require_manifest=True)

    def test_changed_evidence_after_manifest_is_rejected(self):
        self.sealed()
        (self.root / 'proof.txt').write_text('tampered', encoding='utf-8')
        with self.assertRaisesRegex(OSError, 'EVIDENCE_HASH_MISMATCH'):
            common.result_zip(self.root, require_manifest=True)

    def test_missing_result_reference_is_rejected(self):
        data = self.data()
        data['results'][0]['evidence'].append('missing-proof.txt')
        common.report(self.root, data)
        self.e.manifest()
        with self.assertRaisesRegex(OSError, 'REFERENCED_EVIDENCE_MISSING'):
            common.result_zip(self.root, require_manifest=True)

    def test_event_reference_to_excluded_work_is_rejected(self):
        self.data()
        (self.root / 'WORK').mkdir()
        (self.root / 'WORK/input.txt').write_text('temporary')
        self.e.event('attachment', file='WORK/input.txt')
        common.report(self.root, dict(run_id='audit-run', overall='PASS', results=[]))
        self.e.manifest()
        with self.assertRaisesRegex(OSError, 'REFERENCED_EVIDENCE_MISSING'):
            common.result_zip(self.root, require_manifest=True)

    def test_certify_rejects_duplicate_required_pass(self):
        row = self.data()['results'][0]
        self.assertTrue(common.certify([row], ['game.smoke'], 'v', True))
        self.assertFalse(common.certify([row, copy.deepcopy(row)], ['game.smoke'], 'v', True))

    def test_missing_declared_required_case_stays_required_not_run(self):
        plan = profile_plan(self.profile())
        common.write_json(self.root / 'plan.json', plan)
        rows = []
        audit = audit_plan(self.e, rows, plan, 'plan.json')
        self.assertIn('example.smoke.goal', audit['missing'])
        missing = next(r for r in rows if r['test_case'] == 'example.smoke.goal')
        self.assertEqual((missing['status'], missing['gate']), ('NOT_RUN', 'REQUIRED'))
        self.assertEqual(common.overall(rows), 'HARNESS_ERROR')

    def test_not_run_cannot_downgrade_frozen_required_gate(self):
        common.write_json(self.root / 'plan.json', {})
        rows = [self.e.result('example.smoke.goal', 'NOT_RUN', 'PREREQUISITE_FAILED')]
        audit_plan(self.e, rows, [{'test_case': 'example.smoke.goal', 'gate': 'REQUIRED'}], 'plan.json')
        self.assertEqual(rows[0]['gate'], 'REQUIRED')
        self.assertEqual(common.overall(rows), 'HARNESS_ERROR')

    def test_duplicate_required_case_is_diagnostic_error(self):
        common.write_json(self.root / 'plan.json', {})
        row = self.e.result('example.smoke.goal', 'PASS', 'OK', ['plan.json'])
        rows = [row, copy.deepcopy(row)]
        outcome = audit_plan(self.e, rows, [{'test_case': row['test_case'], 'gate': 'REQUIRED'}], 'plan.json')
        self.assertEqual(outcome['duplicates'], ['example.smoke.goal'])
        self.assertEqual(common.overall(rows), 'HARNESS_ERROR')

    def test_invalid_goal_reference_is_rejected_before_execution(self):
        p = self.profile()
        p['scenarios'][0]['goal'] = 'unknown'
        with self.assertRaisesRegex(ValueError, 'UNKNOWN_SCENARIO_GOAL'):
            profile_plan(p)

    def test_invalid_test_reference_is_rejected_before_execution(self):
        p = self.profile()
        p['tests'] = [dict(id='check', scenario='unknown', expect={'field': 'score'})]
        with self.assertRaisesRegex(ValueError, 'UNKNOWN_TEST_SCENARIO'):
            profile_plan(p)

    def finalize_with_fault(self, stage):
        data = self.data()
        lock = self.root.parent / 'active.lock'
        lock.write_text('owned')
        seen = []
        def broken_cleanup():
            raise OSError('cleanup injection')
        kwargs = dict(cleanup=(broken_cleanup, lambda: seen.append('continued')) if stage == 'cleanup' else (),
                      latest_path=self.root.parent / 'latest.json', lock=lock)
        if stage == 'cleanup':
            outcome = finalize.finalize_run(self.e, data, **kwargs)
            self.assertEqual(seen, ['continued'])
        else:
            target = {'report': 'finalize.report', 'manifest': 'common.Evidence.manifest', 'archive': 'finalize.result_zip'}[stage]
            with patch(target, side_effect=OSError(stage + ' injection')):
                outcome = finalize.finalize_run(self.e, data, **kwargs)
        self.assertFalse(lock.exists())
        self.assertEqual(outcome['overall'], 'HARNESS_ERROR')
        self.assertFalse(data['completion_certified'])
        if outcome['zip_created']:
            self.assertTrue(Path(outcome['result_zip']).is_file())
            common.validate_result_zip(outcome['result_zip'], require_manifest=True)
        else:
            self.assertIsNone(outcome['result_zip'])
            self.assertTrue(outcome['error'])
            self.assertEqual(outcome['residual_path'], str(self.root))
        return outcome

    def test_cleanup_failure_does_not_stop_following_cleanup_or_archive(self):
        self.assertTrue(self.finalize_with_fault('cleanup')['zip_created'])

    def test_report_failure_still_produces_valid_diagnostic_archive(self):
        self.assertTrue(self.finalize_with_fault('report')['zip_created'])

    def test_manifest_persistent_failure_explicitly_reports_no_zip(self):
        self.assertFalse(self.finalize_with_fault('manifest')['zip_created'])

    def test_archive_persistent_failure_explicitly_reports_no_zip(self):
        self.assertFalse(self.finalize_with_fault('archive')['zip_created'])
        local = common.read_json(self.root / 'result.json')
        self.assertEqual(local['overall'], 'HARNESS_ERROR')
        self.assertFalse(local['completion_certified'])
        self.assertIn('Overall Result: HARNESS_ERROR', (self.root / 'SUMMARY.txt').read_text(encoding='utf-8'))
        self.assertIn('HARNESS_ERROR', (self.root / 'report.html').read_text(encoding='utf-8'))
        self.assertNotIn('<h1>PASS</h1>', (self.root / 'report.html').read_text(encoding='utf-8'))

    def test_archive_single_failure_recovers_valid_diagnostic_zip(self):
        original = finalize.result_zip
        count = []
        def fail_once(*args, **kwargs):
            count.append(1)
            if len(count) == 1:
                raise OSError('first publication injection')
            return original(*args, **kwargs)
        with patch('finalize.result_zip', side_effect=fail_once):
            result = finalize.finalize_run(self.e, self.data())
        self.assertTrue(result['zip_created'])
        self.assertTrue(result['diagnostic_archive'])
        common.validate_result_zip(result['result_zip'], require_manifest=True)
        with zipfile.ZipFile(result['result_zip']) as z:
            archived = json.loads(z.read('result.json'))
            self.assertTrue(archived['diagnostic_archive'])
            self.assertEqual(archived['overall'], 'HARNESS_ERROR')
            self.assertFalse(archived['completion_certified'])
            for name in ('result.json', 'SUMMARY.txt', 'report.html'):
                self.assertEqual((self.root / name).read_bytes(), z.read(name))
            self.assertIn('Overall Result: HARNESS_ERROR', z.read('SUMMARY.txt').decode('utf-8'))
            self.assertIn('<h1>HARNESS_ERROR</h1>', z.read('report.html').decode('utf-8'))
        preserved = common.read_json(self.root / 'pre_packaging_result.json')
        self.assertTrue(any(r['test_case'] == 'game.smoke' for r in preserved['results']))
        self.assertEqual(preserved['qa_status_before_finalization'], 'PASS')
        self.assertEqual(common.read_json(self.root / 'result.json')['overall'], result['overall'])

    def test_manifest_single_failure_refreshes_local_and_archived_reports(self):
        original = common.Evidence.manifest
        calls = []
        def fail_once(evidence):
            calls.append(1)
            if len(calls) == 1:
                raise OSError('first manifest injection')
            return original(evidence)
        with patch.object(common.Evidence, 'manifest', new=fail_once):
            result = finalize.finalize_run(self.e, self.data())
        self.assertTrue(result['zip_created'])
        self.assertEqual(result['overall'], 'HARNESS_ERROR')
        common.validate_result_zip(result['result_zip'], require_manifest=True)
        with zipfile.ZipFile(result['result_zip']) as z:
            archived = json.loads(z.read('result.json'))
            self.assertEqual(archived['overall'], 'HARNESS_ERROR')
            self.assertFalse(archived['completion_certified'])
            self.assertTrue(any(r['test_case'] == 'finalization.manifest' for r in archived['results']))
            for name in ('result.json', 'SUMMARY.txt', 'report.html'):
                self.assertEqual((self.root / name).read_bytes(), z.read(name))
            self.assertIn('Overall Result: HARNESS_ERROR', z.read('SUMMARY.txt').decode('utf-8'))
            self.assertIn('<h1>HARNESS_ERROR</h1>', z.read('report.html').decode('utf-8'))

    def test_latest_pointer_failure_does_not_hide_valid_archive(self):
        latest = self.root.parent / 'latest.json'
        original = finalize.write_json
        def reject_pointer(path, value):
            if Path(path) == latest:
                raise OSError('pointer injection')
            return original(path, value)
        with patch('finalize.write_json', side_effect=reject_pointer):
            result = finalize.finalize_run(self.e, self.data(), latest_path=latest)
        self.assertTrue(result['zip_created'])
        self.assertEqual(result['overall'], 'PASS')
        common.validate_result_zip(result['result_zip'], require_manifest=True)

    def test_japanese_path_utf8_and_bom_json_read(self):
        path = self.root / '日本語.json'
        value = {'result_zip': str(self.root / 'RESULT_FOR_CHATGPT.zip')}
        for encoding in ('utf-8', 'utf-8-sig'):
            path.write_text(json.dumps(value, ensure_ascii=False), encoding=encoding)
            self.assertEqual(common.read_json(path), value)

    def test_save_output_string_is_not_required_input_asset(self):
        (self.root / 'game.gd').write_text('var path = ProjectSettings.globalize_path("res://save.json")\n', encoding='utf-8')
        self.assertEqual(inspect_assets(self.root, {'save': {'file': 'save.json'}})['missing'], [])

    def test_true_missing_resource_remains_detected(self):
        (self.root / 'game.gd').write_text('var texture = preload("res://missing.png")\n', encoding='utf-8')
        self.assertEqual(inspect_assets(self.root, {})['missing'], ['missing.png'])

    def test_explicit_required_asset_overrides_runtime_exclusion(self):
        profile = {'save': {'file': 'save.json'}, 'required_assets': ['save.json']}
        self.assertEqual(inspect_assets(self.root, profile)['missing'], ['save.json'])



class RealtimeProfileContracts(unittest.TestCase):
    def test_continuous_fixture_uses_complete_bounded_sequence_and_endpoint(self):
        root=Path(__file__).resolve().parents[1]
        for name,field,limit in [('PROFILES/fixture_realtime.json','position.x',5.0),('VALIDATION_PROFILES/rfb_realtime.json','x',430)]:
            p=common.read_json(root/name);goal=next(s for s in p['scenarios'] if s['id']=='goal');reg=p['qa_plan']['regression']
            self.assertFalse(goal['stop_on_goal']);self.assertEqual(goal['action_budget'],len(goal['sequence']))
            self.assertFalse(reg['compare_trajectory']);self.assertIn(field,reg['state_fields'])
            self.assertTrue({'goal','score','turn'} <= set(reg['state_fields']));self.assertTrue(reg['performance_limits'])
            self.assertTrue(any(t['scenario']=='goal' and t['expect']=={'field':field,'op':'eq','value':limit} for t in p['tests']))
    def test_logic_trajectory_contract_preserved(self):
        root=Path(__file__).resolve().parents[1]
        for folder in ('PROFILES','VALIDATION_PROFILES'):
            for path in (root/folder).glob('*.json'):
                p=common.read_json(path)
                if p['prototype_type']=='logic' and p.get('qa_plan',{}).get('regression'):self.assertTrue(p['qa_plan']['regression']['compare_trajectory'])
    def test_endpoint_mutation_fails_even_without_intermediate_trajectory(self):
        from regression import compare
        from unittest.mock import patch
        p={'qa_plan':{'regression':{'state_fields':['goal','x'],'compare_trajectory':False,'visual_tolerance':.08}}}
        b={'state':{'goal':True,'x':430},'transitions':[],'actions':['right']*7,'performance':{}}
        with patch('regression.masked_distance',return_value=0):
            results=compare(b,p,{'goal':True,'x':429},['right']*7,[],{},'a','b')
        self.assertEqual(results[0][1:3],('FAIL','BEHAVIORAL_REGRESSION'))

if __name__ == '__main__':
    unittest.main()
