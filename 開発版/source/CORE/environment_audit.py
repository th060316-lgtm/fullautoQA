"""Bounded, honest observation of the persistent environment.

Issue #1 asks for acceptance evidence that the run does not permanently
change Program Files, the Registry or PATH.  This module measures what can
actually be measured on a standard, non-administrator Windows session and
reports the rest as ``NOT_MEASURED``.  It never converts an observation that
did not happen into a pass.

Two independent observations are provided:

``registry_environment_audit``
    Every value of the per-user ``Environment`` key and of the machine
    ``Environment`` key, digested by name and value.  A machine session
    cannot write the machine key without elevation, and the completion route
    refuses an elevated session, so the user key is the one that matters.
    The scope is stated in the result: this is **not** a complete Registry
    write audit.

``program_files_audit``
    A bounded listing of the top level of every installed Program Files
    root (name, size, modification time).  Recursive scanning of Program
    Files is not attempted: it is neither cheap nor necessary, because a
    standard user session cannot write there.  The scope is stated as well.

Both observations return a comparable structure, so a caller can take a
``before`` and an ``after`` snapshot and compare them.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

#: Registry keys whose values are digested.  (hive, subkey) with the hives
#: spelled the way ``winreg`` spells them.
REGISTRY_ENVIRONMENT_KEYS = (
    ('HKEY_CURRENT_USER', r'Environment'),
    ('HKEY_CURRENT_USER', r'Volatile Environment'),
    ('HKEY_LOCAL_MACHINE', r'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'),
)

PROGRAM_FILES_ENV_VARS = ('ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432')

#: The scope of each observation.  It is part of every result, including the
#: results that carry no measurement, so that a reader can always tell what
#: was and was not looked at.
REGISTRY_SCOPE = ('Environment and Volatile Environment values only; '
                  'not a complete Registry write audit')
PROGRAM_FILES_SCOPE = ('top level of each Program Files root only; '
                       'not a recursive content audit')


def _digest(value) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, default=str)
    return hashlib.sha256(payload.encode('utf-8')).hexdigest()


def registry_environment_audit():
    """Digest every value of the persistent environment keys.

    Returns ``{'status': 'MEASURED'|'NOT_MEASURED', ...}``.  A key that
    cannot be opened is reported as unread; it is never treated as empty,
    because "unreadable" and "unchanged" are different statements.
    """
    if os.name != 'nt':
        return {'status': 'NOT_MEASURED', 'reason': 'WINDOWS_REQUIRED', 'scope': REGISTRY_SCOPE}
    try:
        import winreg
    except Exception as ex:  # pragma: no cover - defensive
        return {'status': 'NOT_MEASURED', 'reason': 'WINREG_UNAVAILABLE:%s' % type(ex).__name__,
                'scope': REGISTRY_SCOPE}
    hives = {
        'HKEY_CURRENT_USER': winreg.HKEY_CURRENT_USER,
        'HKEY_LOCAL_MACHINE': winreg.HKEY_LOCAL_MACHINE,
    }
    keys = []
    unreadable = []
    for hive_name, subkey in REGISTRY_ENVIRONMENT_KEYS:
        hive = hives[hive_name]
        values = {}
        try:
            with winreg.OpenKey(hive, subkey, 0, winreg.KEY_READ) as handle:
                index = 0
                while True:
                    try:
                        name, value, kind = winreg.EnumValue(handle, index)
                    except OSError:
                        break
                    values[str(name)] = {'registry_type': int(kind), 'sha256': _digest(value)}
                    index += 1
        except FileNotFoundError:
            values = {}
        except OSError as ex:
            unreadable.append('%s\\%s:%s' % (hive_name, subkey, getattr(ex, 'winerror', None)))
            values = None
        if values is None:
            continue
        keys.append({'hive': hive_name, 'key': subkey, 'values': values,
                     'value_count': len(values), 'digest': _digest(values)})
    if unreadable:
        return {
            'status': 'NOT_MEASURED',
            'reason': 'REGISTRY_KEY_UNREADABLE',
            'unreadable': sorted(unreadable),
            'scope': REGISTRY_SCOPE,
        }
    return {
        'status': 'MEASURED',
        'keys': keys,
        'digest': _digest(keys),
        'scope': REGISTRY_SCOPE,
    }


def program_files_audit():
    """Bounded listing of the top level of every Program Files root."""
    roots = []
    for name in PROGRAM_FILES_ENV_VARS:
        root = os.environ.get(name)
        if root and root not in roots:
            roots.append(root)
    if not roots:
        return {'status': 'NOT_MEASURED', 'reason': 'PROGRAM_FILES_ROOTS_UNAVAILABLE',
                'scope': PROGRAM_FILES_SCOPE}
    entries = []
    for root in roots:
        if not os.path.isdir(root):
            entries.append({'root': root, 'name': None, 'state': 'MISSING'})
            continue
        try:
            names = sorted(os.listdir(root))
        except OSError as ex:
            return {'status': 'NOT_MEASURED',
                    'reason': 'PROGRAM_FILES_UNREADABLE:%s' % getattr(ex, 'winerror', None),
                    'scope': PROGRAM_FILES_SCOPE}
        for name in names:
            path = Path(root) / name
            try:
                stat = path.stat()
            except OSError:
                entries.append({'root': root, 'name': name, 'state': 'UNREADABLE'})
                continue
            entries.append({
                'root': root,
                'name': name,
                'state': 'PRESENT',
                'is_dir': path.is_dir(),
                'size': None if path.is_dir() else stat.st_size,
                'mtime_ns': stat.st_mtime_ns,
            })
    return {
        'status': 'MEASURED',
        'roots': roots,
        'entry_count': len(entries),
        'entries': entries,
        'digest': _digest(entries),
        'scope': PROGRAM_FILES_SCOPE,
    }


def compare_observations(before, after):
    """Compare two observations of the same kind.

    ``UNCHANGED`` / ``CHANGED_REQUIRES_REVIEW`` / ``NOT_MEASURED``.  A missing
    measurement is never reported as unchanged.
    """
    if not isinstance(before, dict) or not isinstance(after, dict):
        return 'NOT_MEASURED'
    if before.get('status') != 'MEASURED' or after.get('status') != 'MEASURED':
        return 'NOT_MEASURED'
    if before.get('digest') == after.get('digest'):
        return 'UNCHANGED'
    return 'CHANGED_REQUIRES_REVIEW'


def environment_audit_snapshot():
    """Both observations in one comparable structure."""
    return {
        'registry_environment': registry_environment_audit(),
        'program_files': program_files_audit(),
    }


def environment_audit_comparison(before, after):
    """Compare two environment audit snapshots."""
    registry = compare_observations(
        (before or {}).get('registry_environment'),
        (after or {}).get('registry_environment'),
    )
    program_files = compare_observations(
        (before or {}).get('program_files'),
        (after or {}).get('program_files'),
    )
    return {
        'schema_version': 1,
        'registry_environment_status': registry,
        'program_files_status': program_files,
        'status': 'UNCHANGED' if registry == 'UNCHANGED' and program_files == 'UNCHANGED' else (
            'CHANGED_REQUIRES_REVIEW' if 'CHANGED_REQUIRES_REVIEW' in (registry, program_files) else 'NOT_MEASURED'),
        'scope': 'Environment and Volatile Environment values plus the top level of each Program Files '
                 'root; not a complete Registry or Program Files content audit',
    }
