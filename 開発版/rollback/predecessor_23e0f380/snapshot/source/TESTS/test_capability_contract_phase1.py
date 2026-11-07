"""Pre-execution capability contract: freeze, missing capability, downgrade rejection."""
import json,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from capability_contract import CapabilityContract,declared_capabilities,target_required_capabilities
from common import CAPABILITIES


def contract_file(root,ids,mandatory=None):
    mandatory=set(ids) if mandatory is None else set(mandatory)
    payload={'schema_version':1,'mandatory_capabilities':[{'id':i,'required':i in mandatory} for i in sorted(ids)]}
    (root/'capability_contract.json').write_text(json.dumps(payload),encoding='utf-8')


class CapabilityContractTests(unittest.TestCase):
    def setUp(self):
        self.t=tempfile.TemporaryDirectory();self.addCleanup(self.t.cleanup);self.root=Path(self.t.name)

    def entry(self,**kwargs):
        base={'id':'game','profile':'PROFILES/game.json'}
        base.update(kwargs);return base

    def test_only_target_scoped_capabilities_are_required(self):
        contract_file(self.root,['soak','video','evidence_zip'])
        contract=CapabilityContract.freeze(self.root,[self.entry(requirements=['soak'])])
        self.assertEqual(set(contract.required),{'soak'})
        self.assertNotIn('video',contract.required)
        self.assertNotIn('evidence_zip',contract.required)
        self.assertNotEqual(set(contract.required),set(CAPABILITIES))

    def test_explicit_required_capabilities_are_frozen(self):
        contract_file(self.root,['soak','evidence_zip'])
        contract=CapabilityContract.freeze(self.root,[self.entry(required_capabilities=['evidence_zip'])])
        self.assertEqual(set(contract.required),{'evidence_zip'})
        self.assertEqual(contract.required['evidence_zip'],'target.declared')

    def test_unknown_capability_is_rejected_before_execution(self):
        with self.assertRaisesRegex(ValueError,'UNKNOWN_CAPABILITY'):
            target_required_capabilities(self.entry(required_capabilities=['not_a_capability']))

    def test_missing_required_capability_has_explicit_non_pass_outcome(self):
        contract_file(self.root,['video'])
        contract=CapabilityContract.freeze(self.root,[self.entry(requirements=['soak'])])
        missing=contract.missing(declared_capabilities(self.root))
        self.assertEqual(missing,['soak'])
        rows=contract.outcome_rows(missing,[])
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['status'],'NOT_RUN')
        self.assertEqual(rows[0]['reason_code'],'REQUIRED_CAPABILITY_UNAVAILABLE')
        self.assertEqual(rows[0]['gate'],'REQUIRED')

    def test_missing_capability_contract_fails_closed(self):
        contract=CapabilityContract.freeze(self.root,[self.entry(requirements=['soak'])])
        self.assertEqual(contract.missing(declared_capabilities(self.root)),['soak'])
        self.assertIsNone(declared_capabilities(self.root))

    def test_disappeared_capability_is_rejected_after_results_exist(self):
        contract_file(self.root,['soak','video'])
        contract=CapabilityContract.freeze(self.root,[self.entry(requirements=['soak'])])
        contract_file(self.root,['video'])
        violations=contract.verify(declared_capabilities(self.root))
        self.assertEqual([v['kind'] for v in violations],['REQUIRED_CAPABILITY_DISAPPEARED'])
        self.assertEqual(contract.outcome_rows([],violations)[0]['status'],'HARNESS_ERROR')

    def test_downgraded_capability_is_rejected_after_results_exist(self):
        contract_file(self.root,['soak','video'],mandatory=['soak','video'])
        contract=CapabilityContract.freeze(self.root,[self.entry(requirements=['soak'])])
        contract_file(self.root,['soak','video'],mandatory=['video'])
        violations=contract.verify(declared_capabilities(self.root))
        self.assertEqual([v['kind'] for v in violations],['REQUIRED_CAPABILITY_DOWNGRADED'])
        self.assertEqual(contract.outcome_rows([],violations)[0]['status'],'HARNESS_ERROR')

    def test_unchanged_capability_contract_passes_verification(self):
        contract_file(self.root,['soak','video'])
        contract=CapabilityContract.freeze(self.root,[self.entry(requirements=['soak'])])
        self.assertEqual(contract.verify(declared_capabilities(self.root)),[])

    def test_requirement_set_change_after_freeze_is_reported(self):
        contract_file(self.root,['soak','video'])
        contract=CapabilityContract.freeze(self.root,[self.entry(requirements=['soak'])])
        violations=contract.verify(declared_capabilities(self.root),[self.entry(requirements=[])])
        self.assertIn('REQUIREMENT_SET_CHANGED',[v['kind'] for v in violations])

    def test_frozen_snapshot_survives_later_manifest_edits(self):
        contract_file(self.root,['soak'])
        contract=CapabilityContract.freeze(self.root,[self.entry(requirements=['soak'])])
        contract_file(self.root,[])
        self.assertEqual(set(contract.required),{'soak'})
        self.assertEqual(contract.missing(declared_capabilities(self.root)),['soak'])

    def test_contract_round_trips_through_json(self):
        contract_file(self.root,['soak'])
        contract=CapabilityContract.freeze(self.root,[self.entry(requirements=['soak'])],frozen_at='2026-01-01T00:00:00Z')
        restored=CapabilityContract.from_dict(json.loads(json.dumps(contract.to_dict())))
        self.assertEqual(restored.required,contract.required)
        self.assertEqual(restored.requirements,contract.requirements)

if __name__=='__main__':unittest.main()
