import sys,json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from adapters import Adapter

class BridgeObservationTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.root=Path(tmp.name)
        class Desktop:
            def state(self):return {'exists':True}
        self.adapter=Adapter({'bridge':'state.json','observation_read_timeout':.02},{'work':self.root,'desktop':Desktop()})

    def test_transient_replace_gap_retries_without_inventing_empty_state(self):
        with patch('adapters.read_json',side_effect=[FileNotFoundError(),json.JSONDecodeError('partial','',0),{'position':{'x':7}}]):
            value=self.adapter.observe()
        self.assertEqual(value['internal_state'],{'position':{'x':7}})
        self.assertEqual(value['observation_status']['attempts'],3)

    def test_persistent_missing_bridge_is_explicit_failure(self):
        with self.assertRaisesRegex(OSError,'OBSERVATION_BRIDGE_UNAVAILABLE'):self.adapter.observe()

    def test_nonobject_bridge_rejected(self):
        (self.root/'state.json').write_text('[]')
        with self.assertRaisesRegex(ValueError,'OBSERVATION_BRIDGE_NOT_OBJECT'):self.adapter.observe()

    def test_blackbox_without_bridge_remains_supported(self):
        self.adapter.profile={}
        value=self.adapter.observe()
        self.assertEqual(value['internal_state'],{})
        self.assertEqual(value['observation_status']['internal_state'],'NOT_CONFIGURED')
