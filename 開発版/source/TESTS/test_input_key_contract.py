"""Standard function keys remain profile-owned, independent of game/engine."""
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from windows import vk

class InputKeyContractTests(unittest.TestCase):
    def test_all_standard_function_keys(self):
        for number in range(1,25):
            with self.subTest(number=number):
                self.assertEqual(vk('F'+str(number)),0x70+number-1)
                self.assertEqual(vk('f'+str(number)),0x70+number-1)

    def test_invalid_function_keys_rejected(self):
        for name in ('F0','F25','F01','F-1','F1junk'):
            with self.subTest(name=name):
                with self.assertRaises(ValueError):vk(name)

    def test_existing_bindings_preserved(self):
        self.assertEqual(vk('ENTER'),13)
        self.assertEqual(vk('F5'),116)
        self.assertEqual(vk('F9'),120)
        self.assertEqual(vk('a'),65)
