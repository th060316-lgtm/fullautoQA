"""Tests for the Sales headquarters evaluator.

Run with:  python -m unittest discover -s tests -t . -v
       or:  pytest tests/test_sales_hq.py
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1] / 'CORE'
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))
import common  # noqa: F401

from coordinator import CoordinatorContext  # noqa: E402
from sales_evaluator import (SALES_BLOCKING_FINDINGS_RECORDED,  # noqa: E402
                              SALES_COLD_START_EVIDENCE_ABSENT,
                              SALES_COLD_START_PROVENANCE_MISSING,
                              SALES_EVALUATION_NOT_PERFORMED,
                              SALES_MODEL_PROXY_IS_NOT_HUMAN_TEST,
                              SALES_OBSERVATION_INCOMPLETE, evaluate_sales)

BUNDLE_NAME = 'sales_evidence.json'


def materialize_bundle_evidence(root, bundle):
    root = Path(root)
    refs = []
    source = bundle.get('review_evidence_source') if isinstance(bundle, dict) else None
    if source:
        refs.append(source)
    audience = bundle.get('audience_summary_evidence') if isinstance(bundle, dict) else None
    if isinstance(audience, str):
        refs.append(audience)
    elif isinstance(audience, (list, tuple)):
        refs.extend(audience)
    for session in (bundle.get('sessions') or []) if isinstance(bundle, dict) else []:
        if not isinstance(session, dict):
            continue
        for record in (session.get('phases') or {}).values():
            if isinstance(record, dict):
                value = record.get('evidence')
                if isinstance(value, str):
                    refs.append(value)
                elif isinstance(value, (list, tuple)):
                    refs.extend(value)
    for ref in refs:
        path = root / str(ref)
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            path.write_bytes(b'test-evidence')


def write_bundle(root, bundle):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    materialize_bundle_evidence(root, bundle)
    (root / BUNDLE_NAME).write_text(json.dumps(bundle), encoding='utf-8')
    return root


def context(root, settings=None, extras=None, results=()):
    return CoordinatorContext(root=root, results=results, settings=settings or {},
                              extras=extras or {})


def complete_bundle(**overrides):
    """A bundle that satisfies every required Sales gate."""
    bundle = {
        'evidence_kind': 'real_human',
        'reviewer': {'kind': 'human', 'id': 'reviewer-1'},
        'human_test_performed': True,
        'review_evidence_source': 'review_evidence/sales_review.json',
        'audience_summary': {
            'schema_version': 1,
            'status': 'GENERATED',
            'entries': [{
                'target_index': 0,
                'what_game': 'The player moves and reaches an objective.',
                'product_description': 'A game centered on movement and reaching an objective.',
                'evidence': ['player_review_packet.json'],
            }],
            'evidence': ['player_review_packet.json'],
            'description_contract': {
                'basis': ['actions', 'goals', 'scenarios'],
                'excluded_metadata': ['game_id', 'game_name', 'title', 'ip', 'license', 'price', 'free'],
                'brand_price_independent': True,
                'quality_claimed': False,
                'human_readability_claimed': False,
            },
        },
        'audience_summary_evidence': ['audience_summary.json', 'AUDIENCE_SUMMARY.txt'],
        'sessions': [{
            'session_id': 's1',
            'cold_start': True,
            'provenance': {'source': 'fresh_install', 'started_at': '2026-01-01T00:00:00Z',
                           'run_id': 'r1'},
            'phases': {
                'first_30_seconds': {'observed': True, 'status': 'pass', 'findings': [],
                                     'evidence': ['rec30.mp4']},
                'first_5_minutes': {'observed': True, 'status': 'pass', 'findings': [],
                                    'evidence': ['rec5m.mp4']},
                'product_shelf_test': {'observed': True, 'status': 'pass', 'findings': [],
                                       'evidence': ['shelf.png']},
                'communication_readability': {'observed': True, 'status': 'pass', 'findings': [],
                                              'evidence': ['notes.txt']},
            },
        }],
    }
    bundle.update(overrides)
    return bundle


def evaluate(bundle=None, settings=None, root=None):
    with tempfile.TemporaryDirectory() as tmp:
        if bundle is not None:
            write_bundle(tmp, bundle)
        return evaluate_sales(context(root or tmp, settings=settings))


def gate(readback, name):
    for entry in readback['gate_status']:
        if entry['name'] == name:
            return entry
    return None


class SalesNoEvidenceTest(unittest.TestCase):
    def test_no_evidence_is_not_run(self):
        report = evaluate(None)
        self.assertEqual(report.name, 'sales')
        self.assertEqual(report.status, 'NOT_RUN')
        self.assertNotEqual(report.status, 'PASS')
        self.assertEqual(report.readback['reason_code'], SALES_EVALUATION_NOT_PERFORMED)
        self.assertFalse(report.readback['evidence_present'])

    def test_no_cold_start_evidence_is_not_run(self):
        bundle = complete_bundle()
        bundle['sessions'][0].pop('cold_start')
        bundle['sessions'][0]['provenance']['source'] = 'incremental_update'
        report = evaluate(bundle)
        self.assertEqual(report.status, 'NOT_RUN')
        self.assertIsNotNone(gate(report.readback, 'sales.cold_start_session'))
        self.assertEqual(gate(report.readback, 'sales.cold_start_session')['reason_code'],
                         SALES_COLD_START_EVIDENCE_ABSENT)
        self.assertTrue(report.readback['unresolved_gates'])

    def test_cold_start_provenance_is_a_separate_gate(self):
        bundle = complete_bundle()
        bundle['sessions'][0].pop('provenance')
        report = evaluate(bundle)
        session_gate = gate(report.readback, 'sales.cold_start_session')
        provenance_gate = gate(report.readback, 'sales.cold_start_provenance')
        self.assertEqual(session_gate['status'], 'PASS')
        self.assertEqual(provenance_gate['status'], 'NOT_RUN')
        self.assertEqual(provenance_gate['reason_code'], SALES_COLD_START_PROVENANCE_MISSING)
        self.assertNotEqual(report.status, 'PASS')


class SalesRobustnessTest(unittest.TestCase):
    def test_malformed_evidence_file_does_not_crash_the_evaluator(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / BUNDLE_NAME).write_text('[1, 2, 3]', encoding='utf-8')
            report = evaluate_sales(context(tmp))
        self.assertEqual(report.status, 'NOT_RUN')
        self.assertFalse(report.readback['human_test_performed'])

    def test_evidence_from_context_extras_is_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = complete_bundle()
            materialize_bundle_evidence(tmp, bundle)
            report = evaluate_sales(context(tmp, extras={'sales_evidence': bundle}))
        self.assertEqual(report.status, 'PASS')
        self.assertTrue(report.readback['human_test_performed'])


class SalesAudienceSummaryTest(unittest.TestCase):
    def test_missing_audience_summary_keeps_product_communication_gates_not_run(self):
        bundle = complete_bundle()
        bundle.pop('audience_summary')
        bundle.pop('audience_summary_evidence')
        report = evaluate(bundle)
        self.assertEqual(gate(report.readback, 'sales.product_description_independent')['status'], 'NOT_RUN')
        self.assertEqual(gate(report.readback, 'sales.what_game_summary')['status'], 'NOT_RUN')
        self.assertEqual(gate(report.readback, 'sales.nontechnical_report')['status'], 'NOT_RUN')
        self.assertNotEqual(report.status, 'PASS')

    def test_valid_summary_passes_structural_description_and_what_game_gates(self):
        report = evaluate(complete_bundle())
        self.assertEqual(gate(report.readback, 'sales.product_description_independent')['status'], 'PASS')
        self.assertEqual(gate(report.readback, 'sales.what_game_summary')['status'], 'PASS')
        self.assertEqual(gate(report.readback, 'sales.nontechnical_report')['status'], 'PASS')
        self.assertEqual(report.readback['audience_summary']['status'], 'GENERATED')

    def test_nontechnical_report_waits_for_readability_review(self):
        bundle = complete_bundle()
        bundle['sessions'][0]['phases'].pop('communication_readability')
        report = evaluate(bundle)
        self.assertEqual(gate(report.readback, 'sales.product_description_independent')['status'], 'PASS')
        self.assertEqual(gate(report.readback, 'sales.what_game_summary')['status'], 'PASS')
        self.assertEqual(gate(report.readback, 'sales.nontechnical_report')['status'], 'NOT_RUN')
        self.assertNotEqual(report.status, 'PASS')


class SalesHumanVersusProxyTest(unittest.TestCase):
    def test_model_proxy_never_sets_human_test_performed(self):
        bundle = complete_bundle()
        bundle['reviewer'] = {'kind': 'model_proxy', 'id': 'model-1'}
        bundle['evidence_kind'] = 'model_proxy'
        report = evaluate(bundle)
        self.assertFalse(report.readback['human_test_performed'])
        self.assertFalse(report.readback['human_test_evidence']['present'])
        human_gate = gate(report.readback, 'sales.human_test')
        self.assertEqual(human_gate['status'], 'NOT_RUN')
        self.assertEqual(human_gate['reason_code'], SALES_MODEL_PROXY_IS_NOT_HUMAN_TEST)

    def test_real_human_evidence_is_distinct_from_a_proxy(self):
        proxy = complete_bundle()
        proxy['reviewer'] = {'kind': 'model_proxy'}
        proxy['evidence_kind'] = 'model_proxy'
        human = complete_bundle()
        proxy_report = evaluate(proxy)
        human_report = evaluate(human)
        self.assertFalse(proxy_report.readback['human_test_performed'])
        self.assertTrue(human_report.readback['human_test_performed'])
        self.assertEqual(human_report.readback['human_test_evidence']['kind'], 'human')
        self.assertEqual(proxy_report.readback['human_test_evidence']['kind'], 'model_proxy')
        self.assertNotEqual(proxy_report.readback['human_test_evidence']['reason_code'],
                            human_report.readback['human_test_evidence']['reason_code'])

    def test_unknown_reviewer_is_not_a_human_test(self):
        bundle = complete_bundle()
        bundle.pop('reviewer')
        bundle['evidence_kind'] = 'unknown_kind'
        report = evaluate(bundle)
        self.assertFalse(report.readback['human_test_performed'])
        self.assertEqual(gate(report.readback, 'sales.human_test')['status'], 'NOT_RUN')

    def test_human_identity_without_explicit_performed_flag_is_not_a_human_test(self):
        bundle = complete_bundle()
        bundle.pop('human_test_performed')
        report = evaluate(bundle)
        self.assertFalse(report.readback['human_test_performed'])
        self.assertEqual(gate(report.readback, 'sales.human_test')['status'], 'NOT_RUN')

    def test_explicit_false_human_test_flag_is_not_a_human_test(self):
        bundle = complete_bundle(human_test_performed=False)
        report = evaluate(bundle)
        self.assertFalse(report.readback['human_test_performed'])
        self.assertEqual(gate(report.readback, 'sales.human_test')['status'], 'NOT_RUN')

    def test_human_flag_without_validated_review_source_is_not_a_human_test(self):
        bundle = complete_bundle()
        bundle.pop('review_evidence_source')
        report = evaluate(bundle)
        self.assertFalse(report.readback['human_test_performed'])
        self.assertEqual(gate(report.readback, 'sales.human_test')['status'], 'NOT_RUN')

    def test_missing_preserved_review_source_blocks_human_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = complete_bundle()
            write_bundle(tmp, bundle)
            (Path(tmp) / 'review_evidence' / 'sales_review.json').unlink()
            report = evaluate_sales(context(tmp))
        self.assertFalse(report.readback['human_test_performed'])
        self.assertEqual(gate(report.readback, 'sales.human_test')['status'], 'NOT_RUN')


class SalesPhaseSeparationTest(unittest.TestCase):
    def test_30_second_and_5_minute_gates_are_separate(self):
        bundle = complete_bundle()
        bundle['sessions'][0]['phases'].pop('first_5_minutes')
        report = evaluate(bundle)
        self.assertEqual(gate(report.readback, 'sales.first_30_seconds')['status'], 'PASS')
        self.assertIsNotNone(gate(report.readback, 'sales.first_5_minutes'))
        self.assertEqual(gate(report.readback, 'sales.first_5_minutes')['status'], 'NOT_RUN')
        self.assertNotEqual(report.status, 'PASS')

    def test_product_and_readability_gates_are_separate(self):
        bundle = complete_bundle()
        bundle['sessions'][0]['phases']['product_shelf_test'] = {
            'observed': True, 'findings': [{'severity': 'error', 'text': 'shelf missing'}],
            'evidence': ['shelf.png']}
        report = evaluate(bundle)
        product = gate(report.readback, 'sales.product_shelf_test')
        readability = gate(report.readback, 'sales.communication_readability')
        self.assertEqual(product['status'], 'FAIL')
        self.assertEqual(product['reason_code'], SALES_BLOCKING_FINDINGS_RECORDED)
        self.assertEqual(readability['status'], 'PASS')
        self.assertNotEqual(report.status, 'PASS')

    def test_blocking_findings_fail_only_their_own_phase(self):
        bundle = complete_bundle()
        bundle['sessions'][0]['phases']['first_30_seconds'] = {
            'observed': True, 'findings': [{'severity': 'error', 'text': 'broken menu'}]}
        report = evaluate(bundle)
        self.assertEqual(gate(report.readback, 'sales.first_30_seconds')['status'], 'FAIL')
        self.assertEqual(gate(report.readback, 'sales.first_5_minutes')['status'], 'PASS')
        self.assertEqual(gate(report.readback, 'sales.product_shelf_test')['status'], 'PASS')

    def test_observation_without_an_outcome_is_not_run(self):
        bundle = complete_bundle()
        bundle['sessions'][0]['phases']['first_5_minutes'] = {'observed': True,
                                                              'evidence': ['rec5m.mp4']}
        report = evaluate(bundle)
        gate_entry = gate(report.readback, 'sales.first_5_minutes')
        self.assertEqual(gate_entry['status'], 'NOT_RUN')
        self.assertEqual(gate_entry['reason_code'], SALES_OBSERVATION_INCOMPLETE)

    def test_positive_phase_without_evidence_reference_is_not_run(self):
        bundle = complete_bundle()
        bundle['sessions'][0]['phases']['first_30_seconds'] = {
            'observed': True, 'status': 'pass', 'findings': []}
        report = evaluate(bundle)
        entry = gate(report.readback, 'sales.first_30_seconds')
        self.assertEqual(entry['status'], 'NOT_RUN')
        self.assertEqual(entry['reason_code'], 'SALES_PHASE_EVIDENCE_MISSING')

    def test_positive_phase_with_missing_evidence_file_is_not_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = complete_bundle()
            write_bundle(tmp, bundle)
            (Path(tmp) / 'rec30.mp4').unlink()
            report = evaluate_sales(context(tmp))
        entry = gate(report.readback, 'sales.first_30_seconds')
        self.assertEqual(entry['status'], 'NOT_RUN')
        self.assertEqual(entry['reason_code'], 'SALES_PHASE_EVIDENCE_MISSING')
        self.assertNotEqual(report.status, 'PASS')


class SalesCertificationTest(unittest.TestCase):
    def test_qa_complete_product_accepted_stable_and_release_stay_distinct(self):
        report = evaluate(complete_bundle())
        certifications = report.readback['certifications']
        self.assertEqual(set(certifications),
                         {'qa_complete', 'product_accepted', 'stable', 'release_approved'})
        self.assertTrue(certifications['qa_complete']['granted'])
        self.assertEqual(certifications['qa_complete']['scope'], 'sales_hq_evaluation')
        for name in ('product_accepted', 'stable', 'release_approved'):
            self.assertFalse(certifications[name]['granted'], name)
            self.assertTrue(certifications[name]['basis'].endswith('HOLD'), name)

    def test_qa_complete_is_not_granted_while_a_gate_is_unresolved(self):
        bundle = complete_bundle()
        bundle['sessions'][0]['phases'].pop('product_shelf_test')
        report = evaluate(bundle)
        certifications = report.readback['certifications']
        self.assertFalse(certifications['qa_complete']['granted'])
        self.assertIn('sales.product_shelf_test', certifications['qa_complete']['unresolved_gates'])

    def test_no_subjective_claims_are_made(self):
        bundle = complete_bundle(fun=True, sellable=True, understandable=True)
        report = evaluate(bundle)
        for name, claim in report.readback['claims'].items():
            self.assertFalse(claim['evaluator_claim'], name)
            self.assertEqual(claim['basis'],
                             'SALES_SUBJECTIVE_CLAIM_NOT_EVALUATED_BY_THIS_EVALUATOR')
        self.assertTrue(report.readback['claims']['fun']['recorded_in_evidence'])
        self.assertTrue(report.readback['claims']['fun']['recorded_value'])

    def test_readback_carries_provenance_and_unresolved_gates(self):
        bundle = complete_bundle()
        bundle['sessions'][0]['phases'].pop('first_5_minutes')
        report = evaluate(bundle)
        readback = report.readback
        self.assertTrue(readback['evidence_sources'])
        self.assertTrue(readback['unresolved_gates'])
        self.assertTrue(any(entry['gate'] == 'sales.first_5_minutes'
                            for entry in readback['unresolved_gates']))
        self.assertEqual(readback['sessions'][0]['session_id'], 's1')
        self.assertTrue(readback['sessions'][0]['cold_start'])


class SalesReadbackTest(unittest.TestCase):
    def test_readback_serializes_to_json(self):
        report = evaluate(complete_bundle())
        payload = json.dumps(report.readback, sort_keys=True)
        restored = json.loads(payload)
        self.assertEqual(restored['domain'], 'sales')
        self.assertEqual(restored['status'], report.status)
        self.assertIn('certifications', restored)
        self.assertIn('unresolved_gates', restored)

    def test_readback_serialization_is_deterministic(self):
        from hq_evidence import stable_fingerprint
        first = evaluate(complete_bundle()).readback
        second = evaluate(complete_bundle()).readback
        self.assertEqual(stable_fingerprint(first), stable_fingerprint(second))

    def test_readback_survives_the_pre_zip_result_model(self):
        from common import write_json
        domain_report = evaluate(complete_bundle())
        with tempfile.TemporaryDirectory() as tmp:
            model = {'headquarters': {}, 'sales_readback': domain_report.readback}
            target = Path(tmp) / 'result.json'
            write_json(target, model)
            stored = json.loads(target.read_text(encoding='utf-8'))
        self.assertIn('sales_readback', stored)
        self.assertEqual(stored['sales_readback']['domain'], 'sales')
        self.assertEqual(stored['sales_readback']['status'], domain_report.status)


class SalesCompleteEvidenceTest(unittest.TestCase):
    def test_sufficient_evidence_produces_a_pass(self):
        report = evaluate(complete_bundle())
        self.assertEqual(report.status, 'PASS')
        self.assertEqual(report.readback['accepted'], True)
        self.assertTrue(report.readback['human_test_performed'])
        self.assertEqual(report.readback['unresolved_gates'], [])


if __name__ == '__main__':
    unittest.main()