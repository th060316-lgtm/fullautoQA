"""Contract: every PowerShell script the real machine executes stays ASCII.

Windows PowerShell 5.1 reads a BOM-less ``.ps1`` file with the system ANSI
code page.  A non-ASCII literal in such a file is therefore mojibake on a
real standard-user Windows machine, while the very same file is read as
UTF-8 by PowerShell 7 - which is what hosted CI uses.  That difference made a
whole class of defects invisible to CI and fatal on the real machine, so the
invariant is enforced here instead of being remembered.

A script is acceptable when it is pure ASCII, or when it carries a UTF-8 BOM
(a BOM makes even Windows PowerShell 5.1 read it as UTF-8).

These contracts are about the *repository* checkout.  When the same suite is
executed against a reconstructed (prepared) Source tree the repository scripts
are not present, and the contracts report that fact as a skip instead of
pretending to have verified anything.
"""
from __future__ import annotations

import unittest
from pathlib import Path

#: The repository source-root directory name.  It is deliberately NOT spelled
#: out here: the point of the contract is that no script may depend on it.
SOURCE_ROOT_NAME = '開発版'


def _find_repository_root():
    for parent in Path(__file__).resolve().parents:
        if (parent / 'RUN_LOCAL_COMPLETION.ps1').is_file():
            return parent
    return None


REPO_ROOT = _find_repository_root()


def _iter_scripts():
    seen = set()
    for path in REPO_ROOT.rglob('*.ps1'):
        if '.git' in path.parts:
            continue
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        yield path


def _is_ascii_or_utf8_bom(path: Path) -> bool:
    raw = path.read_bytes()
    if raw.startswith(b'\xef\xbb\xbf'):
        return True
    try:
        raw.decode('ascii')
    except UnicodeDecodeError:
        return False
    return True


class WindowsScriptEncodingContractTests(unittest.TestCase):
    @unittest.skipIf(REPO_ROOT is None,
                     'the repository checkout is not present (prepared Source tree)')
    def test_every_shipped_script_is_ascii_only_or_utf8_with_bom(self):
        offenders = []
        for path in _iter_scripts():
            if not _is_ascii_or_utf8_bom(path):
                offenders.append(str(path.relative_to(REPO_ROOT)))
        self.assertEqual([], offenders,
                         'these scripts contain non-ASCII bytes and no UTF-8 BOM, so Windows '
                         'PowerShell 5.1 reads them with the system ANSI code page')

    @unittest.skipIf(REPO_ROOT is None,
                     'the repository checkout is not present (prepared Source tree)')
    def test_the_scripts_that_resolve_declared_inputs_carry_no_non_ascii_literal(self):
        """The declared-input path must never be written literally."""
        source_root = REPO_ROOT / SOURCE_ROOT_NAME
        targets = [
            REPO_ROOT / 'RUN_LOCAL_COMPLETION.ps1',
            source_root / 'source' / 'scripts' / 'PREPARE_SOURCE.ps1',
            source_root / 'rollback' / 'RESTORE_PREDECESSOR.ps1',
            source_root / 'source' / 'scripts' / 'REPOSITORY_ENTRY.ps1',
            source_root / 'source' / 'scripts' / 'SOURCE_TREE_FINGERPRINT.ps1',
        ]
        for path in targets:
            self.assertTrue(path.is_file(), 'missing ' + str(path))
            text = path.read_text(encoding='utf-8')
            self.assertNotIn(SOURCE_ROOT_NAME,
                             text,
                             '%s writes the non-ASCII source-root name literally; the source '
                             'root must be discovered structurally' % path.name)

    @unittest.skipIf(REPO_ROOT is None,
                     'the repository checkout is not present (prepared Source tree)')
    def test_the_shared_entry_contract_exists_and_is_referenced(self):
        source_root = REPO_ROOT / SOURCE_ROOT_NAME
        module = source_root / 'source' / 'scripts' / 'REPOSITORY_ENTRY.ps1'
        self.assertTrue(module.is_file())
        for path in (REPO_ROOT / 'RUN_LOCAL_COMPLETION.ps1',
                     source_root / 'source' / 'scripts' / 'PREPARE_SOURCE.ps1',
                     source_root / 'rollback' / 'RESTORE_PREDECESSOR.ps1'):
            text = path.read_text(encoding='utf-8')
            self.assertIn('REPOSITORY_ENTRY.ps1', text,
                          '%s must use the shared entry contract' % path.name)


if __name__ == '__main__':
    unittest.main()
