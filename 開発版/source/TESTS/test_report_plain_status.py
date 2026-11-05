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

    def test_absent_headquarters_never_implies_acceptance(self):
        with tempfile.TemporaryDirectory() as tmp:
            report(tmp, {'overall': 'PASS', 'run_id': 'example', 'results': []})
            html = (Path(tmp) / 'report.html').read_text(encoding='utf-8')
        self.assertIn('Headquarters evaluation: NOT_RUN', html)
        self.assertIn('Stable: HOLD', html)


if __name__ == '__main__':
    unittest.main()
