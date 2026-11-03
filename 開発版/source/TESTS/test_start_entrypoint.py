"""Exercise the actual cmd entrypoint with a diagnostic bootstrap on Windows."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.name == "nt", "Windows cmd/PowerShell entrypoint required")
class StartEntrypointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="qa entry ! ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "START_QA.cmd").write_bytes((ROOT / "START_QA.cmd").read_bytes())
        (self.root / "BOOTSTRAP.ps1").write_text(
            "@{start=$env:FULLAUTOQA_START_QA;fresh=$env:FULLAUTOQA_FRESH_EXTRACTION;"
            "id=$env:FULLAUTOQA_FRESH_EXTRACTION_ID} | ConvertTo-Json | "
            "Set-Content -LiteralPath (Join-Path $PSScriptRoot 'observed.json') -Encoding UTF8\nexit 0\n",
            encoding="utf-8")

    def start(self):
        env = dict(os.environ, FULLAUTOQA_FRESH_EXTRACTION="stale", FULLAUTOQA_FRESH_EXTRACTION_ID="old")
        result = subprocess.run(["cmd.exe", "/d", "/c", "START_QA.cmd"], cwd=self.root,
                                env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads((self.root / "observed.json").read_text(encoding="utf-8-sig"))

    def test_nonempty_marker_consumed_and_propagated_once(self):
        marker = self.root / "PHASE3_FRESH_EXTRACTION.marker"
        marker.write_text("fresh-identity-123\n", encoding="ascii")
        first = self.start()
        self.assertEqual(first, {"start": "1", "fresh": "1", "id": "fresh-identity-123"})
        self.assertFalse(marker.exists())
        second = self.start()
        self.assertFalse(second["fresh"])
        self.assertFalse(second["id"])

    def test_blank_marker_never_claims_fresh(self):
        (self.root / "PHASE3_FRESH_EXTRACTION.marker").write_text("\n", encoding="ascii")
        observed = self.start()
        self.assertFalse(observed["fresh"])
        self.assertFalse(observed["id"])

    def test_missing_marker_clears_inherited_fresh_state(self):
        observed = self.start()
        self.assertEqual(observed["start"], "1")
        self.assertFalse(observed["fresh"])
        self.assertFalse(observed["id"])

    def test_real_bootstrap_corruption_produces_valid_diagnostic_zip(self):
        import hashlib
        import zipfile
        (self.root / "BOOTSTRAP.ps1").write_bytes((ROOT / "BOOTSTRAP.ps1").read_bytes())
        (self.root / "acceptance_manifest.json").write_text(json.dumps({"paths": {"results": "RESULTS"}}))
        (self.root / "sentinel").write_bytes(b"actual")
        (self.root / "core_manifest.json").write_text(json.dumps({"files": [
            {"path": "sentinel", "size": 6, "sha256": "0" * 64}]}))
        result = subprocess.run(["cmd.exe", "/d", "/c", "START_QA.cmd"], cwd=self.root,
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        archives = list((self.root / "RESULTS").glob("bootstrap_*/RESULT_FOR_CHATGPT.zip"))
        self.assertEqual(len(archives), 1, result.stdout + result.stderr)
        with zipfile.ZipFile(archives[0]) as archive:
            self.assertIsNone(archive.testzip())
            report = json.loads(archive.read("result.json").decode("utf-8-sig"))
            self.assertEqual(report["overall"], "HARNESS_ERROR")
            self.assertFalse(report["completion_certified"])
            self.assertIn("CORE hash: sentinel", report["results"][0]["detail"])
            manifest = json.loads(archive.read("evidence_manifest.json").decode("utf-8-sig"))
            for row in manifest:
                content = archive.read(row["file"])
                self.assertEqual(hashlib.sha256(content).hexdigest(), row["sha256"])
                self.assertEqual(len(content), row["size"])
