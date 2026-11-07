"""Phase 1 source integration tests, not Windows or human acceptance.

Reviewed before generation from five internal perspectives (one QA agent):
authority/scope, requirement fidelity, visible status, technical isolation, and
evidence consistency. Temporary targets are deliberately synthetic; successful
packaging does not establish real-game acceptance.
"""
import copy
import contextlib
import hashlib
import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'CORE'))
import common
import coordinator
import finalize
import regression
from target_identity import bind_target, check_result_binding


class PipelinePhase1Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'PROFILES').mkdir()
        (self.root / 'GAME').mkdir()
        (self.root / 'GAME' / 'source.txt').write_text('A', encoding='utf-8')
        self.profile = {'game_id': 'game', 'game_version': '1',
                        'profile_version': '1', 'source': 'GAME',
                        'qa_plan': {'regression': {'state_fields': ['score']}}}
        common.write_json(self.root / 'PROFILES/game.json', self.profile)
        self.entry = {'id': 'game', 'profile': 'PROFILES/game.json',
                      'source': 'GAME', 'requirements': [],
                      'required_capabilities': ['video']}
        self.manifest = {'schema_version': 1, 'targets': [self.entry]}
        self.settings = {'paths': {'target_manifest': 'QA_TARGETS.json'}}
        self.write_manifest()
        self.write_capabilities(['video'])
        self.e = common.Evidence(self.root / 'RESULTS' / 'run', 'pipeline-test')

    def write_manifest(self):
        common.write_json(self.root / 'QA_TARGETS.json', self.manifest)

    def write_capabilities(self, ids, required=True):
        common.write_json(self.root / 'capability_contract.json', {
            'schema_version': 1,
            'mandatory_capabilities': [{'id': name, 'required': required}
                                       for name in ids]})

    def prepare(self):
        return coordinator.prepare_execution(self.root, self.manifest, self.settings)

    def data(self, prepared):
        rows = list(coordinator.preflight_execution(self.e, prepared))
        (self.e.root / 'observed.txt').write_text('observed synthetic target', encoding='utf-8')
        rows.append(self.e.result('game.smoke', 'PASS', 'OBSERVED', ['observed.txt']))
        return {'run_id': self.e.run_id, 'overall': common.overall(rows),
                'results': rows, 'target_qa_certified': True,
                'completion_certified': True, 'future_certified': True}

    def finish(self, prepared, data=None, cleanup=(), run_mode='target'):
        if data is None:
            data = self.data(prepared)
        outcome = finalize.finalize_run(
            self.e, data, cleanup=cleanup,
            execution=coordinator.execution_finalizer(
                self.root, prepared, self.settings, run_mode=run_mode))
        self.assertTrue(outcome['zip_created'], outcome)
        with zipfile.ZipFile(outcome['result_zip']) as archive:
            sealed = json.loads(archive.read('result.json'))
        return data, sealed, outcome

    def assert_blocked(self, sealed):
        self.assertNotEqual(sealed['overall'], 'PASS')
        self.assertFalse(sealed['target_qa_certified'])
        self.assertFalse(sealed['completion_certified'])

    def test_payload_is_present_before_report_manifest_and_zip(self):
        prepared = self.prepare()
        data = self.data(prepared)
        order = []
        original_report = finalize.report
        original_manifest = self.e.manifest
        original_zip = finalize.result_zip

        def checked_report(root, current):
            for key in ('headquarters', 'capability_contract', 'target_identity'):
                self.assertIn(key, current)
            order.append('report')
            return original_report(root, current)

        def checked_manifest():
            local = common.read_json(self.e.root / 'result.json')
            self.assertIn('headquarters', local)
            order.append('manifest')
            return original_manifest()

        def checked_zip(root, *args, **kwargs):
            self.assertEqual(order[-1], 'manifest')
            order.append('zip')
            return original_zip(root, *args, **kwargs)

        with patch.object(finalize, 'report', side_effect=checked_report), \
             patch.object(self.e, 'manifest', side_effect=checked_manifest), \
             patch.object(finalize, 'result_zip', side_effect=checked_zip):
            _, sealed, _ = self.finish(prepared, data)
        self.assertEqual(order, ['report', 'manifest', 'zip'])
        self.assertEqual(sealed['run_id'], self.e.run_id)
        self.assertIn('game.smoke', [r['test_case'] for r in sealed['results']])

    def test_archive_manifest_and_local_final_result_are_identical(self):
        prepared = self.prepare()
        _, sealed, outcome = self.finish(prepared)
        common.validate_result_zip(outcome['result_zip'], require_manifest=True)
        with zipfile.ZipFile(outcome['result_zip']) as archive:
            self.assertEqual(archive.read('result.json'), (self.e.root / 'result.json').read_bytes())
            manifest = json.loads(archive.read('evidence_manifest.json'))
            self.assertEqual({r['file'] for r in manifest},
                             set(archive.namelist()) - {'evidence_manifest.json'})
            for row in manifest:
                content = archive.read(row['file'])
                self.assertEqual(row['size'], len(content))
                self.assertEqual(row['sha256'], hashlib.sha256(content).hexdigest())
        self.assertEqual(sealed, common.read_json(self.e.root / 'result.json'))

    def test_result_is_not_modified_after_zip_is_sealed(self):
        prepared = self.prepare()
        at_seal = {}
        original = finalize.result_zip

        def observe_seal(*args, **kwargs):
            result = original(*args, **kwargs)
            path = self.e.root / 'result.json'
            at_seal.update(content=path.read_bytes(), modified=path.stat().st_mtime_ns)
            return result

        with patch.object(finalize, 'result_zip', side_effect=observe_seal):
            self.finish(prepared)
        path = self.e.root / 'result.json'
        self.assertEqual(path.read_bytes(), at_seal['content'])
        self.assertEqual(path.stat().st_mtime_ns, at_seal['modified'])

    def test_missing_required_capability_is_explicit_before_execution(self):
        self.write_capabilities([])
        prepared = self.prepare()
        before = coordinator.preflight_execution(self.e, prepared)
        self.assertTrue(any(r['status'] != 'PASS' and r.get('gate') == 'REQUIRED'
                            for r in before), before)
        self.assertTrue((self.e.root / 'execution_frozen.json').is_file())

    def test_native_runner_preflight_blocks_before_any_target_session(self):
        # Exercise the real entry/finalization path while replacing only the
        # unavailable complete-candidate integrity input. No Windows claim.
        import windows_runner
        self.write_capabilities([])
        common.write_json(self.root / 'acceptance_manifest.json', self.settings)
        with patch.object(sys, 'argv', ['runner', '--root', str(self.root)]), \
             patch.object(windows_runner, 'verify_core', return_value=[]), \
             patch.object(windows_runner, 'Session') as session, \
             contextlib.redirect_stdout(io.StringIO()):
            exit_code = windows_runner.main()
        session.assert_not_called()
        self.assertEqual(exit_code, 2)
        published = common.read_json(self.root / 'RESULTS/latest.json')
        with zipfile.ZipFile(published['result_zip']) as archive:
            data = json.loads(archive.read('result.json'))
            frozen = json.loads(archive.read('execution_frozen.json'))
        self.assertIn('video', frozen['capability_contract']['required'])
        self.assertTrue(any(r.get('reason_code') == 'REQUIRED_CAPABILITY_UNAVAILABLE'
                            for r in data['results']))
        self.assertTrue(any(r.get('detail') == 'TARGET_PREFLIGHT_BLOCKED'
                            for r in data['results']))
        self.assert_blocked(data)

    def test_frozen_contract_is_independent_of_manifest_and_exported_dict(self):
        prepared = self.prepare()
        snapshot = copy.deepcopy(prepared['contract'].to_dict())
        exported = prepared['contract'].to_dict()
        exported['required'].clear()
        self.entry['required_capabilities'].clear()
        self.entry['requirements'].append('soak')
        self.assertEqual(prepared['contract'].to_dict(), snapshot)

    def test_capability_disappearance_after_execution_blocks_certification(self):
        prepared = self.prepare()
        data = self.data(prepared)
        self.write_capabilities([])
        _, sealed, _ = self.finish(prepared, data)
        self.assert_blocked(sealed)
        self.assertTrue(any('CAPABILITY' in str(r.get('reason_code')) and r['status'] != 'PASS'
                            for r in sealed['results']))

    def test_capability_declaration_deletion_blocks_certification(self):
        prepared = self.prepare()
        data = self.data(prepared)
        (self.root / 'capability_contract.json').unlink()
        _, sealed, _ = self.finish(prepared, data)
        self.assert_blocked(sealed)

    def test_requirement_mutation_after_execution_blocks_certification(self):
        prepared = self.prepare()
        data = self.data(prepared)
        self.entry['requirements'].append('soak')
        self.write_manifest()
        _, sealed, _ = self.finish(prepared, data)
        self.assert_blocked(sealed)

    def test_source_mutation_after_execution_blocks_certification(self):
        prepared = self.prepare()
        data = self.data(prepared)
        (self.root / 'GAME/source.txt').write_text('B', encoding='utf-8')
        _, sealed, _ = self.finish(prepared, data)
        self.assert_blocked(sealed)

    def test_fixture_and_selftest_cannot_certify_real_target(self):
        for kind in ('fixture', 'selftest'):
            with self.subTest(kind=kind):
                self.entry['kind'] = kind
                self.write_manifest()
                prepared = self.prepare()
                _, sealed, _ = self.finish(prepared)
                self.assertFalse(sealed['target_qa_certified'])
                production = next(d for d in sealed['headquarters']['domains']
                                  if d['name'] == 'production')
                self.assertFalse(production['certifies_real_target'])

    def test_management_and_sales_stay_explicit_not_run(self):
        _, sealed, _ = self.finish(self.prepare())
        domains = {d['name']: d for d in sealed['headquarters']['domains']}
        self.assertEqual(domains['management']['status'], 'NOT_RUN')
        self.assertEqual(domains['sales']['status'], 'NOT_RUN')
        self.assertFalse(sealed['headquarters']['accepted'])

    def test_visible_report_separates_processing_from_acceptance(self):
        self.finish(self.prepare())
        for name in ('SUMMARY.txt', 'report.html'):
            with self.subTest(file=name):
                content = (self.e.root / name).read_text(encoding='utf-8')
                for text in ('QA COMPLETE means processing finished.',
                             'Headquarters Overall: NOT_RUN',
                             'management: NOT_RUN', 'sales: NOT_RUN',
                             'Completion certified: False',
                             'Product Acceptance: HOLD', 'Stable: HOLD'):
                    self.assertIn(text, content)

    def test_target_label_cannot_override_selftest_profile_role(self):
        self.entry['kind'] = 'target'
        self.profile['qa_role'] = 'selftest'
        common.write_json(self.root / 'PROFILES/game.json', self.profile)
        self.write_manifest()
        prepared = self.prepare()
        self.assertEqual(prepared['identities']['game'].kind, 'selftest')
        _, sealed, _ = self.finish(prepared)
        self.assertFalse(sealed['target_qa_certified'])
        production = next(d for d in sealed['headquarters']['domains']
                          if d['name'] == 'production')
        self.assertFalse(production['certifies_real_target'])

    def test_finalization_cleanup_failure_revokes_all_certifications(self):
        def fail_cleanup():
            raise RuntimeError('deliberate cleanup failure')
        _, sealed, _ = self.finish(self.prepare(), cleanup=(fail_cleanup,))
        self.assertEqual(sealed['overall'], 'HARNESS_ERROR')
        self.assertFalse(any(v for k, v in sealed.items()
                             if k.endswith('_certified') and isinstance(v, bool)))
        production = next(d for d in sealed['headquarters']['domains']
                          if d['name'] == 'production')
        self.assertEqual(production['status'], 'HARNESS_ERROR')

    def test_multiple_targets_have_distinct_deterministic_serialization(self):
        other = dict(self.entry, id='another', profile='PROFILES/another.json')
        common.write_json(self.root / other['profile'], dict(self.profile, game_id='another'))
        self.manifest['targets'] = [self.entry, other]
        self.write_manifest()
        _, sealed, _ = self.finish(self.prepare())
        identities = sealed['target_identity']
        self.assertEqual(list(identities), ['another', 'game'])
        self.assertEqual({v['target_id'] for v in identities.values()}, {'another', 'game'})
        self.assertNotEqual(identities['another']['fingerprint'], identities['game']['fingerprint'])

    def test_filtered_out_target_remains_required_not_run(self):
        other = dict(self.entry, id='playable', profile='PROFILES/playable.json')
        common.write_json(self.root / other['profile'],
                          dict(self.profile, game_id='playable', prototype_type='playable'))
        self.manifest['targets'] = [self.entry, other]
        self.write_manifest()
        prepared = self.prepare()
        data = self.data(prepared)
        # The native runner records only Sessions actually started after its
        # --prototype filter. A frozen identity alone is not execution proof.
        data['executed_target_ids'] = ['game']
        _, sealed, _ = self.finish(prepared, data)
        self.assert_blocked(sealed)
        unexecuted = [r for r in sealed['results']
                      if r.get('reason_code') == 'TARGET_NOT_EXECUTED']
        self.assertEqual(len(unexecuted), 1)
        self.assertEqual(unexecuted[0]['test_case'], 'target.playable.execution')
        self.assertEqual(unexecuted[0]['status'], 'NOT_RUN')
        self.assertEqual(unexecuted[0]['gate'], 'REQUIRED')

    def test_fixture_and_adhoc_keep_functional_pass_without_real_certification(self):
        self.entry['kind'] = 'fixture'
        self.write_manifest()
        for mode in ('fixture', 'adhoc'):
            with self.subTest(run_mode=mode):
                prepared = self.prepare()
                data = self.data(prepared)
                data['functional_cases_certified'] = True
                data['functional_e2e_certified'] = True
                _, sealed, _ = self.finish(prepared, data, run_mode=mode)
                self.assertEqual(sealed['overall'], 'PASS')
                self.assertTrue(sealed['functional_cases_certified'])
                self.assertTrue(sealed['functional_e2e_certified'])
                self.assertFalse(sealed['target_qa_certified'])
                self.assertFalse(sealed['completion_certified'])
                real_target_rows = [r for r in sealed['results']
                                    if r.get('reason_code') == coordinator.TARGET_NOT_REAL]
                self.assertTrue(real_target_rows)
                self.assertTrue(all(r['status'] == 'NOT_RUN' and r['gate'] == 'OPTIONAL'
                                    for r in real_target_rows))

    def baseline(self, identity):
        screenshot = self.root / 'screen.bmp'
        screenshot.write_bytes(b'copied baseline screenshot')
        return regression.export_baseline(
            self.root / 'baseline', self.profile, 'goal', 17,
            {'score': 1}, ['go'], [{'score': 1}], {}, screenshot,
            'USER_SPECIFIED_PREVIOUS_RUN', target_identity=identity)

    def test_actual_baseline_loader_rejects_stale_a_after_a_b_a(self):
        first = bind_target(self.root, self.entry, self.profile)
        self.baseline(first)
        (self.root / 'GAME/source.txt').write_text('B', encoding='utf-8')
        bind_target(self.root, self.entry, self.profile)
        (self.root / 'GAME/source.txt').write_text('A', encoding='utf-8')
        current = bind_target(self.root, self.entry, self.profile)
        self.assertEqual(first.fingerprint, current.fingerprint)
        self.assertIn('STALE_TARGET_GENERATION', check_result_binding(current, first.to_dict()))
        with self.assertRaisesRegex(ValueError, 'STALE_BASELINE_LINEAGE_BROKEN'):
            regression.load_baseline(self.root / 'baseline', self.profile, 'goal', 17,
                                     identity=current, identity_root=self.root)

    def test_actual_baseline_loader_keeps_unchanged_target_baseline_usable(self):
        first = bind_target(self.root, self.entry, self.profile)
        self.baseline(first)
        current = bind_target(self.root, self.entry, self.profile)
        loaded = regression.load_baseline(self.root / 'baseline', self.profile, 'goal', 17,
                                          identity=current, identity_root=self.root)
        self.assertEqual(loaded['state'], {'score': 1})

    def test_finalizer_rejects_previous_a_result_after_a_b_a(self):
        first = self.prepare()
        data = self.data(first)
        data['target_identity'] = {
            key: identity.to_dict() for key, identity in first['identities'].items()}
        (self.root / 'GAME/source.txt').write_text('B', encoding='utf-8')
        self.prepare()
        (self.root / 'GAME/source.txt').write_text('A', encoding='utf-8')
        current = self.prepare()
        _, sealed, _ = self.finish(current, data)
        self.assert_blocked(sealed)
        self.assertTrue(any(r.get('reason_code') == 'STALE_TARGET_GENERATION'
                            for r in sealed['results']), sealed['results'])


if __name__ == '__main__':
    unittest.main()
