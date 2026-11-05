"""Tests for the Management headquarters evaluator.

Run with:  python -m unittest discover -s tests -t . -v
       or:  pytest tests/test_management_hq.py
"""
from __future__ import annotations

import json
import os
import sys
import unittest
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1] / 'CORE'
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))
import common  # noqa: F401

from coordinator import CoordinatorContext  # noqa: E402
from management_evaluator import (MANAGEMENT_EVIDENCE_FIXTURE_NOT_REAL_GAME,  # noqa: E402
                                  MANAGEMENT_MANUAL_INTERVENTION_REQUIRED,
                                  MANAGEMENT_MEASUREMENT_UNAVAILABLE,
                                  MANAGEMENT_THRESHOLD_NOT_CONFIGURED,
                                  MANAGEMENT_THRESHOLD_UNIT_MISMATCH,
                                  MANAGEMENT_THRESHOLD_VIOLATION, evaluate_management)

BUNDLE_NAME = 'management_evidence.json'


def write_bundle(root, bundle):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    (root / BUNDLE_NAME).write_text(json.dumps(bundle), encoding='utf-8')
    return root


def context(root, settings=None, extras=None, results=()):
    return CoordinatorContext(root=root, results=results, settings=settings or {},
                              extras=extras or {})


def complete_bundle(**overrides):
    """A bundle that satisfies every required Management gate."""
    bundle = {
        'evidence_kind': 'real_game',
        'measurements': {
            'cpu_percent': {'value': 17.5, 'unit': 'percent', 'evidence': ['perf.json']},
            'ram_mb': {'value': 256.25, 'unit': 'mb'},
            'handles': {'value': 412, 'unit': 'count'},
            'runtime_seconds': {'value': 91.5, 'unit': 'seconds'},
            'disk_bytes': {'value': 1048576, 'unit': 'bytes'},
            'evidence_bytes': {'value': 4096, 'unit': 'bytes'},
        },
        'performance_regression': False,
        'reproducibility': True,
        'fresh_run': True,
        'target_generation': 3,
        'one_click': True,
        'manual_intervention': False,
        'no_admin': True,
        'offline': True,
        'integrity': True,
        'residual_risk': [],
    }
    bundle.update(overrides)
    return bundle


FULL_THRESHOLDS = {
    'cpu_percent': {'max': 80, 'unit': 'percent'},
    'ram_mb': {'max': 4096, 'unit': 'mb'},
    'handles': {'max': 5000, 'unit': 'count'},
    'runtime_seconds': {'max': 3600, 'unit': 'seconds'},
    'disk_bytes': {'max': 1073741824, 'unit': 'bytes'},
    'evidence_bytes': {'max': 10485760, 'unit': 'bytes'},
}


class ManagementEvidenceAbsenceTest(unittest.TestCase):
    def test_missing_evidence_is_not_run_and_never_pass(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            report = evaluate_management(context(tmp))
        self.assertEqual(report.name, 'management')
        self.assertEqual(report.status, 'NOT_RUN')
        self.assertNotEqual(report.status, 'PASS')
        self.assertFalse(report.accepted if hasattr(report, 'accepted') else False)
        self.assertEqual(report.counts.get('NOT_RUN', 0) + report.counts.get('INCONCLUSIVE', 0),
                         report.counts['total'])

    def test_missing_evidence_keeps_every_gate_visible(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            report = evaluate_management(context(tmp))
        names = {gate['name'] for gate in report.gates}
        self.assertIn('management.cpu', names)
        self.assertIn('management.ram', names)
        self.assertIn('management.handles', names)
        self.assertIn('management.runtime', names)
        self.assertIn('management.disk', names)
        self.assertIn('management.evidence_size', names)
        self.assertIn('management.one_click', names)
        self.assertIn('management.manual_intervention', names)
        self.assertIn('management.no_admin', names)
        self.assertIn('management.offline', names)
        self.assertIn('management.integrity', names)
        self.assertIn('management.residual_risk', names)
        self.assertIn('management.reproducibility', names)
        self.assertIn('management.fresh_run', names)
        self.assertIn('management.target_generation_integrity', names)
        self.assertIn('management.performance_regression', names)
        self.assertIn('management.evidence_kind', names)
        self.assertIn('management.measurement_coverage', names)

    def test_absent_measurement_is_not_zero(self):
        import tempfile
        bundle = complete_bundle()
        bundle['measurements'].pop('ram_mb')
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, bundle)
            report = evaluate_management(context(tmp))
        measurement = report.readback['measurements']['ram_mb']
        self.assertIsNone(measurement['value'])
        self.assertFalse(measurement['available'])
        self.assertNotEqual(measurement['value'], 0)
        self.assertEqual(measurement['status'], 'NOT_RUN')
        self.assertEqual(measurement['reason_code'], MANAGEMENT_MEASUREMENT_UNAVAILABLE)

    def test_unavailable_items_stay_visible_in_the_readback(self):
        import tempfile
        bundle = complete_bundle()
        bundle['measurements'].pop('ram_mb')
        bundle['measurements'].pop('handles')
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, bundle)
            report = evaluate_management(context(tmp))
        readback = report.readback
        self.assertTrue(readback['unavailable'])
        items = {entry['item'] for entry in readback['unavailable']}
        self.assertTrue(readback['unavailable_required'])
        self.assertIn('management.ram', items)
        self.assertIn('management.handles', items)
        self.assertIn('management.target_generation_integrity', items)
        self.assertTrue(readback['evidence_present'])
        self.assertFalse(readback['accepted'])


