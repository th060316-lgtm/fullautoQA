import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "CORE"))

from contracts import profile_plan


def goal_profile(*, verify_seed_replay=False, regression=False):
    scenario = {
        "id": "goal_main",
        "agent": "Goal",
        "goal": "win",
        "sequence": ["advance"],
        "verify_seed_replay": verify_seed_replay,
    }
    profile = {
        "game_id": "generic_goal_game",
        "actions": {"advance": {"inputs": []}},
        "goals": [{"id": "win", "field": "won", "op": "eq", "value": True}],
        "scenarios": [scenario],
        "tests": [],
        "require_goal_agent": True,
    }
    if regression:
        profile["qa_plan"] = {
            "regression": {
                "scenario": "goal_main",
                "state_fields": ["won"],
            }
        }
    return profile


class GoalReplayContractTests(unittest.TestCase):
    def required(self, profile):
        return {
            row["test_case"]
            for row in profile_plan(profile, options={"required_agents": ["Goal"]})
            if row["gate"] == "REQUIRED"
        }

    def test_direct_goal_run_still_requires_goal_policy_demonstration(self):
        required = self.required(goal_profile())
        self.assertIn("generic_goal_game.goal_main.goal_agent", required)

    def test_seed_replay_does_not_claim_goal_policy_selection(self):
        required = self.required(goal_profile(verify_seed_replay=True))
        self.assertIn("generic_goal_game.goal_main.goal_agent", required)
        self.assertIn("generic_goal_game.seed_replay", required)
        self.assertNotIn("generic_goal_game.goal_main_seed_replay.goal_agent", required)

    def test_regression_replay_does_not_reprove_goal_policy(self):
        required = self.required(goal_profile(regression=True))
        self.assertIn("generic_goal_game.goal_main.goal_agent", required)
        self.assertIn("generic_goal_game.__qa_baseline.goal_agent", required)
        self.assertNotIn("generic_goal_game.__qa_regression.goal_agent", required)
        self.assertIn("generic_goal_game.__qa_regression.behavioral_regression", required)
        self.assertIn("generic_goal_game.__qa_regression.visual_regression", required)


if __name__ == "__main__":
    unittest.main()
