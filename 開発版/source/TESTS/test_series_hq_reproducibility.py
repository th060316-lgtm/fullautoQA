"""Contract for the cross-run Management observation.

Issue #1 requires the Management headquarters to prove that a target behaves
reproducibly.  The evaluator only accepted the scope ``same_run_seed_replay``
- a replay of the same seed inside one run - while the evidence that Issue #1
actually asks for is the A -> B -> A series: the *same target* executed twice
with the same required-case digest.

The evaluator was deliberately NOT relaxed.  Instead the series produces a
``cross_run_same_target`` observation, and the evaluator keeps refusing the
old scope.  Both halves are asserted here.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve()
SOURCE_ROOT = _HERE.parents[1]
_REPO_ROOT = _HERE.parents[3]


def _acceptance_roots():
    """Candidate locations of the acceptance bundle.

    In a prepared Source tree the acceptance bundle is overlaid as
    ``ACCEPTANCE``; in the repository checkout it lives under the non-ASCII
    source-root directory.  Both are tried so that the contract runs against
    the tree that actually ships.
    """
    candidates = [SOURCE_ROOT / 'ACCEPTANCE']
    if _REPO_ROOT != SOURCE_ROOT:
        candidates.append(_REPO_ROOT / '開発版' / 'acceptance_targets')
    for candidate in candidates:
        if (candidate / 'run_series.py').is_file():
            if str(candidate) not in sys.path:
                sys.path.insert(0, str(candidate))
            break
    return candidates


_acceptance_roots()
if str(SOURCE_ROOT / 'CORE') not in sys.path:
    sys.path.insert(0, str(SOURCE_ROOT / 'CORE'))

try:
    import run_series
except ImportError:  # pragma: no cover - the acceptance targets are not always present
    run_series = None


def _record(run_id, target_key='target-1', digest='digest-a', nonpass=()):
    return {
        'index': 0,
        'run_id': run_id,
        'target_key': target_key,
        'required_case_digest': digest,
        'required_case_count': 3,
        'required_nonpass': list(nonpass),
    }


class CrossRunReproducibilityTests(unittest.TestCase):
    @unittest.skipIf(run_series is None, 'the acceptance targets are not present')
    def test_two_agreeing_runs_of_the_same_target_are_reproducible(self):
        observation = run_series.cross_run_reproducibility(
            [_record('a1'), _record('a2')])
        self.assertEqual('cross_run_same_target', observation['scope'])
        self.assertTrue(observation['status'])
        self.assertEqual([], observation['reasons'])
        self.assertEqual(['a1', 'a2'], observation['run_ids'])

    @unittest.skipIf(run_series is None, 'the acceptance targets are not present')
    def test_two_disagreeing_runs_of_the_same_target_are_not_reproducible(self):
        observation = run_series.cross_run_reproducibility(
            [_record('a1', digest='digest-a'), _record('a2', digest='digest-b')])
        self.assertFalse(observation['status'])
        self.assertIn('REQUIRED_CASE_DIGEST_DIVERGED', observation['reasons'])

    @unittest.skipIf(run_series is None, 'the acceptance targets are not present')
    def test_a_missing_digest_is_never_reproducible(self):
        observation = run_series.cross_run_reproducibility(
            [_record('a1', digest=None), _record('a2', digest=None)])
        self.assertFalse(observation['status'])
        self.assertIn('REQUIRED_CASE_DIGEST_ABSENT', observation['reasons'])

    @unittest.skipIf(run_series is None, 'the acceptance targets are not present')
    def test_a_required_case_that_did_not_pass_blocks_the_observation(self):
        observation = run_series.cross_run_reproducibility(
            [_record('a1', nonpass=[{'case': 'x', 'status': 'NOT_RUN'}]),
             _record('a2', nonpass=[{'case': 'x', 'status': 'NOT_RUN'}])])
        self.assertFalse(observation['status'])
        self.assertIn('REQUIRED_CASE_NOT_PASSED', observation['reasons'])

    @unittest.skipIf(run_series is None, 'the acceptance targets are not present')
    def test_a_single_run_produces_no_cross_run_observation(self):
        observation = run_series.cross_run_reproducibility([_record('a1')])
        self.assertFalse(observation['status'])
        self.assertIn('CROSS_RUN_SAMPLE_INSUFFICIENT', observation['reasons'])

    @unittest.skipIf(run_series is None, 'the acceptance targets are not present')
    def test_two_different_targets_are_not_a_cross_run_observation(self):
        observation = run_series.cross_run_reproducibility(
            [_record('a1', target_key='target-1'), _record('b1', target_key='target-2')])
        self.assertFalse(observation['status'])
        self.assertIn('CROSS_RUN_SAMPLE_INSUFFICIENT', observation['reasons'])

    @unittest.skipIf(run_series is None, 'the acceptance targets are not present')
    def test_the_evaluator_refuses_the_old_scope_and_accepts_the_series_scope(self):
        import json
        import tempfile

        from coordinator import CoordinatorContext
        from management_evaluator import evaluate_management

        bundle = {
            'evidence_kind': 'real_game',
            'game': {'id': 'game-1', 'title': 'Game', 'genre': 'g'},
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
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for scope, expected in (('same_run_seed_replay', 'INCONCLUSIVE'),
                                    ('invented_scope', 'INCONCLUSIVE'),
                                    (None, 'INCONCLUSIVE'),
                                    ('cross_run_same_target', 'PASS')):
                payload = dict(bundle)
                payload['reproducibility'] = {
                    'status': True, 'scope': scope, 'source': 'series_records',
                    'evidence': ['SERIES_RECORDS.json'],
                }
                (root / 'management_evidence.json').write_text(
                    json.dumps(payload), encoding='utf-8')
                report = evaluate_management(CoordinatorContext(
                    root=root, results=(), settings={}, extras={}))
                recorded = report.readback['signals']['reproducibility']
                self.assertEqual(expected, recorded['status'], 'scope ' + scope)
                self.assertEqual(scope, recorded['scope'])

    @unittest.skipIf(run_series is None, 'the acceptance targets are not present')
    def test_the_series_writes_a_readback_file(self):
        source = Path(run_series.__file__).read_text(encoding='utf-8')
        self.assertIn('SERIES_HQ_READBACK.json', source)
        self.assertIn('ENVIRONMENT_AUDIT.json', source)
        self.assertIn('cross_run_same_target', source)


if __name__ == '__main__':
    unittest.main()
