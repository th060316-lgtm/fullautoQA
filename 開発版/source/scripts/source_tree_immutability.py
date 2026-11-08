"""Canonical Source-tree identity and regression-immutability audit.

This module is the Python binding of the ONE canonical Source-tree algorithm
that is also implemented by ``scripts/SOURCE_TREE_FINGERPRINT.ps1``.  The two
implementations must produce byte-identical fingerprints for the same tree;
the Windows PowerShell 5.1 contract job compares them on the real repository
tree, so the two can never drift apart silently.

Three copies of this algorithm used to exist - one in the runner, one in the
Candidate builder and one in the CI workflow - and they agreed with each
other.  They were nevertheless not reproducible:

* the rows were joined with the host newline, so the same tree hashed
  differently on Windows (CRLF) and on Linux (LF);
* the rows were sorted with the current culture's comparer, so the order -
  and therefore the hash - depended on the machine's locale;
* bytecode caches were counted as Source, so the hash of a tree changed
  whenever Python wrote a ``__pycache__`` directory into it.

Canonical row format (identical in both implementations)
--------------------------------------------------------
* every regular file under the root is collected;
* files inside a ``__pycache__`` directory and files ending in ``.pyc`` or
  ``.pyo`` are excluded - they are transient bytecode caches, not Source;
* the relative path is POSIX style and relative to the root;
* one row per file: ``<relative path> TAB <size> TAB <sha256 lowercase hex>``;
* rows are sorted by .NET-style ordinal UTF-16 code units, matching
  ``StringComparer.Ordinal`` exactly even when a path contains supplementary
  Unicode characters;
* rows are joined with a single LF and the payload is hashed as UTF-8.

The audit is fail-closed: a regression that modified its own input tree is
reported as a failure and never as a pass.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

SCHEMA_VERSION = 1
ALGORITHM = ('relative-path-tab-size-tab-sha256; rows ordinal; LF; UTF-8; '
             'excludes __pycache__ and .pyc/.pyo')
EXCLUDED_DIRECTORIES = frozenset({'__pycache__'})
EXCLUDED_SUFFIXES = frozenset({'.pyc', '.pyo'})


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def eligible(relative: Path) -> bool:
    """True when the relative path belongs to the canonical Source set."""
    for part in relative.parts:
        if part in EXCLUDED_DIRECTORIES:
            return False
    if relative.suffix.lower() in EXCLUDED_SUFFIXES:
        return False
    return True


def collect(root: Path) -> dict:
    """Relative path -> {'size': int, 'sha256': str} for the canonical set."""
    root = root.resolve()
    files = {}
    for path in root.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(root)
        if not eligible(relative):
            continue
        files[relative.as_posix()] = {
            'size': path.stat().st_size,
            'sha256': sha256(path),
        }
    return files


def ordinal_path_key(value: str) -> tuple:
    """Match .NET ``StringComparer.Ordinal`` using UTF-16 code units.

    Python normally sorts Unicode strings by code point.  .NET ordinal string
    comparison sorts UTF-16 code units, which differs for supplementary
    characters.  The PowerShell binding uses ``StringComparer.Ordinal``, so the
    Python binding must use the same ordering for every valid path, not only
    the current ASCII-heavy tree.
    """
    encoded = value.encode('utf-16-le', errors='surrogatepass')
    return tuple(encoded[index] | (encoded[index + 1] << 8)
                 for index in range(0, len(encoded), 2))


def canonical_rows(files: dict) -> list:
    """The canonical row list: .NET ordinal sort by relative path."""
    return [
        '{}'.format(relative) + '\t' + str(files[relative]['size']) + '\t' + files[relative]['sha256']
        for relative in sorted(files, key=ordinal_path_key)
    ]


def fingerprint(files: dict) -> str:
    """Canonical fingerprint of a collected file set."""
    payload = '\n'.join(canonical_rows(files))
    return hashlib.sha256(payload.encode('utf-8')).hexdigest()


def snapshot(root: Path) -> dict:
    files = collect(root)
    return {
        'schema_version': SCHEMA_VERSION,
        'algorithm': ALGORITHM,
        'root': str(root.resolve()),
        'fingerprint': fingerprint(files),
        'file_count': len(files),
        'files': files,
    }


def compare(before: dict, after: dict) -> dict:
    a = before.get('files') or {}
    b = after.get('files') or {}
    added = sorted(set(b) - set(a))
    removed = sorted(set(a) - set(b))
    changed = sorted(name for name in set(a) & set(b) if a[name] != b[name])
    return {
        'schema_version': SCHEMA_VERSION,
        'algorithm': ALGORITHM,
        'status': 'PASS' if not (added or removed or changed) else 'FAIL',
        'before_fingerprint': before.get('fingerprint'),
        'after_fingerprint': after.get('fingerprint'),
        'added': added,
        'removed': removed,
        'changed': changed,
        'change_count': len(added) + len(removed) + len(changed),
    }


def load_snapshot(path: Path) -> dict:
    return json.loads(path.read_text(encoding='utf-8-sig'))


def write(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    snap = sub.add_parser('snapshot')
    snap.add_argument('--root', required=True)
    snap.add_argument('--output', required=True)
    compare_cmd = sub.add_parser('compare')
    compare_cmd.add_argument('--root', required=True)
    compare_cmd.add_argument('--before', required=True)
    compare_cmd.add_argument('--output', required=True)
    args = parser.parse_args()

    root = Path(args.root)
    if args.command == 'snapshot':
        value = snapshot(root)
        write(Path(args.output), value)
        print('SOURCE_TREE_FINGERPRINT=' + value['fingerprint'])
        return 0

    before = load_snapshot(Path(args.before))
    after = snapshot(root)
    result = compare(before, after)
    write(Path(args.output), result)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['status'] == 'PASS' else 2


if __name__ == '__main__':
    raise SystemExit(main())
