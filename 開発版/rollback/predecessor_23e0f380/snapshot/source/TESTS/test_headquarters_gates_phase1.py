"""Three-headquarters gate model: domain independence and summary contract.

Covers the Phase 1 requirement that one domain's PASS can never hide another
domain's NOT_RUN / FAIL / INCONCLUSIVE / HARNESS_ERROR.
"""
import json,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from headquarters import DOMAIN_ORDER,DomainReport,HeadquartersSummary,worst_status


def row(case,status,gate='REQUIRED',reason=None):
    return {'test_case':case,'status':status,'gate':gate,'reason_code':reason,'evidence':['evidence.png']}


class HeadquartersGateTests(unittest.TestCase):
    def summary(self,production,management=None,sales=None,**kwargs):
        domains=[production]
        domains.append(management if management is not None else DomainReport.not_run('management','MANAGEMENT_EVALUATION_NOT_PERFORMED'))
        domains.append(sales if sales is not None else DomainReport.not_run('sales','SALES_EVALUATION_NOT_PERFORMED'))
        return HeadquartersSummary(domains,**kwargs)

    def test_domains_are_independent_named_domains(self):
        self.assertEqual(DOMAIN_ORDER,('production','management','sales'))
        production=DomainReport.from_results('production',[row('a','PASS')])
        management=DomainReport.from_results('management',[row('b','FAIL','REQUIRED','RESOURCE_LIMIT')])
        sales=DomainReport.from_results('sales',[row('c','PASS')])
        summary=HeadquartersSummary([production,management,sales])
        self.assertEqual(summary.overall,'FAIL')
        self.assertFalse(summary.accepted)
        self.assertEqual([b['domain'] for b in summary.blocked_by],['management'])

    def test_pass_cannot_hide_not_run_of_another_domain(self):
        production=DomainReport.from_results('production',[row('a','PASS')])
        management=DomainReport.not_run('management','MANAGEMENT_EVALUATION_NOT_PERFORMED')
        summary=self.summary(production,management)
        self.assertEqual(summary.overall,'NOT_RUN')
        self.assertFalse(summary.accepted)
        self.assertIn('management',[b['domain'] for b in summary.blocked_by])

    def test_pass_cannot_hide_harness_error_of_another_domain(self):
        production=DomainReport.from_results('production',[row('a','PASS')])
        management=DomainReport.from_results('management',[row('b','HARNESS_ERROR')])
        summary=self.summary(production,management)
        self.assertEqual(summary.overall,'HARNESS_ERROR')
        self.assertFalse(summary.accepted)

    def test_pass_cannot_hide_inconclusive_of_another_domain(self):
        production=DomainReport.from_results('production',[row('a','PASS')])
        sales=DomainReport.from_results('sales',[row('c','INCONCLUSIVE')])
        summary=self.summary(production,sales=sales)
        self.assertEqual(summary.overall,'INCONCLUSIVE')
        self.assertFalse(summary.accepted)

    def test_required_not_run_is_never_pass(self):
        domain=DomainReport.from_results('production',[row('a','PASS'),row('b','NOT_RUN')])
        self.assertEqual(domain.status,'HARNESS_ERROR')
        self.assertFalse(self.summary(domain).accepted)

    def test_optional_not_run_keeps_baseline_semantics(self):
        domain=DomainReport.from_results('production',[row('a','PASS'),row('b','NOT_RUN','OPTIONAL')])
        self.assertEqual(domain.status,'PASS')

    def test_non_pass_gate_is_never_hidden_in_the_domain_listing(self):
        domain=DomainReport.from_results('production',[row('a','PASS'),row('b','FAIL','REQUIRED','CRASH')])
        self.assertEqual([g['name'] for g in domain.gates],['b'])
        self.assertTrue(domain.gates[0]['required'])
        self.assertEqual(domain.counts['PASS'],1)
        self.assertEqual(domain.counts['FAIL'],1)

    def test_summary_order_is_fixed_and_serialisable(self):
        production=DomainReport.from_results('production',[row('a','PASS')])
        summary=self.summary(production)
        payload=summary.to_dict()
        self.assertEqual([d['name'] for d in payload['domains']],['production','management','sales'])
        self.assertEqual(payload['decision'],'NOT_ACCEPTED')
        json.dumps(payload)

    def test_summary_is_deterministic(self):
        production=DomainReport.from_results('production',[row('a','PASS')])
        first=self.summary(production,generated_at='2026-01-01T00:00:00Z').to_dict()
        second=self.summary(production,generated_at='2026-01-01T00:00:00Z').to_dict()
        self.assertEqual(json.dumps(first,sort_keys=True),json.dumps(second,sort_keys=True))

    def test_all_pass_domains_are_accepted(self):
        production=DomainReport.from_results('production',[row('a','PASS')])
        management=DomainReport.from_results('management',[row('b','PASS')])
        sales=DomainReport.from_results('sales',[row('c','PASS')])
        summary=self.summary(production,management,sales)
        self.assertEqual(summary.overall,'PASS')
        self.assertTrue(summary.accepted)
        self.assertEqual(summary.to_dict()['decision'],'ACCEPTED')
        self.assertEqual(summary.blocked_by,[])

    def test_unknown_status_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'UNKNOWN_STATUS'):
            DomainReport('production','MAYBE')
        with self.assertRaisesRegex(ValueError,'UNKNOWN_STATUS'):
            worst_status(['PASS','SOMETHING'])

    def test_worst_status_order(self):
        self.assertEqual(worst_status(['PASS','PASS']),'PASS')
        self.assertEqual(worst_status(['PASS','NOT_RUN']),'NOT_RUN')
        self.assertEqual(worst_status(['NOT_RUN','FAIL']),'FAIL')
        self.assertEqual(worst_status(['FAIL','HARNESS_ERROR']),'HARNESS_ERROR')

if __name__=='__main__':unittest.main()
