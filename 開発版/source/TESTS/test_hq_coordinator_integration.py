"""Tests for the Headquarters coordinator integration.

These cover the Phase-1 invariants that the Management / Sales evaluators
must not break:

* production / management / sales stay independent domains;
* one HQ PASS cannot hide another HQ unresolved or failing;
* a missing evaluator or missing evidence can never PASS;
* an evaluator that raises only makes its own domain worse;
* the readbacks enter the result model before the evidence manifest and the
  RESULT_FOR_CHATGPT.zip are sealed;
* completion cannot be certified while any HQ domain is unresolved;
* source/unit tests cannot promote Product Acceptance or Stable.

Run with:  python -m unittest discover -s tests -t . -v
       or:  pytest tests/test_hq_coordinator_integration.py
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

from coordinator import (Coordinator, CoordinatorContext, HUMAN_TEST_CLAIM_REVOKED,  # noqa: E402
                         attach_readbacks, attach_summary_to_result_file,
                         execution_finalizer, production_evaluator)
from headquarters import DOMAIN_ORDER, DomainReport  # noqa: E402

MANAGEMENT_EVIDENCE = 'management_evidence.json'
SALES_EVIDENCE = 'sales_evidence.json'

THRESHOLDS = {
    'cpu_percent': {'max': 80, 'unit': 'percent'},
    'ram_mb': {'max': 4096, 'unit': 'mb'},
    'handles': {'max': 5000, 'unit': 'count'},
    'runtime_seconds': {'max': 3600, 'unit': 'seconds'},
    'disk_bytes': {'max': 1073741824, 'unit': 'bytes'},
    'evidence_bytes': {'max': 10485760, 'unit': 'bytes'},
}


def management_bundle():
    return {
        'evidence_kind': 'real_game',
        'measurements': {
            'cpu_percent': {'value': 17.5, 'unit': 'percent'},
            'ram_mb': {'value': 256.25, 'unit': 'mb'},
            'handles': {'value': 412, 'unit': 'count'},
            'runtime_seconds': {'value': 91.5, 'unit': 'seconds'},
            'disk_bytes': {'value': 1048576, 'unit': 'bytes'},
            'evidence_bytes': {'value': 4096, 'unit': 'bytes'},
        },
        'performance_regression': False,
        'reproducibility': {'status': True, 'scope': 'cross_run_same_target',
                            'source': 'series_records', 'evidence': ['SERIES_RECORDS.json']},
        'fresh_run': True,
        'target_generation': 3,
        'one_click': True,
        'manual_intervention': False,
        'no_admin': True,
        'offline': True,
        'integrity': True,
        'residual_risk': [],
    }


def sales_bundle(reviewer='human'):
    return {
        'evidence_kind': 'real_human' if reviewer == 'human' else 'model_proxy',
        'reviewer': {'kind': reviewer, 'id': 'reviewer-1'},
        'human_test_performed': reviewer == 'human',
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
            'description_contract': {'brand_price_independent': True},
        },
        'audience_summary_evidence': ['audience_summary.json', 'AUDIENCE_SUMMARY.txt'],
        'sessions': [{
            'session_id': 's1',
            'cold_start': True,
            'provenance': {'source': 'fresh_install', 'run_id': 'r1'},
            'phases': {
                'first_30_seconds': {'observed': True, 'status': 'pass', 'findings': []},
                'first_5_minutes': {'observed': True, 'status': 'pass', 'findings': []},
                'product_shelf_test': {'observed': True, 'status': 'pass', 'findings': []},
                'communication_readability': {'observed': True, 'status': 'pass', 'findings': []},
            },
        }],
    }


def write(root, name, payload):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    (root / name).write_text(json.dumps(payload), encoding='utf-8')
    return root


class FakeExecution:
    def __init__(self, root):
        self.root = Path(root)


class CoordinatorIndependenceTest(unittest.TestCase):
    def test_one_hq_pass_cannot_hide_another_not_run(self):
        coordinator = Coordinator('.')
        coordinator.register('production', lambda context: DomainReport.from_results(
            'production', [{'test_case': 'unit', 'status': 'PASS', 'gate': 'REQUIRED',
                            'evidence': ['unit.json']}]))
        summary = coordinator.evaluate(CoordinatorContext(root='.'))
        statuses = {domain.name: domain.status for domain in summary.domains}
        self.assertEqual(statuses['production'], 'PASS')
        self.assertNotEqual(statuses['management'], 'PASS')
        self.assertNotEqual(statuses['sales'], 'PASS')
        self.assertFalse(summary.accepted)
        self.assertNotEqual(summary.overall, 'PASS')
        blocked = {entry['domain'] for entry in summary.blocked_by}
        self.assertEqual(blocked, {'management', 'sales'})

    def test_production_meaning_is_unchanged_by_the_new_domains(self):
        context = CoordinatorContext(root='.', results=[
            {'test_case': 'unit', 'status': 'PASS', 'gate': 'REQUIRED', 'evidence': ['unit.json']}])
        report = production_evaluator(context)
        self.assertEqual(report.name, 'production')
        self.assertEqual(report.status, 'PASS')
        self.assertEqual(report.gates, [])
        self.assertFalse(report.certifies_real_target)

    def test_evaluator_exception_fails_closed_and_isolates_its_own_domain(self):
        def boom(context):
            raise RuntimeError('evaluator exploded')

        coordinator = Coordinator('.')
        coordinator.register('production', lambda context: DomainReport.from_results(
            'production', [{'test_case': 'unit', 'status': 'PASS', 'gate': 'REQUIRED',
                            'evidence': ['unit.json']}]))
        coordinator.register('management', boom)
        summary = coordinator.evaluate(CoordinatorContext(root='.'))
        statuses = {domain.name: domain.status for domain in summary.domains}
        self.assertEqual(statuses['management'], 'HARNESS_ERROR')
        self.assertEqual(statuses['production'], 'PASS')
        self.assertNotEqual(statuses['sales'], 'PASS')
        self.assertFalse(summary.accepted)
        reason = [domain.reason_code for domain in summary.domains
                  if domain.name == 'management'][0]
        self.assertEqual(reason, 'HQ_EVALUATOR_EXCEPTION')

    def test_missing_evaluator_can_never_pass(self):
        coordinator = Coordinator('.')
        coordinator._evaluators.pop('sales')
        summary = coordinator.evaluate(CoordinatorContext(root='.'))
        statuses = {domain.name: domain.status for domain in summary.domains}
        self.assertEqual(statuses['sales'], 'HARNESS_ERROR')
        self.assertNotEqual(statuses['sales'], 'PASS')
        self.assertFalse(summary.accepted)

    def test_domain_name_mismatch_is_isolated(self):
        coordinator = Coordinator('.')
        coordinator.register('management', lambda context: DomainReport('sales', 'PASS'))
        summary = coordinator.evaluate(CoordinatorContext(root='.'))
        statuses = {domain.name: domain.status for domain in summary.domains}
        self.assertEqual(statuses['management'], 'HARNESS_ERROR')
        self.assertEqual(statuses['sales'], 'NOT_RUN')

    def test_not_run_evaluator_still_produces_a_visible_readback(self):
        from coordinator import MANAGEMENT_NOT_RUN, not_run_evaluator
        coordinator = Coordinator('.')
        coordinator.register('management', not_run_evaluator('management', MANAGEMENT_NOT_RUN))
        summary = coordinator.evaluate(CoordinatorContext(root='.'))
        readback = summary.readback('management')
        self.assertIsNotNone(readback)
        self.assertEqual(readback['status'], 'NOT_RUN')
        self.assertEqual(readback['reason_code'], MANAGEMENT_NOT_RUN)
        data = coordinator.attach({}, summary)
        self.assertIn('management_readback', data)
        self.assertNotEqual(summary.domains[1].status, 'PASS')

    def test_all_three_domains_are_always_present(self):
        summary = Coordinator('.').evaluate(CoordinatorContext(root='.'))
        self.assertEqual([domain.name for domain in summary.domains], list(DOMAIN_ORDER))


class ReadbackAttachmentTest(unittest.TestCase):
    def test_readbacks_are_attached_by_the_coordinator(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(tmp, MANAGEMENT_EVIDENCE, management_bundle())
            write(tmp, SALES_EVIDENCE, sales_bundle())
            coordinator = Coordinator(tmp, settings={'management_thresholds': THRESHOLDS})
            summary = coordinator.evaluate(CoordinatorContext(
                root=tmp, settings={'management_thresholds': THRESHOLDS},
                extras={'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}))
            data = coordinator.attach({}, summary)
        self.assertIn('management_readback', data)
        self.assertIn('sales_readback', data)
        self.assertEqual(data['management_readback']['domain'], 'management')
        self.assertEqual(data['sales_readback']['domain'], 'sales')
        json.dumps(data)

    def test_readbacks_are_attached_by_the_execution_finalizer(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(tmp, MANAGEMENT_EVIDENCE, management_bundle())
            write(tmp, SALES_EVIDENCE, sales_bundle())
            attach = execution_finalizer(tmp, None, settings={'management_thresholds': THRESHOLDS})
            data = {'results': [], 'completion_certified': True}
            attach(FakeExecution(tmp), data)
        self.assertIn('management_readback', data)
        self.assertIn('sales_readback', data)
        self.assertIn('headquarters', data)
        domains = {domain['name']: domain['status'] for domain in data['headquarters']['domains']}
        self.assertEqual(set(domains), {'production', 'management', 'sales'})

    def test_finalizer_reads_current_run_evidence_not_stale_package_root(self):
        with tempfile.TemporaryDirectory() as package, tempfile.TemporaryDirectory() as run:
            stale = management_bundle()
            stale['measurements']['ram_mb'] = {'value': 99999, 'unit': 'mb'}
            write(package, MANAGEMENT_EVIDENCE, stale)
            write(run, MANAGEMENT_EVIDENCE, management_bundle())
            write(run, SALES_EVIDENCE, sales_bundle())
            attach = execution_finalizer(package, None, settings={'management_thresholds': THRESHOLDS})
            data = {'results': []}
            attach(FakeExecution(run), data)
            readback = data['management_readback']
            self.assertTrue(readback['evidence_present'])
            self.assertNotEqual(readback['measurements']['ram_mb']['value'], 99999)
            self.assertTrue(data['sales_readback']['evidence_present'])

    def test_run_without_evidence_cannot_reuse_package_root_bundle(self):
        with tempfile.TemporaryDirectory() as package, tempfile.TemporaryDirectory() as run:
            write(package, MANAGEMENT_EVIDENCE, management_bundle())
            write(package, SALES_EVIDENCE, sales_bundle())
            data = {'results': []}
            execution_finalizer(package, None)(FakeExecution(run), data)
            self.assertFalse(data['management_readback']['evidence_present'])
            self.assertFalse(data['sales_readback']['evidence_present'])

    def test_readbacks_are_attached_before_the_result_model_is_sealed(self):
        from common import write_json
        with tempfile.TemporaryDirectory() as tmp:
            write(tmp, MANAGEMENT_EVIDENCE, management_bundle())
            write(tmp, SALES_EVIDENCE, sales_bundle())
            attach = execution_finalizer(tmp, None, settings={'management_thresholds': THRESHOLDS})
            data = {'results': []}
            attach(FakeExecution(tmp), data)
            target = Path(tmp) / 'result.json'
            write_json(target, data)
            stored = json.loads(target.read_text(encoding='utf-8'))
        self.assertIn('management_readback', stored)
        self.assertIn('sales_readback', stored)

    def test_attach_readbacks_is_idempotent_and_does_not_lose_other_keys(self):
        summary = Coordinator('.').evaluate(CoordinatorContext(root='.'))
        data = {'keep': 'me'}
        attach_readbacks(data, summary)
        first = dict(data)
        attach_readbacks(data, summary)
        self.assertEqual(data['keep'], 'me')
        self.assertEqual(set(first), set(data))

    def test_persisted_readback_is_not_reconsumed_as_fresh_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            coordinator = Coordinator(tmp)
            first = coordinator.evaluate(CoordinatorContext(root=tmp, results=[]))
            data = coordinator.attach({'overall': 'PASS', 'results': []}, first)
            target = Path(tmp) / 'result.json'
            target.write_text(json.dumps(data), encoding='utf-8')
            attach_summary_to_result_file(target, root=tmp)
            stored = json.loads(target.read_text(encoding='utf-8'))
        statuses = {d['name']: d['status'] for d in stored['headquarters']['domains']}
        self.assertEqual(statuses['management'], 'NOT_RUN')
        self.assertEqual(statuses['sales'], 'NOT_RUN')


class CompletionGuardTest(unittest.TestCase):
    def test_completion_cannot_be_accepted_while_hq_is_unresolved(self):
        coordinator = Coordinator('.')
        summary = coordinator.evaluate(CoordinatorContext(root='.'))
        data = coordinator.attach({'completion_certified': True}, summary)
        self.assertFalse(data['completion_certified'])

    def test_completion_stays_false_when_one_domain_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(tmp, MANAGEMENT_EVIDENCE, management_bundle())
            write(tmp, SALES_EVIDENCE, sales_bundle())
            coordinator = Coordinator(tmp, settings={'management_thresholds': THRESHOLDS})
            coordinator.register('sales', lambda context: DomainReport.from_results(
                'sales', [{'test_case': 'sales.x', 'status': 'FAIL', 'gate': 'REQUIRED',
                           'reason_code': 'SALES_FAILED', 'evidence': ['e.json']}]))
            summary = coordinator.evaluate(CoordinatorContext(root=tmp))
            data = coordinator.attach({'completion_certified': True}, summary)
        self.assertFalse(data['completion_certified'])
        self.assertFalse(summary.accepted)

    def test_target_qa_certification_is_not_granted_without_a_real_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            attach = execution_finalizer(tmp, None)
            data = {'results': []}
            attach(FakeExecution(tmp), data)
        self.assertFalse(data.get('target_qa_certified', False))


class HumanTestGuardTest(unittest.TestCase):
    def test_a_proxy_review_never_promotes_human_test_performed(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(tmp, SALES_EVIDENCE, sales_bundle(reviewer='model_proxy'))
            coordinator = Coordinator(tmp)
            summary = coordinator.evaluate(CoordinatorContext(root=tmp))
            data = coordinator.attach({'human_test_performed': True}, summary)
        self.assertFalse(data['human_test_performed'])
        self.assertEqual(data.get('human_test_note'), HUMAN_TEST_CLAIM_REVOKED +
                         ': the Sales evaluation found no real human review evidence')
        self.assertFalse(summary.readback('sales')['human_test_performed'])

    def test_a_real_human_review_does_not_get_revoked(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(tmp, SALES_EVIDENCE, sales_bundle(reviewer='human'))
            coordinator = Coordinator(tmp)
            summary = coordinator.evaluate(CoordinatorContext(root=tmp))
            data = coordinator.attach({'human_test_performed': True}, summary)
        self.assertTrue(data['human_test_performed'])


class SourceTestPromotionTest(unittest.TestCase):
    def test_source_tests_cannot_promote_product_acceptance_or_stable(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(tmp, MANAGEMENT_EVIDENCE, management_bundle())
            write(tmp, SALES_EVIDENCE, sales_bundle())
            coordinator = Coordinator(tmp, settings={'management_thresholds': THRESHOLDS})
            summary = coordinator.evaluate(CoordinatorContext(
                root=tmp, settings={'management_thresholds': THRESHOLDS},
                extras={'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}))
            data = coordinator.attach({}, summary)
        for key in ('product_accepted', 'product_acceptance', 'stable', 'release_approved',
                    'release_approved'):
            self.assertNotIn(key, data)
            self.assertNotEqual(data.get(key), True)
        certifications = data['sales_readback']['certifications']
        self.assertFalse(certifications['product_accepted']['granted'])
        self.assertFalse(certifications['stable']['granted'])
        self.assertFalse(certifications['release_approved']['granted'])
        self.assertFalse(data.get('completion_certified', False))

    def test_completion_can_be_certified_only_when_every_domain_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(tmp, MANAGEMENT_EVIDENCE, management_bundle())
            write(tmp, SALES_EVIDENCE, sales_bundle())
            coordinator = Coordinator(tmp, settings={'management_thresholds': THRESHOLDS})
            coordinator.register('production', lambda context: DomainReport.from_results(
                'production', [{'test_case': 'unit', 'status': 'PASS', 'gate': 'REQUIRED',
                                'evidence': ['unit.json']}]))
            summary = coordinator.evaluate(CoordinatorContext(
                root=tmp, settings={'management_thresholds': THRESHOLDS},
                extras={'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}))
            statuses = {domain.name: domain.status for domain in summary.domains}
            data = coordinator.attach({'completion_certified': True}, summary)
        self.assertEqual(statuses['production'], 'PASS')
        self.assertEqual(statuses['management'], 'PASS')
        self.assertEqual(statuses['sales'], 'PASS')
        self.assertTrue(summary.accepted)
        self.assertTrue(data['completion_certified'])

    def test_completion_is_not_certified_even_with_complete_sales_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(tmp, MANAGEMENT_EVIDENCE, management_bundle())
            write(tmp, SALES_EVIDENCE, sales_bundle())
            coordinator = Coordinator(tmp, settings={'management_thresholds': THRESHOLDS})
            summary = coordinator.evaluate(CoordinatorContext(
                root=tmp, settings={'management_thresholds': THRESHOLDS},
                extras={'target_identity': {'demo': {'generation': 3, 'fingerprint': 'abc'}}}))
            statuses = {domain.name: domain.status for domain in summary.domains}
            self.assertEqual(statuses['sales'], 'PASS')
            self.assertNotEqual(statuses['production'], 'PASS')
            self.assertFalse(summary.accepted)


if __name__ == '__main__':
    unittest.main()
