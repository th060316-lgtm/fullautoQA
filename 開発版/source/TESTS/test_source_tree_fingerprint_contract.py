"""Contract for the ONE canonical Source-tree fingerprint.

The runner (producer) and the Candidate builder (verifier) must agree on the
exact bytes they are talking about.  Three copies of the algorithm used to
exist in this repository - in the runner, in the Candidate builder and in the
CI workflow.  They agreed with each other, but they were not reproducible:
the rows were joined with the host newline (CRLF on Windows, LF on Linux),
sorted with the current culture's comparer, and bytecode caches were counted
as Source.  The same tree therefore hashed differently on a Japanese machine
and on an English CI runner, and again as soon as Python wrote a
``__pycache__`` directory into it.

The canonical row format is:

    <relative path> TAB <size> TAB <sha256 lowercase hex>

ordered ordinally by the relative path, joined with a single LF and hashed
as UTF-8.  Transient bytecode caches (``__pycache__`` and ``.pyc``/``.pyo``)
are not part of the Source identity.
"""
from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE_ROOT / 'scripts'))

import source_tree_immutability as immutability  # noqa: E402


class CanonicalFingerprintContractTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / 'tree'
        (self.root / 'CORE').mkdir(parents=True)
        (self.root / 'CORE' / 'a.py').write_text('x = 1\n', encoding='utf-8')
        (self.root / 'CORE' / 'b.py').write_text('y = 2\n', encoding='utf-8')
        (self.root / 'README.md').write_text('readme\n', encoding='utf-8')

    def tearDown(self):
        self._tmp.cleanup()

    def test_rows_are_tab_separated_and_ordinally_ordered(self):
        files = immutability.collect(self.root)
        rows = immutability.canonical_rows(files)
        self.assertEqual(['CORE/a.py', 'CORE/b.py', 'README.md'],
                         [row.split('\t')[0] for row in rows])
        for row in rows:
            parts = row.split('\t')
            self.assertEqual(3, len(parts))
            self.assertEqual(64, len(parts[2]))
            self.assertEqual(parts[2], parts[2].lower())

    def test_fingerprint_is_the_sha256_of_the_lf_joined_rows(self):
        files = immutability.collect(self.root)
        expected = hashlib.sha256(
            '\n'.join(immutability.canonical_rows(files)).encode('utf-8')).hexdigest()
        self.assertEqual(expected, immutability.fingerprint(files))

    def test_bytecode_caches_are_not_part_of_the_source_identity(self):
        before = immutability.fingerprint(immutability.collect(self.root))
        cache = self.root / 'CORE' / '__pycache__'
        cache.mkdir()
        (cache / 'a.cpython-311.pyc').write_bytes(b'\x00compiled')
        (self.root / 'stale.pyc').write_bytes(b'\x00compiled')
        after = immutability.fingerprint(immutability.collect(self.root))
        self.assertEqual(before, after,
                         'transient bytecode caches must not change the Source identity')

    def test_a_changed_source_file_changes_the_fingerprint(self):
        before = immutability.fingerprint(immutability.collect(self.root))
        (self.root / 'CORE' / 'a.py').write_text('x = 99\n', encoding='utf-8')
        after = immutability.fingerprint(immutability.collect(self.root))
        self.assertNotEqual(before, after)

    def test_the_immutability_audit_detects_a_mutated_input(self):
        snapshot = immutability.snapshot(self.root)
        (self.root / 'CORE' / 'a.py').write_text('x = 99\n', encoding='utf-8')
        (self.root / 'CORE' / 'c.py').write_text('z = 3\n', encoding='utf-8')
        result = immutability.compare(snapshot, immutability.snapshot(self.root))
        self.assertEqual('FAIL', result['status'])
        self.assertEqual(['CORE/a.py'], result['changed'])
        self.assertEqual(['CORE/c.py'], result['added'])

    def test_the_immutability_audit_passes_an_untouched_input(self):
        snapshot = immutability.snapshot(self.root)
        result = immutability.compare(snapshot, immutability.snapshot(self.root))
        self.assertEqual('PASS', result['status'])
        self.assertEqual(0, result['change_count'])

    def test_the_snapshot_manifest_carries_the_canonical_format(self):
        snapshot = immutability.snapshot(self.root)
        self.assertEqual(immutability.SCHEMA_VERSION, snapshot['schema_version'])
        self.assertEqual(immutability.ALGORITHM, snapshot['algorithm'])
        self.assertEqual(3, snapshot['file_count'])
        self.assertEqual(snapshot['fingerprint'],
                         immutability.fingerprint(snapshot['files']))
        json.dumps(snapshot)

    def test_the_powershell_implementation_declares_the_same_algorithm(self):
        script = SOURCE_ROOT / 'scripts' / 'SOURCE_TREE_FINGERPRINT.ps1'
        self.assertTrue(script.is_file())
        text = script.read_text(encoding='utf-8')
        self.assertIn('relative-path-tab-size-tab-sha256', text)
        self.assertIn("StringComparer]::Ordinal", text)
        self.assertIn('[char]10', text)
        self.assertIn('__pycache__', text)
        self.assertIn('.pyc', text)


if __name__ == '__main__':
    unittest.main()
