import unittest
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[1]


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

    def test_candidate_builder_binds_identity_to_the_prepared_source_tree(self):
        rebuild = (SOURCE_ROOT / "scripts" / "PHASE3_OVERLAY_REBUILD.ps1").read_text(encoding="utf-8")
        self.assertIn("$actualSourceFingerprint=Get-TreeFingerprint $src", rebuild)
        self.assertIn("SOURCE_BASELINE_MISMATCH", rebuild)
        self.assertIn("source_baseline=$actualSourceFingerprint", rebuild)
        self.assertIn("prepared_source_fingerprint=$actualSourceFingerprint", rebuild)


if __name__ == "__main__":
    unittest.main()
