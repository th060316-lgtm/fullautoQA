"""Distribution-wide corruption checks, separate from CORE-only integrity."""
import json
import struct
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from package_integrity import check_archive, check_package_manifest, inventory, seal_package

class PackageDistributionTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        for name in ['CORE/z.py', 'CORE/A.py', 'RUNTIME/python/python.exe', 'PAYLOAD/runtime.zip', 'PROFILES/user.json']:
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(name.encode())
        seal_package(self.root)

    def test_sealed_distribution_passes(self):
        self.assertEqual(check_package_manifest(self.root), [])

    def test_support_file_corruption_fails(self):
        (self.root / 'PROFILES/user.json').write_bytes(b'changed')
        self.assertIn('PACKAGE_CONTENT_CHANGED', check_package_manifest(self.root))

    def test_extra_file_rejected(self):
        (self.root / 'CORE/injected.py').write_bytes(b'x')
        self.assertIn('PACKAGE_FILE_SET_CHANGED', check_package_manifest(self.root))

    def test_missing_runtime_rejected(self):
        (self.root / 'RUNTIME/python/python.exe').unlink()
        self.assertIn('PACKAGE_FILE_SET_CHANGED', check_package_manifest(self.root))

    def test_duplicate_and_path_escape_rejected(self):
        manifest = self.root / 'package_manifest.json'
        data = json.loads(manifest.read_text())
        data['files'].append(dict(data['files'][0]))
        manifest.write_text(json.dumps(data))
        self.assertIn('PACKAGE_MANIFEST_DUPLICATE', check_package_manifest(self.root))
        data['files'][-1]['path'] = '../outside'
        manifest.write_text(json.dumps(data))
        self.assertTrue(any('PATH_ESCAPE' in e for e in check_package_manifest(self.root)))

    def test_transient_evidence_and_marker_do_not_mutate_distribution(self):
        (self.root / 'RESULTS').mkdir()
        (self.root / 'RESULTS/run.json').write_bytes(b'run')
        marker = self.root / 'PHASE3_FRESH_EXTRACTION.marker'
        marker.write_bytes(b'fresh')
        self.assertEqual(check_package_manifest(self.root), [])
        marker.unlink()
        self.assertEqual(check_package_manifest(self.root), [])

    def test_preserved_inventory_covers_runtime_and_payload_bytes(self):
        before = inventory(self.root, True)
        self.assertEqual({r['path'] for r in before}, {'RUNTIME/python/python.exe', 'PAYLOAD/runtime.zip'})
        (self.root / 'PAYLOAD/runtime.zip').write_bytes(b'changed')
        self.assertNotEqual(inventory(self.root, True), before)

    def test_archive_crc_detects_payload_corruption(self):
        path = self.root / 'candidate.zip'
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr('data.txt', b'unmodified data')
        self.assertEqual(check_archive(path), [])
        data = bytearray(path.read_bytes())
        name_length, extra_length = struct.unpack_from('<HH', data, 26)
        data[30 + name_length + extra_length] ^= 1
        path.write_bytes(data)
        self.assertTrue(check_archive(path))

    def test_archive_duplicate_and_escape_rejected(self):
        path = self.root / 'candidate.zip'
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('a', b'a')
                archive.writestr('a', b'b')
        self.assertIn('ARCHIVE_DUPLICATE', check_archive(path))
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('../escape', b'bad')
        self.assertTrue(any('UNSAFE_ARCHIVE' in e for e in check_archive(path)))
