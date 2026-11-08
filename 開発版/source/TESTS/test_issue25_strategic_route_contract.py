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

    def test_the_candidate_builder_uses_the_one_canonical_fingerprint_implementation(self):
        """There must be exactly ONE implementation of the Source-tree identity.

        Three copies used to exist - the runner, the Candidate builder and the
        CI workflow.  They agreed with each other but were not reproducible:
        the host newline and the culture-sensitive sort made the same tree
        hash differently on different machines, and bytecode caches were
        counted as Source.
        """
        rebuild = (SOURCE_ROOT / "scripts" / "PHASE3_OVERLAY_REBUILD.ps1").read_text(encoding="utf-8")
        self.assertIn("SOURCE_TREE_FINGERPRINT.ps1", rebuild)
        self.assertNotIn("-Recurse -File", rebuild,
                         "the builder must delegate to the canonical script, not hash a tree itself")
        self.assertIn("def fingerprint(", (SOURCE_ROOT / "scripts" / "source_tree_immutability.py")
                      .read_text(encoding="utf-8"))

    def test_the_prepared_source_script_uses_the_shared_entry_contract(self):
        text = (SOURCE_ROOT / "scripts" / "PREPARE_SOURCE.ps1").read_text(encoding="utf-8")
        self.assertIn("REPOSITORY_ENTRY.ps1", text)
        self.assertIn("Resolve-RepositoryRelativePath", text)

    def test_the_source_tree_fingerprint_script_is_the_canonical_one(self):
        script = SOURCE_ROOT / "scripts" / "SOURCE_TREE_FINGERPRINT.ps1"
        self.assertTrue(script.is_file())
        text = script.read_text(encoding="utf-8")
        self.assertIn("[StringComparer]::Ordinal", text)
        self.assertIn("relative-path-tab-size-tab-sha256", text)


if __name__ == "__main__":
    unittest.main()
