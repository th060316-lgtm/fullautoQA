import importlib.util,math,sys,types,unittest
from pathlib import Path
from unittest.mock import patch

stub=types.ModuleType('adapters');stub.Adapter=object
with patch.dict(sys.modules,{'adapters':stub}):
    spec=importlib.util.spec_from_file_location('coordinate_adapter_test',Path(__file__).with_name('adapter.py'))
    adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(adapter)

class ObservedCoordinateTests(unittest.TestCase):
    def test_letterbox_offset_is_applied_in_client_space(self):
        state={'input_mapping':{'xx':.8,'xy':0,'yx':0,'yy':.8,'origin_x':0,'origin_y':72,'client_width':1024,'client_height':720}}
        self.assertEqual(adapter.normalized_point(state,640,360),(.5,.5))
        self.assertEqual(adapter.normalized_point(state,0,0),(0,.1))
    def test_observed_translation_and_nonuniform_scaling_are_not_fixed(self):
        state={'input_mapping':{'xx':.5,'xy':0,'yx':0,'yy':.75,'origin_x':40,'origin_y':30,'client_width':800,'client_height':900}}
        x,y=adapter.normalized_point(state,200,100);self.assertAlmostEqual(x,.175);self.assertAlmostEqual(y,105/900)
    def test_absent_or_invalid_mapping_cannot_silently_click(self):
        with self.assertRaises(KeyError):adapter.normalized_point({},10,20)
        state={'input_mapping':{'xx':1,'xy':0,'yx':0,'yy':1,'origin_x':0,'origin_y':0,'client_width':0,'client_height':900}}
        with self.assertRaises(ValueError):adapter.normalized_point(state,10,20)
        state['input_mapping']['client_width']=math.inf
        with self.assertRaises(ValueError):adapter.normalized_point(state,10,20)

if __name__=='__main__':unittest.main()
