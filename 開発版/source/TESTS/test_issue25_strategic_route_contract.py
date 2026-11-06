import unittest
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SOURCE_ROOT.parents[1]


class Issue25StrategicRouteContractTests(unittest.TestCase):
    def test_prepare_source_uses_declared_recovery_input_not_repository_recursion(self):
        text = (SOURCE_ROOT / "scripts" / "PREPARE_SOURCE.ps1").read_text(encoding="utf-8")
        self.assertIn("TRANSFER_MANIFEST.json", text)
        self.assertIn("RECOVERY_SOURCE_SHA256_MISMATCH", text)
        self.assertIn("Resolve-RepositoryRelativePath", text)
        self.assertNotIn(
            "Get-ChildItem -LiteralPath $RepositoryRoot -Recurse",
            text,
            "Recovery-source discovery must not recursively search the mutable repository root",
        )

    def test_local_route_separates_repository_workspace_and_evidence_roots(self):
        text = (REPO_ROOT / "RUN_LOCAL_COMPLETION.ps1").read_text(encoding="utf-8")
        self.assertIn("PhysicalWorkRoot = Join-Path ([IO.Path]::GetTempPath())", text)
        self.assertIn("WorkDrive = New-RepoDrive $PhysicalWorkRoot", text)
        self.assertIn("WorkRoot = ($WorkDrive + '\\')", text)
        self.assertIn("PhysicalOutRoot = Join-Path $repoParent", text)
        self.assertNotIn("Join-Path $RepoRoot ('.fqa_work_'", text)
        self.assertNotIn("Join-Path $RepoRoot ('LOCAL_FINAL_ACCEPTANCE_'", text)

        live = text.split("try {", 1)[1]
        self.assertNotIn(
            "Find-RepositoryFile -Root $RepoRoot",
            live,
            "The live completion route must resolve declared repository inputs, not discover them recursively",
        )
        self.assertIn("TRANSFER_MANIFEST.json", live)
        self.assertIn("Resolve-RepositoryRelativePath", live)

    def test_candidate_identity_is_bound_to_the_prepared_source_tree(self):
        runner = (REPO_ROOT / "RUN_LOCAL_COMPLETION.ps1").read_text(encoding="utf-8")
        rebuild = (SOURCE_ROOT / "scripts" / "PHASE3_OVERLAY_REBUILD.ps1").read_text(encoding="utf-8")
        self.assertIn("prepared_source_fingerprint", runner)
        self.assertIn("'-SourceBaseline',$Summary.prepared_source_fingerprint", runner)
        self.assertIn("SOURCE_BASELINE_MISMATCH", rebuild)
        self.assertIn("prepared_source_fingerprint=$actualSourceFingerprint", rebuild)


if __name__ == "__main__":
    unittest.main()
