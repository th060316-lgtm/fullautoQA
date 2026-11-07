"""Contract for the local-completion runner's entry and baseline behaviour.

These are the structural assertions that used to live inside the runner's own
PowerShell self-test.  A script that inspects its own source text can only
compare mojibake to mojibake under Windows PowerShell 5.1, which is how a
broken route survived CI.  They are therefore asserted here, from Python,
against the repository checkout.

The runner-level *behavioural* contracts (-RepositoryEntryContractTest and
-PreparedBaselineContractTest) remain in the runner and run on hosted Windows
PowerShell 5.1; they prove the route works, not that the text looks right.
"""
from __future__ import annotations

import unittest
from pathlib import Path


def _find_repository_root():
    for parent in Path(__file__).resolve().parents:
        if (parent / 'RUN_LOCAL_COMPLETION.ps1').is_file():
            return parent
    return None


REPO_ROOT = _find_repository_root()
RUNNER = REPO_ROOT / 'RUN_LOCAL_COMPLETION.ps1' if REPO_ROOT else None


@unittest.skipIf(RUNNER is None,
                 'the repository checkout is not present (prepared Source tree)')
class LocalCompletionRunnerContractTests(unittest.TestCase):
    def setUp(self):
        self.text = RUNNER.read_text(encoding='utf-8')

    def assertContains(self, needle, message):
        self.assertTrue(needle in self.text, message)

    def assertNotContains(self, needle, message):
        self.assertTrue(needle not in self.text, message)

    def test_bounded_environment_observations_do_not_become_full_write_audits(self):
        self.assertContains("registry_write_audit = 'NOT_MEASURED'",
                            'complete Registry write audit must stay NOT_MEASURED without complete evidence')
        self.assertContains("program_files_write_audit = 'NOT_MEASURED'",
                            'complete Program Files write audit must stay NOT_MEASURED without complete evidence')
        self.assertContains('$Summary.registry_environment_audit=',
                            'the bounded Registry observation must keep its own field')
        self.assertContains('$Summary.program_files_top_level_audit=',
                            'the bounded Program Files observation must keep its own field')
        self.assertNotContains('$Summary.registry_write_audit=[string]$environmentAudit.comparison.registry_environment_status',
                               'bounded Registry observation must not be promoted to the full write-audit claim')
        self.assertNotContains('$Summary.program_files_write_audit=[string]$environmentAudit.comparison.program_files_status',
                               'bounded Program Files observation must not be promoted to the full write-audit claim')

    def test_the_full_environment_claims_require_continuous_monitors(self):
        self.assertContains('RegNotifyChangeKeyValue',
                            'complete Registry evidence must come from a subtree change monitor')
        self.assertContains('IncludeSubdirectories = true',
                            'Program Files monitoring must be recursive')
        self.assertContains('OFFLINE_CONTINUOUS_REQUIREMENT_NONPASS',
                            'requested offline acceptance must require the continuous monitor')
        self.assertContains('REGISTRY_WRITE_AUDIT_NONPASS',
                            'the full Registry claim must block the local acceptance gate')
        self.assertContains('PROGRAM_FILES_WRITE_AUDIT_NONPASS',
                            'the full Program Files claim must block the local acceptance gate')
        self.assertContains('ENVIRONMENT_CHANGE_MONITOR.json',
                            'the continuous monitor must leave a preserved evidence artifact')

    def test_the_runner_resolves_its_inputs_through_the_shared_entry_contract(self):
        self.assertContains('REPOSITORY_ENTRY.ps1',
                            'the runner must dot-source the shared entry contract')
        self.assertContains('Get-DeclaredRepositoryEntries',
                            'the runner must resolve the declared inputs through the contract')
        self.assertContains('Get-RepositorySourceRoot',
                            'the runner must discover the source root structurally')

    def test_stage0_shared_entry_contract_owns_input_identity_preflight(self):
        entry = REPO_ROOT / '開発版' / 'source' / 'scripts' / 'REPOSITORY_ENTRY.ps1'
        text = entry.read_text(encoding='utf-8')
        self.assertIn('RECOVERY_SOURCE_SHA256_MISMATCH', text)
        self.assertIn('DONOR_DECLARATION_SHA256_MISMATCH', text)
        self.assertIn('DONOR_BLOCK_SIZE_MISMATCH', text)
        self.assertContains('Test-DeclaredRepositoryEntries -Entries $declaredEntries',
                            'the live Stage-0 route must call the shared aggregate preflight')

    def test_the_runner_does_not_write_its_work_or_evidence_under_the_repository(self):
        self.assertNotContains("Join-Path `$RepoRoot ('.fqa_work_'",
                               'the transient work tree must not live in the repository')
        self.assertNotContains("Join-Path `$RepoRoot ('LOCAL_FINAL_ACCEPTANCE_'",
                               'the preserved evidence must not live in the repository')

    def test_the_runner_keeps_the_work_root_on_a_separate_drive(self):
        self.assertContains('$PhysicalWorkRoot = Join-Path ([IO.Path]::GetTempPath())',
                            'the work root must be on the temporary drive')
        self.assertContains('$WorkDrive = New-RepoDrive $PhysicalWorkRoot',
                            'the work root must be mapped to a short drive path')

    def test_the_runner_does_not_search_the_whole_repository_for_the_recovery_input(self):
        self.assertNotContains('Find-RepositoryFile -Root $RepoRoot',
                               'the declared recovery input must not be discovered by recursion')

    def test_the_runner_passes_the_bound_baseline_to_the_candidate_builder(self):
        self.assertContains('prepared_source_fingerprint',
                            'the summary must carry the bound baseline')
        self.assertContains("'-SourceBaseline',$Summary.prepared_source_fingerprint",
                            'the builder must be given the bound baseline')

    def test_the_baseline_is_bound_after_the_acceptance_overlay(self):
        """The regression that made the route fail on a healthy tree.

        The baseline used to be the fingerprint of the tree BEFORE the
        acceptance bundle was copied in.  The Candidate builder hashes the
        tree AFTER the overlay, so the two could never agree and every run
        failed with SOURCE_BASELINE_MISMATCH for a reason unrelated to the
        Source.
        """
        start = self.text.index('function Initialize-PreparedSource')
        end = self.text.index('function Invoke-RepositoryEntryContractTest')
        body = self.text[start:end]
        overlay = body.index("Copy-Item -LiteralPath $acceptanceSource")
        fingerprint = body.index('Get-SourceTreeFingerprint $sourceRoot')
        self.assertLess(overlay, fingerprint,
                        'the baseline must be the fingerprint of the tree AFTER the overlay')

    def test_the_live_route_uses_the_shared_preparation_function(self):
        self.assertContains('Initialize-PreparedSource',
                            'the live route must use the shared preparation function')
        self.assertNotContains('$Summary.source_baseline=Get-SourceTreeFingerprint',
                               'the live route must not hash the tree outside the shared function')

    def test_cmd_entrypoint_forwards_offline_and_optional_series_review_manifest(self):
        cmd = (REPO_ROOT / 'RUN_LOCAL_COMPLETION.cmd').read_text(encoding='ascii')
        self.assertIn('-RequireOffline', cmd)
        self.assertIn('-SalesReviewEvidence "%~1"', cmd)
        self.assertIn('if not "%~1"==""', cmd)
        self.assertIn('LOCAL TECHNICAL ACCEPTANCE FINISHED.', cmd)
        self.assertNotIn('LOCAL FINAL COMPLETION FINISHED.', cmd)
    def test_the_runner_reports_the_hq_gates_without_promoting_them(self):
        self.assertContains('management_gate', 'the summary must carry the Management verdict')
        self.assertContains('sales_gate', 'the summary must carry the Sales verdict')
        self.assertContains('product_acceptance', 'the summary must carry the acceptance state')
        self.assertContains('stable', 'the summary must carry the stable state')

    def test_local_rollback_gate_reads_the_actual_qualification_schema(self):
        self.assertContains('$rollbackProof.snapshot_git_blob_identity',
                            'rollback must verify the historical snapshot identity')
        self.assertContains('$rollbackProof.donor_byte_identity',
                            'rollback must verify the preserved donor identity')
        self.assertContains('$rollbackProof.package_integrity',
                            'rollback must verify the rebuilt package integrity')
        self.assertContains('$rollbackProof.runnable_rollback_status',
                            'rollback must require the fresh predecessor selftest')
        self.assertNotContains('$rollbackProof.byte_identity',
                               'the local route must not read a field the qualification schema never emits')

    def test_compact_evidence_keeps_series_review_intake(self):
        self.assertContains("'SERIES_REVIEW_INTAKE.json'",
                            'review-intake failures must survive compact evidence export')

    def test_the_summary_declares_the_canonical_fingerprint_algorithm(self):
        self.assertContains('source_tree_fingerprint_algorithm',
                            'the summary must declare which fingerprint algorithm was used')

    def test_the_runner_rejects_an_elevated_session(self):
        self.assertContains('RUN_FROM_A_STANDARD_NON_ADMIN_WINDOWS_SESSION',
                            'the route must refuse an elevated session')


if __name__ == '__main__':
    unittest.main()
