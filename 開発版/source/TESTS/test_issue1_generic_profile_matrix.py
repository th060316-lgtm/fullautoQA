import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "CORE"))

from adapters import Adapter
from profile import load as load_profile
from target_intake import tool_ids_from_profile, validate_profile_structure


DECLARED_TOOLS = {"godot", "java", "node", "python", "c", "ffmpeg", "git"}


def profile_for(launch, build=None):
    actions = {
        "move": {"inputs": [{"kind": "key", "key": "W", "duration": 0.05}]},
        "camera": {"inputs": [{"kind": "drag", "x": 0.5, "y": 0.5, "to_x": 0.6, "to_y": 0.5, "duration": 0.1}]},
        "menu": {"inputs": [{"kind": "key", "key": "ESC", "duration": 0.05}]},
        "combat": {"inputs": [{"kind": "click", "x": 0.5, "y": 0.5}]},
        "ui": {"inputs": [{"kind": "click", "x": 0.2, "y": 0.2}]},
        "tutorial": {"inputs": [{"kind": "key", "key": "ENTER", "duration": 0.05}]},
        "retry": {"inputs": [{"kind": "key", "key": "R", "duration": 0.05}]},
        "save_load": {"inputs": [{"kind": "key", "key": "F5", "duration": 0.05}]},
    }
    result = {
        "game_id": "generic-target",
        "game_version": "test",
        "profile_version": "1",
        "schema_version": 1,
        "prototype_type": "playable",
        "launch": {"argv": launch},
        "actions": actions,
        "goals": [{
            "id": "observe_progress",
            "type": "trigger_event",
            "field": "scene",
            "op": "exists",
            "value": True,
        }],
        "scenarios": [{
            "id": "main_loop",
            "agent": "Explorer",
            "goal": "observe_progress",
            "sequence": list(actions),
            "retry_test": True,
        }],
        "tests": [],
        "observations": ["window", "screenshot", "process", "log"],
        "instructions": "Use the declared actions and observe the resulting game loop.",
    }
    if build is not None:
        result["build"] = {"argv": build}
    return result


class GenericRuntimeProfileMatrixTests(unittest.TestCase):
    def assert_profile_loads(self, profile):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "profile.json"
            path.write_text(json.dumps(profile), encoding="utf-8")
            loaded = load_profile(tmp, path)
            self.assertEqual(loaded["game_id"], profile["game_id"])

    def test_runtime_and_native_executable_families_use_the_same_profile_contract(self):
        matrix = {
            "godot": (["{godot}", "GAME/project.godot"], None, {"godot"}),
            "java": (["{java}", "-jar", "GAME/game.jar"], None, {"java"}),
            "node": (["{node}", "GAME/game.js"], None, {"node"}),
            "python": (["{python}", "GAME/game.py"], None, {"python"}),
            "c": (["GAME/game.exe"], ["{c}", "GAME/game.c", "-o", "GAME/game.exe"], {"c"}),
            "unity": (["GAME/UnityGame.exe"], None, set()),
            "unreal": (["GAME/UnrealGame.exe"], None, set()),
            "exe": (["GAME/CustomGame.exe"], None, set()),
        }
        for family, (launch, build, expected_tools) in matrix.items():
            with self.subTest(family=family):
                profile = profile_for(launch, build)
                self.assertEqual(validate_profile_structure(profile), [])
                self.assert_profile_loads(profile)
                self.assertEqual(
                    set(tool_ids_from_profile(profile, DECLARED_TOOLS)),
                    expected_tools,
                )

    def test_operation_names_are_profile_data_not_core_hardcoded_categories(self):
        profile = profile_for(["GAME/game.exe"])
        self.assert_profile_loads(profile)
        self.assertEqual(
            set(profile["actions"]),
            {"move", "camera", "menu", "combat", "ui", "tutorial", "retry", "save_load"},
        )
        self.assertEqual(profile["scenarios"][0]["id"], "main_loop")

    def test_default_bridge_less_adapter_is_explicit_about_supported_and_missing_capabilities(self):
        class Desktop:
            def state(self):
                return {"exists": True}
        profile = profile_for(["GAME/game.exe"])
        adapter = Adapter(profile, {"desktop": Desktop(), "work": Path("."), "evidence": None, "tools": None})
        caps = adapter.capabilities()
        self.assertFalse(caps["internal_state"])
        self.assertTrue(caps["window_automation"])
        self.assertFalse(caps["ocr"])
        self.assertFalse(caps["audio"])


if __name__ == "__main__":
    unittest.main()
