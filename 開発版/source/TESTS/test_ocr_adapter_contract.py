import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "CORE"))

from adapters import Adapter
from common import Evidence
from windows_runner import Session


class Desktop:
    def state(self):
        return {"exists": True, "focused": True, "rect": [10, 20, 210, 120]}

    def focus(self):
        return None

    def perform(self, item):
        return None


class OcrAdapterContractTests(unittest.TestCase):
    def test_profile_must_explicitly_request_ocr(self):
        with patch("adapters.OculixOCR.supported", return_value=True):
            adapter = Adapter(
                {"observations": ["window"], "actions": {}},
                {"desktop": Desktop(), "tools": Mock(), "work": Path("."), "evidence": None},
            )
            self.assertFalse(adapter.capabilities()["ocr"])

    def test_passed_ocr_is_exposed_as_external_text_with_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            backend = Mock()
            backend.read.return_value = {
                "status": "PASS",
                "reason_code": "OCR_CAPTURE_COMPLETED",
                "text": "visible text",
                "evidence": ["ocr_observation_000001.json"],
                "method": "oculix_region_text",
                "claim_scope": "visible_window_text_only",
            }
            with patch("adapters.OculixOCR.supported", return_value=True),                  patch("adapters.OculixOCR", return_value=backend):
                adapter = Adapter(
                    {"observations": ["ocr"], "actions": {}},
                    {
                        "desktop": Desktop(),
                        "tools": Mock(),
                        "work": Path(tmp),
                        "evidence": SimpleNamespace(root=Path(tmp)),
                    },
                )
                self.assertTrue(adapter.capabilities()["ocr"])
                observed = adapter.observe()
                self.assertEqual(observed["ocr"]["status"], "PASS")
                self.assertEqual(
                    observed["external_observations"]["values"]["ocr_text"],
                    "visible text",
                )
                self.assertEqual(
                    observed["external_observations"]["provenance"]["claim_scope"],
                    "visible_window_text_only",
                )
                adapter.close()
                backend.close.assert_called_once()

    def test_failed_ocr_never_becomes_external_observation(self):
        with tempfile.TemporaryDirectory() as tmp:
            backend = Mock()
            backend.read.return_value = {
                "status": "HARNESS_ERROR",
                "reason_code": "OCULIX_OCR_FAILED",
                "text": "",
                "evidence": ["ocr_observation_000001.json"],
                "method": "oculix_region_text",
                "claim_scope": "visible_window_text_only",
            }
            with patch("adapters.OculixOCR.supported", return_value=True),                  patch("adapters.OculixOCR", return_value=backend):
                adapter = Adapter(
                    {"observations": ["ocr"], "actions": {}},
                    {
                        "desktop": Desktop(),
                        "tools": Mock(),
                        "work": Path(tmp),
                        "evidence": SimpleNamespace(root=Path(tmp)),
                    },
                )
                observed = adapter.observe()
                self.assertEqual(observed["ocr"]["status"], "HARNESS_ERROR")
                self.assertIsNone(observed["external_observations"])


class OcrRunnerEvidenceTests(unittest.TestCase):
    def test_scenario_emits_optional_ocr_evidence_without_semantic_promotion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            evidence = Evidence(root / "E", "run")
            profile = {
                "game_id": "g",
                "actions": {"noop": {"inputs": []}},
                "goals": [],
                "tests": [],
                "state_signature": ["scene"],
            }
            scenario = {
                "id": "s",
                "agent": "Smoke",
                "sequence": ["noop"],
                "action_budget": 1,
                "time_budget": 5,
                "observation_delay": 0,
            }
            observation = {
                "internal_state": {"scene": "main"},
                "window": {"exists": True, "focused": True},
                "ocr": {
                    "status": "PASS",
                    "reason_code": "OCR_CAPTURE_COMPLETED",
                    "text": "menu",
                    "evidence": ["ocr.json"],
                },
                "external_observations": {
                    "values": {"ocr_text": "menu"},
                    "provenance": {
                        "method": "oculix_region_text",
                        "claim_scope": "visible_window_text_only",
                        "evidence": ["ocr.json"],
                    },
                },
            }
            (evidence.root / "ocr.json").write_text("{}", encoding="utf-8")
            (evidence.root / "g.s_stderr.log").write_text("", encoding="utf-8")

            adapter = Mock()
            adapter.capabilities.return_value = {"ocr": True, "audio": False, "gamepad": False}
            adapter.observe.return_value = observation
            adapter.act.return_value = None
            process = SimpleNamespace(pid=123, poll=lambda: None)

            session = Session(root, evidence, None, profile)
            session.desktop = Desktop()
            session.copy_game = Mock(return_value=root)
            session.start = Mock(return_value=(process, adapter))
            session.shot = Mock(return_value=(None, None))
            session.disk_guard = Mock()
            session.monitor = Mock()
            session.stop = Mock()
            session.checkpoint = Mock()
            session.behavioral_regression = Mock()
            session.observe_features = Mock(return_value=None)
            session.required_cases = []

            session.run_scenario(scenario, 7)

            row = next(r for r in session.results if r["test_case"] == "g.s.ocr")
            self.assertEqual(row["status"], "PASS")
            self.assertEqual(row["gate"], "OPTIONAL")
            self.assertEqual(row["evidence"], ["ocr.json"])
            self.assertIn("semantic game outcome remains unverified", row["claim"])


if __name__ == "__main__":
    unittest.main()
