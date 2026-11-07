"""Contract for the review-evidence intake.

The Sales headquarters must be able to consume a review that was produced
outside the automated run - a human cold-start playtest or a validated review
analyser - without ever confusing the two.

The two rules under test:

* a model proxy is never promoted to a human;
* evidence that is absent or malformed stays absent and is reported, never
  guessed at and never turned into a PASS.
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE_ROOT / 'CORE'))

import review_intake  # noqa: E402
from review_intake import (load_review_evidence, materialize_review_evidence,  # noqa: E402
                            merge_review_evidence, sanitize_sales_bundle,
                            validate_review_evidence)


def _review(reviewer_kind='human', human_test=True, run_id='run-1'):
    return {
        'schema_version': 1,
        'run_id': run_id,
        'reviewer': {'kind': reviewer_kind, 'id': 'reviewer-1'},
        'human_test_performed': human_test,
        'sessions': [{
            'session_id': run_id,
            'cold_start': True,
            'provenance': {'source': 'external_review'},
            'phases': {
                'first_30_seconds': {'status': 'PASS', 'findings': [],
                                     'evidence': ['session-01']},
                'first_5_minutes': {'status': 'INCONCLUSIVE', 'findings': [],
                                    'evidence': ['session-01']},
            },
        }],
    }


class ReviewIntakeContractTests(unittest.TestCase):
    def test_a_human_review_is_accepted_and_keeps_the_reviewer_kind(self):
        normalized, problems = validate_review_evidence(_review(), run_id='run-1')
        self.assertEqual([], problems)
        self.assertEqual('human', normalized['reviewer']['kind'])
        self.assertTrue(normalized['human_test_performed'])

    def test_a_proxy_review_is_accepted_but_never_becomes_a_human(self):
        normalized, problems = validate_review_evidence(
            _review(reviewer_kind='model_proxy', human_test=True), run_id='run-1')
        self.assertEqual([], problems)
        self.assertEqual('model_proxy', normalized['reviewer']['kind'])
        bundle, _ = merge_review_evidence({'human_test_performed': False}, normalized)
        self.assertFalse(bundle['human_test_performed'])
        self.assertEqual('model_proxy', bundle['reviewer']['kind'])
        self.assertEqual('model_proxy', bundle['evidence_kind'])

    def test_a_human_review_may_set_the_human_test_flag(self):
        normalized, _ = validate_review_evidence(_review(), run_id='run-1')
        bundle, _ = merge_review_evidence({'human_test_performed': False}, normalized)
        self.assertTrue(bundle['human_test_performed'])
        self.assertEqual('human', bundle['reviewer']['kind'])

    def test_a_human_test_claim_requires_reviewer_identity_and_cold_start_provenance(self):
        document = _review()
        document['reviewer']['id'] = ''
        document['sessions'][0]['cold_start'] = False
        document['sessions'][0]['provenance'] = {}
        normalized, problems = validate_review_evidence(document, run_id='run-1')
        self.assertIsNone(normalized)
        self.assertIn('REVIEW_EVIDENCE_HUMAN_REVIEWER_ID_MISSING', problems)
        self.assertIn('REVIEW_EVIDENCE_HUMAN_COLD_START_MISSING', problems)

    def test_a_human_test_claim_requires_cold_start_provenance(self):
        document = _review()
        document['sessions'][0]['provenance'] = {}
        normalized, problems = validate_review_evidence(document, run_id='run-1')
        self.assertIsNone(normalized)
        self.assertIn('REVIEW_EVIDENCE_HUMAN_PROVENANCE_MISSING', problems)

    def test_an_unknown_reviewer_kind_is_rejected(self):
        normalized, problems = validate_review_evidence(
            _review(reviewer_kind='wizard'), run_id='run-1')
        self.assertIsNone(normalized)
        self.assertIn('REVIEW_EVIDENCE_REVIEWER_KIND_UNKNOWN', problems)

    def test_a_phase_without_an_outcome_is_rejected(self):
        document = _review()
        document['sessions'][0]['phases']['first_30_seconds'] = {'notes': 'looked fine'}
        normalized, problems = validate_review_evidence(document, run_id='run-1')
        self.assertIsNone(normalized)
        self.assertIn('REVIEW_EVIDENCE_PHASE_OUTCOME_MISSING:first_30_seconds', problems)

    def test_a_positive_phase_without_evidence_reference_is_rejected(self):
        document = _review()
        document['sessions'][0]['phases']['first_30_seconds']['evidence'] = []
        normalized, problems = validate_review_evidence(document, run_id='run-1')
        self.assertIsNone(normalized)
        self.assertIn('REVIEW_EVIDENCE_PHASE_EVIDENCE_MISSING:first_30_seconds', problems)

    def test_a_review_for_another_run_is_rejected(self):
        normalized, problems = validate_review_evidence(_review(run_id='other'), run_id='run-1')
        self.assertIsNone(normalized)
        self.assertIn('REVIEW_EVIDENCE_RUN_ID_MISMATCH:other', problems)

    def test_a_missing_review_leaves_the_bundle_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            normalized, problems, source = load_review_evidence(Path(tmp), run_id='run-1')
        self.assertIsNone(normalized)
        self.assertEqual([], problems)
        self.assertEqual('absent', source)

    def test_an_unreadable_review_is_reported_not_guessed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'review_evidence').mkdir()
            (root / 'review_evidence' / 'sales_review.json').write_text('{not json',
                                                                          encoding='utf-8')
            normalized, problems, source = load_review_evidence(root, run_id='run-1')
        self.assertIsNone(normalized)
        self.assertTrue(problems)
        self.assertEqual('default', source)
    def test_review_and_attachments_are_materialized_into_run_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'input'
            run = root / 'run'
            source.mkdir()
            run.mkdir()
            document = _review()
            document['sessions'][0]['phases']['first_30_seconds']['evidence'] = ['capture/session-01.mp4']
            document['sessions'][0]['phases']['first_5_minutes']['evidence'] = ['capture/session-01.mp4']
            (source / 'capture').mkdir()
            (source / 'capture' / 'session-01.mp4').write_bytes(b'video-evidence')
            review_path = source / 'sales_review.json'
            review_path.write_text(json.dumps(document), encoding='utf-8')
            normalized, problems, _ = load_review_evidence(
                run, explicit_path=str(review_path), run_id='run-1')
            self.assertEqual([], problems)
            materialized, problems, files = materialize_review_evidence(normalized, run)
            self.assertEqual([], problems)
            self.assertIsNotNone(materialized)
            self.assertEqual('review_evidence/source_review.json', materialized['source'])
            self.assertIn('review_evidence/capture/session-01.mp4', files)
            self.assertEqual(
                ['review_evidence/capture/session-01.mp4'],
                materialized['sessions'][0]['phases']['first_30_seconds']['evidence'])
            self.assertEqual(
                b'video-evidence',
                (run / 'review_evidence' / 'capture' / 'session-01.mp4').read_bytes())
            self.assertTrue((run / 'review_evidence' / 'normalized_review.json').is_file())

    def test_missing_review_attachment_makes_review_unusable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'input'
            run = root / 'run'
            source.mkdir()
            run.mkdir()
            document = _review()
            document['sessions'][0]['phases']['first_30_seconds']['evidence'] = ['missing.mp4']
            document['sessions'][0]['phases']['first_5_minutes']['evidence'] = ['missing.mp4']
            review_path = source / 'sales_review.json'
            review_path.write_text(json.dumps(document), encoding='utf-8')
            normalized, problems, _ = load_review_evidence(
                run, explicit_path=str(review_path), run_id='run-1')
            self.assertEqual([], problems)
            materialized, problems, files = materialize_review_evidence(normalized, run)
            self.assertIsNone(materialized)
            self.assertTrue(any('ATTACHMENT_MISSING' in item for item in problems))
            self.assertIn('review_evidence/source_review.json', files)

    def test_a_forged_human_claim_is_rejected(self):
        bundle = {'reviewer': {'kind': 'model_proxy'}, 'human_test_performed': True}
        sanitized, notes = sanitize_sales_bundle(bundle)
        self.assertFalse(sanitized['human_test_performed'])
        self.assertTrue(notes)

    def test_a_genuine_human_claim_survives_sanitizing(self):
        bundle = {'reviewer': {'kind': 'human'}, 'human_test_performed': True}
        sanitized, notes = sanitize_sales_bundle(bundle)
        self.assertTrue(sanitized['human_test_performed'])
        self.assertEqual([], notes)

    def test_the_default_review_location_is_inside_the_evidence_root(self):
        self.assertFalse(review_intake.REVIEW_EVIDENCE_RELATIVE.startswith('/'))
        self.assertNotIn('..', review_intake.REVIEW_EVIDENCE_RELATIVE)


if __name__ == '__main__':
    unittest.main()
