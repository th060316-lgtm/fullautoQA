import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'CORE'))
from common import report


class PlainReportStatusTests(unittest.TestCase):
    def test_acceptance_precedes_technical_details_and_links_remain(self):
        data = {'overall': 'PASS', 'run_id': 'example',
                'results': [{'test_case': 'smoke', 'status': 'PASS', 'evidence': ['proof.json']}],
                'headquarters': {'overall': 'NOT_RUN', 'domains': [{'name': 'Sales', 'status': 'NOT_RUN'}]},
                'target_qa_certified': True, 'completion_certified': False}
        with tempfile.TemporaryDirectory() as tmp:
            report(tmp, data)
            html = (Path(tmp) / 'report.html').read_text(encoding='utf-8')
        self.assertLess(html.index('Acceptance status'), html.index('Detailed test results'))
        for text in ('Automated test result: PASS', 'Sales: NOT_RUN',
                     'Completion certified: False', 'Product Acceptance: HOLD',
                     'Stable: HOLD', 'href="proof.json"'):
            self.assertIn(text, html)

    def test_audience_summary_is_rendered_without_overstating_acceptance(self):
        audience = {
            'status': 'GENERATED',
            'entries': [{
                'what_game': 'The player moves and reaches an objective.',
                'product_description': 'A game centered on movement and reaching an objective.',
            }],
        }
        data = {
            'overall': 'PASS',
            'run_id': 'example',
            'results': [],
            'sales_readback': {
                'status': 'NOT_RUN',
                'reason_code': 'SALES_READABILITY_REVIEW_REQUIRED',
                'accepted': False,
                'audience_summary': audience,
                'risks': [],
            },
        }
        with tempfile.TemporaryDirectory() as tmp:
            report(tmp, data)
            html = (Path(tmp) / 'report.html').read_text(encoding='utf-8')
            text = (Path(tmp) / 'SUMMARY.txt').read_text(encoding='utf-8')
        self.assertIn('What this game asks the player to do', html)
        self.assertIn('Name/IP/price-blind description', html)
        self.assertIn('readability: requires Sales communication/readability acceptance', text)
        self.assertIn('Product Acceptance: HOLD', html)

    def test_absent_headquarters_never_implies_acceptance(self):
        with tempfile.TemporaryDirectory() as tmp:
            report(tmp, {'overall': 'PASS', 'run_id': 'example', 'results': []})
            html = (Path(tmp) / 'report.html').read_text(encoding='utf-8')
        self.assertIn('Headquarters evaluation: NOT_RUN', html)
        self.assertIn('Stable: HOLD', html)


if __name__ == '__main__':
    unittest.main()
