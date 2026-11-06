import sys
import unittest
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "CORE"))

from audience_summary import build_audience_summary, render_audience_summary


class AudienceSummaryTests(unittest.TestCase):
    def packet(self):
        return {
            "schema_version": 1,
            "run_id": "r1",
            "targets": [{
                "target_id": "target-a",
                "game_id": "BrandName",
                "game_version": "1",
                "title": "Famous IP",
                "ip": "Famous IP",
                "free": True,
                "price": 0,
                "actions": ["move_left", "move_right", "confirm"],
                "goals": [{"id": "reach_exit"}],
                "scenarios": [{"id": "first_route", "agent": "Goal", "goal": "reach_exit"}],
            }],
        }

    def test_description_is_independent_of_game_ip_and_price_metadata(self):
        a = self.packet()
        b = deepcopy(a)
        b["targets"][0].update({
            "game_id": "CompletelyDifferentBrand",
            "title": "Different IP",
            "ip": "Different IP",
            "free": False,
            "price": 9999,
        })
        sa = build_audience_summary(a)
        sb = build_audience_summary(b)
        self.assertEqual(sa["status"], "GENERATED")
        self.assertEqual(sa["entries"][0]["product_description"],
                         sb["entries"][0]["product_description"])
        self.assertEqual(sa["entries"][0]["what_game"],
                         sb["entries"][0]["what_game"])
        self.assertTrue(sa["description_contract"]["brand_price_independent"])

    def test_missing_mechanics_never_fabricates_a_summary(self):
        packet = {"targets": [{"game_id": "anything", "actions": [], "goals": [], "scenarios": []}]}
        result = build_audience_summary(packet)
        self.assertEqual(result["status"], "NOT_RUN")
        self.assertEqual(result["reason_code"], "AUDIENCE_MECHANICS_EVIDENCE_ABSENT")
        self.assertEqual(result["entries"], [])

    def test_plain_report_names_evidence_and_keeps_acceptance_separate(self):
        summary = build_audience_summary(self.packet())
        text = render_audience_summary(summary)
        self.assertIn("Name/IP/price-blind product description", text)
        self.assertIn("player_review_packet.json", text)
        self.assertIn("not a human satisfaction or product-acceptance verdict", text)
        self.assertIn("Readability must still be judged", text)


if __name__ == "__main__":
    unittest.main()
