"""Deterministic target identity and stale state defence.

The identity of a target has two independent parts:

* fingerprint - a deterministic digest of the declared target / profile identity
  and of the relevant source and config bytes. Identical inputs always produce an
  identical fingerprint, and no absolute user path is part of it.
* generation - a monotonically increasing counter kept in a binding ledger. The
  fingerprint of a replaced and later restored target is unchanged, the generation is
  not. That is what tells a fresh A apart from a stale A after an A -> B -> A
  replacement.

Standard library only.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

from common import digest, inside, read_json, stamp, write_json
from targets import target_kind

SCHEMA_VERSION = 1
DEFAULT_BINDINGS = 'QA_BINDINGS.json'
STALE_AUDIT_FILE = 'STALE_STATE_AUDIT.json'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def sha256_text(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def sha256_value(value):
    return sha256_text(canonical(value))


def file_digest(path):
    path = Path(path)
    return digest(path) if path.is_file() else None


def tree_digest(path):
    path = Path(path)
    if not path.exists():
        return None
    if path.is_file():
        return digest(path)
    rows = []
    for current, dirs, files in os.walk(path, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not (Path(current) / d).is_symlink())
        for name in sorted(files):
            item = Path(current) / name
            if item.is_symlink() or not item.is_file():
                continue
            if '__pycache__' in item.parts or name.endswith('.pyc'):
                continue
            rows.append(item.relative_to(path).as_posix() + '\0' + str(item.stat().st_size)
                        + '\0' + digest(item))
    return sha256_text('\n'.join(rows))


def relative_to_root(root, path):
    root = Path(root).resolve()
    try:
        return Path(path).resolve().relative_to(root).as_posix()
    except ValueError:
        return Path(path).name


def declared_path(root, rel, code='TARGET_PATH_INVALID'):
    if not isinstance(rel, str) or not rel.strip():
        raise ValueError(code)
    return inside(root, rel)


def identity_components(root, entry, profile=None):
    root = Path(root)
    profile_rel = entry.get('profile')
    components = {'target_id': str(entry.get('id')),
                  'kind': target_kind(profile, entry),
                  'profile': None,
                  'profile_digest': None,
                  'requirements_digest': sha256_value({
                      'requirements': sorted(entry.get('requirements') or []),
                      'required_agents': sorted(entry.get('required_agents') or []),
                      'required_capabilities': sorted(entry.get('required_capabilities') or [])}),
                  'source_digest': None,
                  'config_digest': None,
                  'instance_digest': None}
    if profile_rel:
        resolved = declared_path(root, profile_rel)
        components['profile'] = relative_to_root(root, resolved)
        components['profile_digest'] = file_digest(resolved)
    source = entry.get('source') or (profile or {}).get('source')
    if source:
        components['source_digest'] = tree_digest(declared_path(root, source))
    config = entry.get('config')
    if config:
        components['config_digest'] = tree_digest(declared_path(root, config))
    marker = entry.get('instance_marker') or (profile or {}).get('instance_marker')
    if marker:
        components['instance_digest'] = file_digest(declared_path(root, marker))
    return components


class TargetIdentity:
    def __init__(self, target_id, kind, fingerprint, components=None, generation=1,
                 certifies_real_target=None, lineage_broken=False, ledger_persisted=True):
        self.target_id = target_id
        self.kind = kind
        self.fingerprint = fingerprint
        self.components = dict(components or {})
        self.generation = int(generation)
        self.certifies_real_target = (kind == 'target') if certifies_real_target is None \
            else bool(certifies_real_target)
        self.lineage_broken = bool(lineage_broken)
        self.ledger_persisted = bool(ledger_persisted)

    def to_dict(self):
        return {'schema_version': SCHEMA_VERSION,
                'target_id': self.target_id,
                'kind': self.kind,
                'fingerprint': self.fingerprint,
                'components': json.loads(canonical(self.components)),
                'generation': self.generation,
                'certifies_real_target': self.certifies_real_target,
                'lineage_broken': self.lineage_broken,
                'ledger_persisted': self.ledger_persisted}

    @classmethod
    def from_dict(cls, data):
        data = data or {}
        return cls(data.get('target_id'), data.get('kind'), data.get('fingerprint'),
                   data.get('components'), data.get('generation', 1),
                   data.get('certifies_real_target'), data.get('lineage_broken', False),
                   data.get('ledger_persisted', True))

    def short(self):
        return {'target_id': self.target_id, 'kind': self.kind,
                'fingerprint': self.fingerprint, 'generation': self.generation,
                'certifies_real_target': self.certifies_real_target}


def bindings_path(root, settings=None):
    settings = settings or {}
    rel = settings.get('paths', {}).get('target_bindings', DEFAULT_BINDINGS)
    return inside(root, rel)


def load_bindings(root, settings=None):
    path = bindings_path(root, settings)
    if not path.is_file():
        return {'schema_version': SCHEMA_VERSION, 'targets': {}}
    data = read_json(path)
    if (not isinstance(data, dict) or data.get('schema_version') != SCHEMA_VERSION
            or not isinstance(data.get('targets'), dict)):
        raise ValueError('TARGET_BINDINGS_INVALID')
    for key, record in data['targets'].items():
        if not isinstance(key,str) or not isinstance(record,dict):
            raise ValueError('TARGET_BINDINGS_INVALID')
        generation = record.get('generation')
        history = record.get('history')
        if (not isinstance(generation,int) or isinstance(generation,bool) or generation < 1
                or not isinstance(history,list) or len(history) != generation
                or record.get('kind') not in ('target','fixture','selftest')):
            raise ValueError('TARGET_BINDINGS_INVALID')
        for index, item in enumerate(history,1):
            if (not isinstance(item,dict) or item.get('generation') != index
                    or not isinstance(item.get('fingerprint'),str) or len(item['fingerprint']) != 64):
                raise ValueError('TARGET_BINDINGS_INVALID')
        if history[-1]['fingerprint'] != record.get('fingerprint'):
            raise ValueError('TARGET_BINDINGS_INVALID')
    return data


def save_bindings(root, data, settings=None):
    write_json(bindings_path(root, settings), data)


def bind_target(root, entry, profile=None, settings=None, observed_at=None):
    root = Path(root)
    kind = target_kind(profile, entry)
    components = identity_components(root, entry, profile)
    fingerprint = sha256_value(components)
    ledger = load_bindings(root, settings)
    target_id = str(entry.get('id'))
    record = ledger['targets'].get(target_id) or {}
    generation = int(record.get('generation', 0)) + 1
    previous = record.get('fingerprint')
    history = list(record.get('history') or [])
    history.append({'generation': generation, 'fingerprint': fingerprint,
                    'observed_at': observed_at or stamp()})
    ledger['targets'][target_id] = {'generation': generation, 'fingerprint': fingerprint,
                                    'kind': kind, 'history': history}
    persisted = True
    try:
        save_bindings(root, ledger, settings)
    except OSError:
        persisted = False
    identity = TargetIdentity(target_id, kind, fingerprint, components, generation,
                              certifies_real_target=(kind == 'target' and persisted),
                              lineage_broken=bool(previous) and previous != fingerprint,
                              ledger_persisted=persisted)
    return identity


def check_result_binding(identity, recorded):
    if not isinstance(recorded, dict) or not recorded:
        return ['TARGET_IDENTITY_MISSING']
    violations = []
    if recorded.get('target_id') != identity.target_id:
        violations.append('TARGET_ID_MISMATCH')
    if recorded.get('fingerprint') != identity.fingerprint:
        violations.append('TARGET_FINGERPRINT_MISMATCH')
    if recorded.get('generation') != identity.generation:
        violations.append('STALE_TARGET_GENERATION')
    if recorded.get('kind') != identity.kind:
        violations.append('TARGET_KIND_MISMATCH')
    return violations


def check_baseline_reuse(identity, recorded, root=None, settings=None):
    if not isinstance(recorded, dict) or not recorded:
        return ['BASELINE_IDENTITY_MISSING']
    violations = []
    if recorded.get('fingerprint') != identity.fingerprint:
        violations.append('BASELINE_FINGERPRINT_MISMATCH')
    if recorded.get('target_id') != identity.target_id or recorded.get('kind') != identity.kind:
        violations.append('BASELINE_TARGET_MISMATCH')
    generation = recorded.get('generation')
    if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
        violations.append('BASELINE_GENERATION_INVALID')
    if isinstance(generation, int) and generation > identity.generation:
        violations.append('BASELINE_GENERATION_AHEAD')
    if root is not None:
        ledger = load_bindings(root, settings)
        history = (ledger['targets'].get(str(identity.target_id)) or {}).get('history') or []
        if not any(item.get('generation') == generation and item.get('fingerprint') == recorded.get('fingerprint') for item in history):
            violations.append('BASELINE_GENERATION_UNVERIFIABLE')
        if not history:
            violations.append('BASELINE_LINEAGE_UNVERIFIABLE')
        else:
            for entry in history:
                if isinstance(generation, int) and int(entry.get('generation', 0)) < generation:
                    continue
                if entry.get('fingerprint') != recorded.get('fingerprint'):
                    violations.append('STALE_BASELINE_LINEAGE_BROKEN')
                    break
    return violations


def audit_results(root, identity, results_dir, settings=None):
    findings = []
    base = Path(results_dir)
    if not base.is_dir():
        return findings
    for path in sorted(base.rglob('result.json')):
        try:
            data = read_json(path)
        except (OSError, ValueError):
            continue
        violations = check_result_binding(identity, data.get('target_identity'))
        findings.append({'file': relative_to_root(base, path), 'kind': 'result',
                         'verdict': 'STALE' if violations else 'CURRENT',
                         'violations': violations})
    return findings


def write_stale_audit(root, identity, findings, settings=None):
    root = Path(root)
    settings = settings or {}
    rel = settings.get('paths', {}).get('stale_audit', STALE_AUDIT_FILE)
    path = inside(root, rel)
    payload = {'schema_version': SCHEMA_VERSION,
               'target': identity.short(),
               'stale': [f for f in findings if f.get('verdict') == 'STALE'],
               'current': [f for f in findings if f.get('verdict') != 'STALE']}
    write_json(path, payload)
    return path
