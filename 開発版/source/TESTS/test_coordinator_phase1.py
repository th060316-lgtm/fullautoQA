"""Coordinator boundary: domain wiring, capability enforcement, result attachment."""
import json,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from capability_contract import CapabilityContract
from coordinator import (Coordinator,CoordinatorContext,attach_summary_to_result_file,
                         build_payload,prepare_execution)
from headquarters import DomainReport
from target_identity import bind_target


def row(case,status,gate='REQUIRED',reason=None):
    return {'test_case':case,'status':status,'gate':gate,'reason_code':reason,'evidence':['evidence.png']}


def contract_file(root,ids,mandatory=None):
    mandatory=set(ids) if mandatory is None else set(mandatory)
    payload={'schema_version':1,'mandatory_capabilities':[{'id':i,'required':i in mandatory} for i in sorted(ids)]}
    (root/'capability_contract.json').write_text(json.dumps(payload),encoding='utf-8')


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.t=tempfile.TemporaryDirectory();self.addCleanup(self.t.cleanup);self.root=Path(self.t.name)
        (self.root/'PROFILES').mkdir();(self.root/'GAME').mkdir()
        (self.root/'PROFILES'/'game.json').write_text(json.dumps({'game_id':'game','game_version':'1'}),encoding='utf-8')
        (self.root/'GAME'/'a').write_bytes(b'game-a')
        self.entry={'id':'game','profile':'PROFILES/game.json','source':'GAME','requirements':['soak']}
        self.settings={'paths':{'target_manifest':'QA_TARGETS.json','target_bindings':'QA_BINDINGS.json'}}

    def identity(self,entry=None):
        return bind_target(self.root,entry or self.entry,None,settings=self.settings)

    def context(self,results=None,identity=None,contract=None):
        return CoordinatorContext(root=self.root,results=results if results is not None else [row('a','PASS')],
                                   identity=identity,contract=contract,settings=self.settings)

    def test_management_and_sales_are_not_run_by_default(self):
        summary=Coordinator(self.root,self.settings).evaluate(self.context())
        statuses={d.name:d.status for d in summary.domains}
        self.assertEqual(statuses['production'],'PASS')
        self.assertEqual(statuses['management'],'NOT_RUN')
        self.assertEqual(statuses['sales'],'NOT_RUN')
        self.assertEqual(summary.overall,'NOT_RUN');self.assertFalse(summary.accepted)

    def test_registering_management_does_not_change_the_production_domain(self):
        coordinator=Coordinator(self.root,self.settings);before=coordinator.evaluate(self.context())
        coordinator.register('management',lambda context:DomainReport.from_results('management',[row('m','PASS')]))
        after=coordinator.evaluate(self.context())
        self.assertEqual(after.domains[0].to_dict(),before.domains[0].to_dict())
        self.assertEqual({d.name:d.status for d in after.domains}['management'],'PASS')
        self.assertEqual(after.overall,'NOT_RUN')

    def test_a_full_pipeline_of_passing_domains_is_accepted(self):
        coordinator=Coordinator(self.root,self.settings)
        coordinator.register('management',lambda context:DomainReport.from_results('management',[row('m','PASS')]))
        coordinator.register('sales',lambda context:DomainReport.from_results('sales',[row('s','PASS')]))
        summary=coordinator.evaluate(self.context())
        self.assertEqual(summary.overall,'PASS');self.assertTrue(summary.accepted)

    def test_unknown_domain_cannot_be_registered(self):
        with self.assertRaisesRegex(ValueError,'UNKNOWN_DOMAIN'):
            Coordinator(self.root,self.settings).register('marketing',lambda context:None)

    def test_summary_is_attached_without_touching_the_baseline_fields(self):
        coordinator=Coordinator(self.root,self.settings)
        data={'overall':'PASS','run_id':'r1','results':[row('a','PASS')]}
        context=self.context();summary=coordinator.evaluate(context);payload=coordinator.attach(data,summary,context)
        self.assertEqual(payload['overall'],'PASS');self.assertEqual(payload['run_id'],'r1')
        self.assertEqual(payload['results'],data['results']);self.assertEqual(payload['headquarters']['overall'],'NOT_RUN')
        self.assertEqual(data.get('headquarters'),None)

    def test_missing_required_capability_blocks_the_production_domain(self):
        contract_file(self.root,['video'])
        contract=CapabilityContract.freeze(self.root,[self.entry],settings=self.settings)
        summary=Coordinator(self.root,self.settings).evaluate(self.context(contract=contract))
        production=[d for d in summary.domains if d.name=='production'][0]
        self.assertNotEqual(production.status,'PASS')
        self.assertIn('REQUIRED_CAPABILITY_UNAVAILABLE',[g['reason_code'] for g in production.gates])

    def test_capability_downgrade_blocks_the_production_domain(self):
        contract_file(self.root,['soak','video'],mandatory=['soak','video'])
        contract=CapabilityContract.freeze(self.root,[self.entry],settings=self.settings)
        contract_file(self.root,['soak','video'],mandatory=['video'])
        summary=Coordinator(self.root,self.settings).evaluate(self.context(contract=contract))
        production=[d for d in summary.domains if d.name=='production'][0]
        self.assertNotEqual(production.status,'PASS')
        self.assertIn('REQUIRED_CAPABILITY_DOWNGRADED',[g['reason_code'] for g in production.gates])

    def test_a_fixture_target_never_certifies_a_real_target(self):
        entry=dict(self.entry);entry['kind']='fixture'
        summary=Coordinator(self.root,self.settings).evaluate(self.context(identity=self.identity(entry)))
        production=[d for d in summary.domains if d.name=='production'][0]
        self.assertFalse(production.certifies_real_target);self.assertNotEqual(production.status,'PASS')
        self.assertFalse(summary.accepted)

    def test_a_real_target_certifies_a_real_target(self):
        summary=Coordinator(self.root,self.settings).evaluate(self.context(identity=self.identity()))
        self.assertTrue([d for d in summary.domains if d.name=='production'][0].certifies_real_target)

    def test_result_file_hook_is_additive(self):
        run_dir=self.root/'RESULTS'/'run1';run_dir.mkdir(parents=True)
        payload={'overall':'PASS','run_id':'r1','results':[row('a','PASS')]}
        (run_dir/'result.json').write_text(json.dumps(payload),encoding='utf-8')
        summary=attach_summary_to_result_file(run_dir/'result.json',root=self.root,settings=self.settings)
        self.assertIsNotNone(summary);written=json.loads((run_dir/'result.json').read_text(encoding='utf-8'))
        self.assertEqual(written['overall'],'PASS');self.assertEqual(written['results'],payload['results'])
        self.assertEqual(written['headquarters']['domains'][0]['status'],'PASS')

    def test_result_file_hook_leaves_a_missing_file_alone(self):
        self.assertIsNone(attach_summary_to_result_file(self.root/'missing.json',root=self.root,settings=self.settings))

    def test_prepare_execution_freezes_the_contract_and_binds_the_identities(self):
        contract_file(self.root,['soak','video']);manifest={'schema_version':1,'targets':[self.entry]}
        prepared=prepare_execution(self.root,manifest,self.settings)
        self.assertEqual(set(prepared['contract'].required),{'soak'})
        identity=prepared['identities']['game'];self.assertEqual(identity.generation,1)
        self.assertTrue(identity.certifies_real_target);self.assertEqual(prepared['contract'].requirements,{'game':['soak']})

    def test_build_payload_keeps_the_baseline_fields(self):
        coordinator=Coordinator(self.root,self.settings);context=self.context();summary=coordinator.evaluate(context)
        payload=build_payload(self.root,context.results,summary,identity=context.identity,
                              contract=None,settings=self.settings,
                              result_data={'overall':'PASS','results':context.results})
        self.assertEqual(payload['overall'],'PASS');self.assertEqual(payload['results'],context.results)
        self.assertIn('headquarters',payload)

    def test_preflight_blocks_the_execution_of_a_target_with_a_missing_capability(self):
        contract_file(self.root,['video']);manifest={'schema_version':1,'targets':[self.entry]}
        prepared=prepare_execution(self.root,manifest,self.settings)
        context=CoordinatorContext(root=self.root,results=[],identity=prepared['identities']['game'],
                                   contract=prepared['contract'],settings=self.settings)
        problems=Coordinator(self.root,self.settings).preflight(context)
        self.assertEqual([p['subject'] for p in problems],['soak'])
        self.assertEqual(problems[0]['kind'],'REQUIRED_CAPABILITY_UNAVAILABLE')

    def test_preflight_passes_when_every_required_capability_is_available(self):
        contract_file(self.root,['soak','video'],mandatory=['soak','video'])
        manifest={'schema_version':1,'targets':[self.entry]};prepared=prepare_execution(self.root,manifest,self.settings)
        context=CoordinatorContext(root=self.root,results=[],identity=prepared['identities']['game'],
                                   contract=prepared['contract'],settings=self.settings)
        self.assertEqual(Coordinator(self.root,self.settings).preflight(context),[])

    def test_full_phase1_flow_from_manifest_to_result_file(self):
        contract_file(self.root,['soak','video'],mandatory=['soak','video'])
        manifest={'schema_version':1,'targets':[self.entry]};coordinator=Coordinator(self.root,self.settings)
        prepared=prepare_execution(self.root,manifest,self.settings)
        context=CoordinatorContext(root=self.root,results=[row('a','PASS')],
                                   identity=prepared['identities']['game'],
                                   contract=prepared['contract'],settings=self.settings)
        self.assertEqual(coordinator.preflight(context),[])
        summary=coordinator.evaluate(context)
        self.assertEqual(summary.domains[0].status,'PASS');self.assertEqual(summary.overall,'NOT_RUN')
        self.assertFalse(summary.accepted)
        payload=coordinator.attach({'overall':'PASS','results':context.results},summary,context)
        self.assertEqual(payload['overall'],'PASS');self.assertIn('target_identity',payload)
        self.assertIn('capability_contract',payload)
        run_dir=self.root/'RESULTS'/'run1';run_dir.mkdir(parents=True)
        (run_dir/'result.json').write_text(json.dumps(payload),encoding='utf-8')
        attach_summary_to_result_file(run_dir/'result.json',root=self.root,settings=self.settings)
        written=json.loads((run_dir/'result.json').read_text(encoding='utf-8'))
        self.assertEqual(written['overall'],'PASS')
        self.assertEqual([d['name'] for d in written['headquarters']['domains']],
                         ['production','management','sales'])
        self.assertEqual(written['headquarters']['domains'][0]['status'],'PASS')
        self.assertEqual(written['headquarters']['domains'][1]['status'],'NOT_RUN')

if __name__=='__main__':unittest.main()