class ManagementRobustnessTest(unittest.TestCase):
    def test_malformed_evidence_file_does_not_crash_the_evaluator(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / BUNDLE_NAME).write_text('{not json at all', encoding='utf-8')
            report = evaluate_management(context(tmp))
        self.assertEqual(report.status, 'NOT_RUN')
        self.assertFalse(report.readback['evidence_present'])
        sources = report.readback['evidence_sources']
        self.assertTrue(any(source.get('error') for source in sources))

    def test_unrelated_evidence_shape_does_not_crash_the_evaluator(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, {'unrelated': 'value', 'measurements': 'not a mapping'})
            report = evaluate_management(context(tmp))
        self.assertNotEqual(report.status, 'PASS')
        self.assertTrue(report.readback['unavailable_required'])

    def test_evidence_from_context_extras_is_used(self):
        import tempfile
        bundle = complete_bundle()
        with tempfile.TemporaryDirectory() as tmp:
            report = evaluate_management(context(tmp, extras={'management_evidence': bundle}))
        self.assertTrue(report.readback['evidence_present'])
        self.assertEqual(report.readback['measurements']['cpu_percent']['value'], 17.5)


class ManagementMeasurementTest(unittest.TestCase):
    def test_measured_values_are_preserved_exactly(self):
        import tempfile
        bundle = complete_bundle()
        bundle['measurements']['cpu_percent'] = {'value': 12.345678901234567, 'unit': 'percent'}
        bundle['measurements']['runtime_seconds'] = {'value': 0.1 + 0.2, 'unit': 'seconds'}
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, bundle)
            report = evaluate_management(context(tmp, settings={'management_thresholds': FULL_THRESHOLDS}))
        cpu = report.readback['measurements']['cpu_percent']
        runtime = report.readback['measurements']['runtime_seconds']
        self.assertEqual(cpu['value'], 12.345678901234567)
        self.assertEqual(runtime['value'], 0.1 + 0.2)
        self.assertNotEqual(cpu['value'], 12.35)

    def test_string_measurements_are_not_coerced(self):
        import tempfile
        bundle = complete_bundle()
        bundle['measurements']['ram_mb'] = {'value': '256.25', 'unit': 'mb'}
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, bundle)
            report = evaluate_management(context(tmp))
        self.assertEqual(report.readback['measurements']['ram_mb']['value'], '256.25')

    def test_measurement_evidence_provenance_is_kept(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            report = evaluate_management(context(tmp))
        sources = report.readback['evidence_sources']
        self.assertTrue(sources)
        self.assertTrue(any(source.get('kind') == 'file' for source in sources))
        file_source = [source for source in sources if source.get('kind') == 'file'][0]
        self.assertIn(BUNDLE_NAME, file_source['location'])
        self.assertEqual(len(file_source['sha256']), 64)


class ManagementThresholdTest(unittest.TestCase):
    def test_absent_threshold_does_not_fabricate_a_verdict(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            report = evaluate_management(context(tmp))
        cpu = report.readback['measurements']['cpu_percent']
        self.assertEqual(cpu['status'], 'INCONCLUSIVE')
        self.assertEqual(cpu['reason_code'], MANAGEMENT_THRESHOLD_NOT_CONFIGURED)
        self.assertIsNone(cpu['threshold'])
        self.assertEqual(cpu['value'], 17.5)
        self.assertEqual(report.readback['measurement_quality']['status'], 'INCONCLUSIVE')

    def test_configured_threshold_can_pass_and_fail(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            passing = evaluate_management(context(tmp, settings={'management_thresholds': FULL_THRESHOLDS}))
            failing = evaluate_management(context(
                tmp, settings={'management_thresholds': dict(FULL_THRESHOLDS,
                                                             cpu_percent={'max': 1, 'unit': 'percent'})}))
        self.assertEqual(passing.readback['measurements']['cpu_percent']['status'], 'PASS')
        self.assertEqual(failing.readback['measurements']['cpu_percent']['status'], 'FAIL')
        self.assertEqual(failing.readback['measurements']['cpu_percent']['reason_code'],
                         MANAGEMENT_THRESHOLD_VIOLATION)
        self.assertEqual(failing.readback['measurements']['cpu_percent']['value'], 17.5)

    def test_unit_mismatch_does_not_produce_a_pass(self):
        import tempfile
        thresholds = dict(FULL_THRESHOLDS, cpu_percent={'max': 80, 'unit': 'mb'})
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            report = evaluate_management(context(tmp, settings={'management_thresholds': thresholds}))
        cpu = report.readback['measurements']['cpu_percent']
        self.assertEqual(cpu['status'], 'INCONCLUSIVE')
        self.assertEqual(cpu['reason_code'], MANAGEMENT_THRESHOLD_UNIT_MISMATCH)
        self.assertNotEqual(report.status, 'PASS')

    def test_bare_numeric_threshold_is_ignored_not_guessed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            report = evaluate_management(context(tmp, settings={'management_thresholds': {'cpu_percent': 80}}))
        cpu = report.readback['measurements']['cpu_percent']
        self.assertEqual(cpu['status'], 'INCONCLUSIVE')
        self.assertEqual(cpu['reason_code'], MANAGEMENT_THRESHOLD_NOT_CONFIGURED)
        self.assertTrue(any(risk['code'] == 'MANAGEMENT_THRESHOLD_IGNORED'
                            for risk in report.readback['risks']))


class ManagementSignalTest(unittest.TestCase):
    def test_manual_intervention_is_a_failure_not_a_pass(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle(manual_intervention=True))
            report = evaluate_management(context(tmp))
        gate = [g for g in report.readback['gates'] if g['name'] == 'management.manual_intervention'][0]
        self.assertEqual(gate['status'], 'FAIL')
        self.assertEqual(gate['reason_code'], MANAGEMENT_MANUAL_INTERVENTION_REQUIRED)
        self.assertNotEqual(report.status, 'PASS')

    def test_performance_regression_is_a_failure(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle(performance_regression=True))
            report = evaluate_management(context(tmp))
        gate = [g for g in report.readback['gates']
                if g['name'] == 'management.performance_regression'][0]
        self.assertEqual(gate['status'], 'FAIL')

    def test_fixture_evidence_is_never_real_game_acceptance(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle(evidence_kind='fixture'))
            report = evaluate_management(context(tmp))
        gate = [g for g in report.readback['gates'] if g['name'] == 'management.evidence_kind'][0]
        self.assertEqual(gate['status'], 'NOT_RUN')
        self.assertEqual(gate['reason_code'], MANAGEMENT_EVIDENCE_FIXTURE_NOT_REAL_GAME)
        self.assertFalse(report.readback['real_game_acceptance'])
        self.assertNotEqual(report.status, 'PASS')

    def test_target_generation_is_cross_checked_against_the_frozen_identity(self):
        import tempfile
        extras = {'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle(target_generation=3))
            matching = evaluate_management(context(tmp, extras=extras))
            write_bundle(tmp, complete_bundle(target_generation=9))
            mismatching = evaluate_management(context(tmp, extras=extras))
        gate = [g for g in matching.readback['gates']
                if g['name'] == 'management.target_generation_integrity']
        self.assertEqual(gate, [])
        bad = [g for g in mismatching.readback['gates']
               if g['name'] == 'management.target_generation_integrity'][0]
        self.assertEqual(bad['status'], 'FAIL')
        self.assertEqual(bad['reason_code'], 'MANAGEMENT_IDENTITY_MISMATCH')


class ManagementReadbackTest(unittest.TestCase):
    def test_readback_serializes_to_json(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            report = evaluate_management(context(tmp))
        payload = json.dumps(report.readback, sort_keys=True)
        restored = json.loads(payload)
        self.assertEqual(restored['domain'], 'management')
        self.assertEqual(restored['status'], report.status)
        self.assertIn('measurements', restored)
        self.assertIn('unavailable', restored)
        self.assertIn('risks', restored)

    def test_readback_serialization_is_deterministic(self):
        import tempfile
        from hq_evidence import stable_fingerprint
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            first = evaluate_management(context(tmp)).readback
            second = evaluate_management(context(tmp)).readback
        self.assertEqual(stable_fingerprint(first), stable_fingerprint(second))
        self.assertEqual(first['fingerprint'], second['fingerprint'])

    def test_readback_survives_the_pre_zip_result_model(self):
        import tempfile
        from common import write_json
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            domain_report = evaluate_management(context(tmp))
            model = {'headquarters': {}, 'management_readback': domain_report.readback}
            target = Path(tmp) / 'result.json'
            write_json(target, model)
            stored = json.loads(target.read_text(encoding='utf-8'))
        self.assertIn('management_readback', stored)
        self.assertEqual(stored['management_readback']['domain'], 'management')
        self.assertEqual(stored['management_readback']['status'], domain_report.status)


class ManagementCompleteEvidenceTest(unittest.TestCase):
    def test_sufficient_evidence_produces_a_pass(self):
        import tempfile
        extras = {'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            report = evaluate_management(context(tmp, settings={'management_thresholds': FULL_THRESHOLDS},
                                                 extras=extras))
        self.assertEqual(report.status, 'PASS')
        self.assertEqual(report.readback['accepted'], True)
        self.assertTrue(report.readback['real_game_acceptance'])
        self.assertEqual(report.readback['unavailable_required'], [])
        self.assertEqual(report.readback['status'], 'PASS')

class ManagementCompletionSemanticsTest(unittest.TestCase):
    def test_recorded_measurements_do_not_need_invented_absolute_limits(self):
        import tempfile
        extras = {'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            report = evaluate_management(context(tmp, extras=extras))
        self.assertEqual(report.readback['measurement_availability']['status'], 'PASS')
        self.assertEqual(report.readback['measurement_quality']['status'], 'INCONCLUSIVE')
        self.assertEqual(report.status, 'PASS')
        cpu = next(row for row in report.readback['gate_status'] if row['name'] == 'management.cpu')
        self.assertEqual(cpu['status'], 'INCONCLUSIVE')
        self.assertFalse(cpu['required'])

    def test_missing_required_measurement_still_blocks(self):
        import tempfile
        extras = {'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}
        bundle = complete_bundle()
        bundle['measurements'].pop('ram_mb')
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, bundle)
            report = evaluate_management(context(tmp, extras=extras))
        self.assertEqual(report.readback['measurement_availability']['status'], 'NOT_RUN')
        self.assertNotEqual(report.status, 'PASS')
        coverage = next(row for row in report.readback['gate_status']
                        if row['name'] == 'management.measurement_coverage')
        self.assertTrue(coverage['required'])
        self.assertEqual(coverage['status'], 'NOT_RUN')

    def test_absent_performance_baseline_stays_visible_but_does_not_invent_failure(self):
        import tempfile
        extras = {'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}
        bundle = complete_bundle()
        bundle.pop('performance_regression')
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, bundle)
            report = evaluate_management(context(tmp, extras=extras))
        perf = next(row for row in report.readback['gate_status']
                    if row['name'] == 'management.performance_regression')
        self.assertEqual(perf['status'], 'NOT_RUN')
        self.assertFalse(perf['required'])
        self.assertEqual(report.status, 'PASS')

    def test_recorded_performance_regression_is_enforced(self):
        import tempfile
        extras = {'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle(performance_regression=True))
            report = evaluate_management(context(tmp, extras=extras))
        self.assertEqual(report.status, 'FAIL')
        perf = next(row for row in report.readback['gate_status']
                    if row['name'] == 'management.performance_regression')
        self.assertTrue(perf['required'])
        self.assertEqual(perf['status'], 'FAIL')


class NonFiniteThresholdTest(unittest.TestCase):
    def test_nonfinite_measurements_and_bounds_never_pass(self):
        from hq_evidence import compare_threshold
        for value in (float('nan'), float('inf'), float('-inf'), 'nan', 'inf', '-inf'):
            for bound in ('min', 'max', 'equals'):
                with self.subTest(value=value, bound=bound):
                    self.assertIsNone(compare_threshold(value, {bound: 1})[0])
                    self.assertIsNone(compare_threshold(1, {bound: value})[0])

    def test_finite_comparisons_keep_their_outcomes(self):
        from hq_evidence import compare_threshold
        self.assertIs(compare_threshold(1, {'max': 2})[0], True)
        self.assertIs(compare_threshold(3, {'max': 2})[0], False)


class ManagementSeparationTest(unittest.TestCase):
    def test_evaluator_completed_without_conflating_unjudged_quality(self):
        import tempfile
        extras = {'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            report = evaluate_management(context(tmp, extras=extras))
        self.assertEqual(report.readback['evaluator_execution'], 'COMPLETED')
        self.assertEqual(report.readback['measurement_availability']['status'], 'PASS')
        self.assertEqual(report.readback['measurement_quality']['status'], 'INCONCLUSIVE')
        self.assertEqual(report.status, 'PASS')

    def test_missing_and_nonfinite_measurement_not_available(self):
        import tempfile
        for value in (None, float('nan'), float('inf'), float('-inf')):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as tmp:
                bundle = complete_bundle()
                bundle['measurements']['cpu_percent']['value'] = value
                write_bundle(tmp, bundle)
                report = evaluate_management(context(tmp, {'management_thresholds': FULL_THRESHOLDS}))
                self.assertEqual(report.readback['measurement_availability']['status'], 'NOT_RUN')
                self.assertNotEqual(report.readback['measurement_quality']['status'], 'PASS')
                self.assertNotEqual(report.status, 'PASS')

    def test_configured_breach_is_failure_even_with_completed_execution(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle())
            limits = dict(FULL_THRESHOLDS, cpu_percent={'max': 1, 'unit': 'percent'})
            report = evaluate_management(context(tmp, {'management_thresholds': limits}))
        self.assertEqual(report.readback['evaluator_execution'], 'COMPLETED')
        self.assertEqual(report.readback['measurement_quality']['status'], 'FAIL')
        self.assertEqual(report.status, 'FAIL')

    def test_seed_replay_keeps_same_run_scope_and_sources(self):
        import tempfile
        from phase3_run_evidence import _signals
        with tempfile.TemporaryDirectory() as tmp:
            results = [{'test_case': 'game.seed_replay', 'status': 'PASS', 'evidence': ['seed.json']}]
            signal = _signals(results, False, False, 'environment.json', tmp)['reproducibility']
            bundle = complete_bundle(reproducibility=signal)
            write_bundle(tmp, bundle)
            report = evaluate_management(context(tmp))
        recorded = report.readback['signals']['reproducibility']
        self.assertEqual(recorded['scope'], 'same_run_seed_replay')
        self.assertEqual(recorded['source'], 'result_rows')
        self.assertEqual(recorded['test_cases'], ['game.seed_replay'])
        self.assertEqual(recorded['evidence'], ['seed.json'])
        self.assertEqual(recorded['status'], 'INCONCLUSIVE')
        self.assertIn('same-run seed replay', next(row['detail'] for row in report.readback['gate_status'] if row['name'] == 'management.reproducibility'))

    def test_failed_seed_replay_stays_failure(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_bundle(tmp, complete_bundle(reproducibility={
                'status': False, 'scope': 'same_run_seed_replay', 'evidence': ['seed.json']}))
            report = evaluate_management(context(tmp))
        self.assertEqual(report.readback['signals']['reproducibility']['status'], 'FAIL')
        self.assertEqual(report.status, 'FAIL')


if __name__ == '__main__':
    unittest.main()
