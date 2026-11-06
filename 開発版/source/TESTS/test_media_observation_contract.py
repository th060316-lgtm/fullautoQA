import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "CORE"))

from common import Evidence
from contracts import profile_plan
from observations import profile_requests_observation
from windows_runner import Session


class Desktop:
    def state(self):
        return {"exists": True, "focused": True}

    def focus(self):
        return None

    def perform(self, item):
        return None


def profile(observations):
    return {
        "game_id": "g",
        "actions": {"noop": {"inputs": []}},
        "goals": [],
        "scenarios": [{
            "id": "s",
            "agent": "Smoke",
            "sequence": ["noop"],
            "action_budget": 1,
            "time_budget": 5,
        }],
        "tests": [],
        "observations": observations,
    }


class RequestedObservationPlanTests(unittest.TestCase):
    def required(self, observations):
        return {
            row["test_case"]
            for row in profile_plan(profile(observations))
            if row["gate"] == "REQUIRED"
        }

    def test_ocr_and_audio_are_frozen_only_when_requested(self):
        plain = self.required(["window", "screenshot", "log"])
        self.assertNotIn("g.s.ocr", plain)
        self.assertNotIn("g.s.audio", plain)

        requested = self.required(["ocr", "sound"])
        self.assertIn("g.s.ocr", requested)
        self.assertIn("g.s.audio", requested)

    def test_sound_alias_maps_to_audio(self):
        self.assertTrue(profile_requests_observation(profile(["sound"]), "audio"))
        self.assertTrue(profile_requests_observation(profile({"audio": True}), "audio"))
        self.assertFalse(profile_requests_observation(profile(["window"]), "audio"))


class AudioAdapterEvidenceTests(unittest.TestCase):
    def test_custom_adapter_audio_evidence_satisfies_requested_required_case(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            evidence = Evidence(root / "E", "run")
            (evidence.root / "audio.json").write_text("{}", encoding="utf-8")
            (evidence.root / "g.s_stderr.log").write_text("", encoding="utf-8")

            p = profile(["audio"])
            observation = {
                "internal_state": {},
                "window": {"exists": True, "focused": True},
                "audio": {
                    "status": "PASS",
                    "reason_code": "AUDIO_SIGNAL_OBSERVED",
                    "evidence": ["audio.json"],
                    "method": "profile_adapter_audio_meter",
                    "claim_scope": "declared_audio_signal_only",
                },
            }
            adapter = Mock()
            adapter.capabilities.return_value = {
                "ocr": False,
                "audio": True,
                "gamepad": False,
            }
            adapter.observe.return_value = observation
            adapter.act.return_value = None
            process = SimpleNamespace(pid=123, poll=lambda: None)

            session = Session(root, evidence, None, p)
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
            session.required_cases = ["g.s.audio"]

            session.run_scenario(p["scenarios"][0], 7)

            row = next(r for r in session.results if r["test_case"] == "g.s.audio")
            self.assertEqual(row["status"], "PASS")
            self.assertEqual(row["gate"], "REQUIRED")
            self.assertEqual(row["evidence"], ["audio.json"])
            self.assertEqual(row["method"], "profile_adapter_audio_meter")
            self.assertIn("semantic game outcome remain unverified", row["claim"])

    def test_requested_audio_without_capability_remains_not_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            evidence = Evidence(root / "E", "run")
            (evidence.root / "g.s_stderr.log").write_text("", encoding="utf-8")

            p = profile(["audio"])
            observation = {
                "internal_state": {},
                "window": {"exists": True, "focused": True},
                "audio": None,
            }
            adapter = Mock()
            adapter.capabilities.return_value = {
                "ocr": False,
                "audio": False,
                "gamepad": False,
            }
            adapter.observe.return_value = observation
            adapter.act.return_value = None
            process = SimpleNamespace(pid=123, poll=lambda: None)

            session = Session(root, evidence, None, p)
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
            session.required_cases = ["g.s.audio"]

            session.run_scenario(p["scenarios"][0], 7)

            row = next(r for r in session.results if r["test_case"] == "g.s.audio")
            self.assertEqual(row["status"], "NOT_RUN")
            # audit_plan later freezes this same case as REQUIRED; do not fabricate PASS.
            self.assertNotEqual(row["status"], "PASS")


if __name__ == "__main__":
    unittest.main()
