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
