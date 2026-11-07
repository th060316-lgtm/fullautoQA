"""Contract for the persistent-environment observation.

Issue #1 asks for acceptance evidence that the run does not permanently change
Program Files, the Registry or PATH.  The rule under test is the one that
matters most: **an observation that did not happen is never reported as
"unchanged"**, and never as a pass.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE_ROOT / 'CORE'))

from environment_audit import (compare_observations, environment_audit_comparison,  # noqa: E402
                               environment_audit_snapshot, program_files_audit,
                               registry_environment_audit)


class EnvironmentAuditContractTests(unittest.TestCase):
    def test_a_missing_measurement_is_never_reported_as_unchanged(self):
        self.assertEqual('NOT_MEASURED',
                         compare_observations({'status': 'NOT_MEASURED'},
                                              {'status': 'NOT_MEASURED'}))
        self.assertEqual('NOT_MEASURED',
                         compare_observations({'status': 'MEASURED', 'digest': 'a'},
                                              {'status': 'NOT_MEASURED'}))
        self.assertEqual('NOT_MEASURED', compare_observations(None, None))

    def test_an_unchanged_measurement_is_reported_as_unchanged(self):
        observation = {'status': 'MEASURED', 'digest': 'abc'}
        self.assertEqual('UNCHANGED', compare_observations(observation, dict(observation)))

    def test_a_changed_measurement_requires_review(self):
        self.assertEqual('CHANGED_REQUIRES_REVIEW',
                         compare_observations({'status': 'MEASURED', 'digest': 'a'},
                                              {'status': 'MEASURED', 'digest': 'b'}))

    def test_the_comparison_is_not_measured_when_either_side_is_missing(self):
        before = {'registry_environment': {'status': 'NOT_MEASURED'},
                  'program_files': {'status': 'MEASURED', 'digest': 'x'}}
        after = {'registry_environment': {'status': 'MEASURED', 'digest': 'x'},
                 'program_files': {'status': 'MEASURED', 'digest': 'x'}}
        comparison = environment_audit_comparison(before, after)
        self.assertEqual('NOT_MEASURED', comparison['registry_environment_status'])
        self.assertEqual('UNCHANGED', comparison['program_files_status'])
        self.assertEqual('NOT_MEASURED', comparison['status'])

    def test_the_comparison_reports_a_change_for_review(self):
        before = {'registry_environment': {'status': 'MEASURED', 'digest': 'a'},
                  'program_files': {'status': 'MEASURED', 'digest': 'x'}}
        after = {'registry_environment': {'status': 'MEASURED', 'digest': 'b'},
                 'program_files': {'status': 'MEASURED', 'digest': 'x'}}
        comparison = environment_audit_comparison(before, after)
        self.assertEqual('CHANGED_REQUIRES_REVIEW', comparison['registry_environment_status'])
        self.assertEqual('CHANGED_REQUIRES_REVIEW', comparison['status'])

    def test_the_observations_state_their_own_scope(self):
        registry = registry_environment_audit()
        program_files = program_files_audit()
        self.assertIn('scope', registry)
        self.assertIn('not a complete Registry write audit', registry['scope'])
        self.assertIn('scope', program_files)
        self.assertIn('not a recursive content audit', program_files['scope'])

    def test_runner_does_not_promote_bounded_observations_to_full_write_audits(self):
        runner = Path(__file__).resolve().parents[3] / 'RUN_LOCAL_COMPLETION.ps1'
        text = runner.read_text(encoding='utf-8')
        self.assertIn("registry_write_audit = 'NOT_MEASURED'", text)
        self.assertIn("program_files_write_audit = 'NOT_MEASURED'", text)
        self.assertIn('$Summary.registry_environment_audit=', text)
        self.assertIn('$Summary.program_files_top_level_audit=', text)
        self.assertNotIn(
            '$Summary.registry_write_audit=[string]$environmentAudit.comparison.registry_environment_status',
            text,
        )
        self.assertNotIn(
            '$Summary.program_files_write_audit=[string]$environmentAudit.comparison.program_files_status',
            text,
        )

    def test_the_snapshot_carries_both_observations(self):
        snapshot = environment_audit_snapshot()
        self.assertIn('registry_environment', snapshot)
        self.assertIn('program_files', snapshot)


if __name__ == '__main__':
    unittest.main()
