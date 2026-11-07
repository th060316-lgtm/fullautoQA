
import os, sys, tempfile, unittest
from pathlib import Path

CORE = Path(__file__).resolve().parents[1] / "CORE"
STUBS = Path(__file__).resolve().parent / "stubs"
sys.path.insert(0, str(CORE))
sys.path.insert(1, str(STUBS))

from agents import Agent
from storage_qa import StorageInspector, PathEscapeError
from browser_backend import validate_browser_target, validate_browser_profile


class AgentTests(unittest.TestCase):
    def profile(self):
        return {"actions":{"a":{},"b":{}}, "state_signature":["x"]}

    def test_non_soak_budget_not_broken_by_memory_limit(self):
        a=Agent(self.profile(),{"agent":"Explorer","action_budget":5,"time_budget":999,"memory_limit":2},123)
        for i in range(5):
            self.assertFalse(a.exhausted())
            action=a.choose({"x":0},screen=b"same")
            a.feedback({"x":0},{"x":0},action,screen_before=b"same",screen_after=b"same")
        self.assertTrue(a.exhausted())
        self.assertEqual(len(a.history),5)

    def test_no_reaction_never_success(self):
        a=Agent(self.profile(),{"agent":"Explorer","action_budget":10,"time_budget":999},1)
        action=a.choose({"x":0},screen=b"same")
        a.feedback({"x":0},{"x":0},action,screen_before=b"same",screen_after=b"same")
        self.assertEqual(sum(a.obs_success.values()),0)
        self.assertEqual(sum(a.obs_failed.values()),1)

    def test_changed_screen_can_be_learned(self):
        a=Agent(self.profile(),{"agent":"Explorer","action_budget":20,"time_budget":999},1)
        action=a.choose({"x":0},screen=b"s0")
        a.feedback({"x":0},{"x":0},action,screen_before=b"s0",screen_after=b"s1")
        self.assertEqual(sum(a.obs_success.values()),1)
        # same starting screen should prefer the action with prior observed success
        self.assertEqual(a.choose({"x":0},screen=b"s0"),action)

    def test_observational_learning_requires_explicit_before_and_after(self):
        a=Agent(self.profile(),{"agent":"Explorer","action_budget":10,"time_budget":999},1)
        action=a.choose({"x":0},screen=b"s0")
        a.feedback({"x":0},{"x":0},action,screen_after=b"s1")
        self.assertEqual(sum(a.obs_success.values()),0)
        self.assertEqual(sum(a.obs_failed.values()),0)


class StorageTests(unittest.TestCase):
    def snap(self, inspector):
        return inspector.snapshot()

    def test_save_mutate_load_required(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); (root/"saves").mkdir()
            f=root/"saves"/"slot.dat"; f.write_text("old")
            i=StorageInspector(root,["saves"])
            pre=i.snapshot("pre")
            f.write_text("saved")
            saved=i.snapshot("saved")
            f.write_text("mutated")
            mutated=i.snapshot("mutated")
            f.write_text("saved")
            loaded=i.snapshot("loaded")
            r=i.check_persistence(pre,saved,mutated,loaded)
            self.assertEqual(r["status"],"PASS")
            self.assertTrue(r["mutation_had_effect"])

    def test_no_mutation_is_not_pass(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); (root/"saves").mkdir()
            f=root/"saves"/"slot.dat"; f.write_text("old")
            i=StorageInspector(root,["saves"])
            pre=i.snapshot()
            f.write_text("saved")
            saved=i.snapshot()
            loaded=i.snapshot()
            r=i.check_persistence(pre,saved,saved,loaded)
            self.assertEqual(r["status"],"INCONCLUSIVE")
            self.assertIn("STORAGE_NOT_MUTATED_BEFORE_LOAD",r["reasons"])

    def test_escape_rejected(self):
        with tempfile.TemporaryDirectory() as td, tempfile.TemporaryDirectory() as outside:
            root=Path(td)
            with self.assertRaises(PathEscapeError):
                StorageInspector(root,[outside])


class BrowserValidationTests(unittest.TestCase):
    def test_loopback_allowed_external_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertEqual(validate_browser_target("http://127.0.0.1:8000/game",td)["scheme"],"http")
            self.assertEqual(validate_browser_target("https://localhost/game",td)["scheme"],"https")
            with self.assertRaises(OSError):
                validate_browser_target("https://example.com/game",td)

    def test_file_target_must_stay_inside_work(self):
        with tempfile.TemporaryDirectory() as td, tempfile.TemporaryDirectory() as outside:
            root=Path(td); inside=root/"index.html"; inside.write_text("ok")
            self.assertEqual(validate_browser_target(inside.as_uri(),root)["scheme"],"file")
            out=Path(outside)/"x.html"; out.write_text("x")
            with self.assertRaises(OSError):
                validate_browser_target(out.as_uri(),root)

    def test_relative_file_allowed_and_file_host_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); (root/"index.html").write_text("ok")
            self.assertEqual(validate_browser_target("index.html",root)["scheme"],"file")
            with self.assertRaises(OSError):
                validate_browser_target("file://server/share/game.html",root)

    def test_expanded_launch_arguments_are_validated(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); (root/"index.html").write_text("ok")
            profile={"display":{"kind":"browser","target":"index.html"},"launch":{"argv":["browser"]}}
            self.assertEqual(validate_browser_profile(profile,root,["browser","http://127.0.0.1:8080"])["scheme"],"file")
            with self.assertRaises(OSError):
                validate_browser_profile(profile,root,["browser","https://example.com/game"])


class CoordinatorNonRegressionStaticTests(unittest.TestCase):
    def test_phase1_protections_still_present(self):
        text=(CORE/"coordinator.py").read_text()
        required=[
            "def verify_execution(",
            "TARGET_MANIFEST_CHANGED",
            "TARGET_FINGERPRINT_MISMATCH",
            "check_result_binding(TargetIdentity.from_dict(recorded), prior_map.get(key))",
            "TARGET_NOT_EXECUTED",
            "execution_verification.json",
            "attach_readbacks(data, summary)",
        ]
        for token in required:
            self.assertIn(token,text)


if __name__=="__main__":
    unittest.main()