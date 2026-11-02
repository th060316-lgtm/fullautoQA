"""Pre-execution capability contract.

The capabilities a target requires are frozen before a run starts, and the frozen
snapshot decides what a later result may claim:

* a capability a target requires may not silently disappear or be downgraded once
  results exist - the difference between the frozen and the current declaration is
  reported as an explicit violation;
* a missing required capability always produces an explicit non PASS outcome;
* only the capabilities a target actually declares are required for that target, the
  tool capability list is never applied universally to every target.

Standard library only.
"""
from __future__ import annotations

from common import CAPABILITIES, inside, read_json

SCHEMA_VERSION = 1
CAPABILITY_CONTRACT_FILE = 'capability_contract.json'
PHASE1_CAPABILITIES = ('capability_contract', 'coordinator_boundary', 'target_identity',
                       'three_hq_gates')
KNOWN_CAPABILITIES = frozenset(CAPABILITIES) | frozenset(PHASE1_CAPABILITIES)
REQUIREMENT_CAPABILITIES = {
    'goal': 'game_launch',
    'save_load': 'save_load',
    'soak': 'soak',
    'regression': 'regression',
    'historical_regression': 'historical_regression_scope',
    'technical_tests': 'technical_qa',
    'seed_replay': 'state_log',
    'player_review_evidence': 'player_review_packet',
}
VIOLATION_PREFIX = {
    'REQUIRED_CAPABILITY_DISAPPEARED': 'capability',
    'REQUIRED_CAPABILITY_DOWNGRADED': 'capability',
    'REQUIRED_CAPABILITY_NOT_AVAILABLE': 'capability',
    'CAPABILITY_DECLARATION_UNAVAILABLE': 'capability',
    'REQUIREMENT_SET_CHANGED': 'requirements',
    'TARGET_CAPABILITY_SET_CHANGED': 'requirements',
}


def capability_contract_path(root, settings=None):
    settings = settings or {}
    rel = settings.get('paths', {}).get('capability_contract', CAPABILITY_CONTRACT_FILE)
    return inside(root, rel)


def declared_capabilities(root, settings=None):
    path = capability_contract_path(root, settings)
    if not path.is_file():
        return None
    data = read_json(path)
    available = set()
    mandatory = set()
    for row in data.get('mandatory_capabilities', []) or []:
        if not isinstance(row, dict):
            continue
        capability = row.get('id')
        if not isinstance(capability, str) or not capability.strip():
            continue
        available.add(capability)
        if row.get('required'):
            mandatory.add(capability)
    return {'available': available, 'mandatory': mandatory}


def target_required_capabilities(entry):
    declared = entry.get('required_capabilities')
    if declared is None:
        declared = []
    if not isinstance(declared, list) or any(not isinstance(c, str) or not c.strip() for c in declared):
        raise ValueError('TARGET_CAPABILITY_INVALID:' + str(entry.get('id')))
    required = {}
    for capability in declared:
        if capability not in KNOWN_CAPABILITIES:
            raise ValueError('UNKNOWN_CAPABILITY:' + capability)
        required[capability] = 'target.declared'
    requirements = entry.get('requirements') or []
    if not isinstance(requirements, list):
        raise ValueError('TARGET_REQUIREMENT_INVALID:' + str(entry.get('id')))
    for requirement in requirements:
        capability = REQUIREMENT_CAPABILITIES.get(requirement)
        if capability:
            required.setdefault(capability, 'target.requirement:' + str(requirement))
    return required


class CapabilityContract:
    def __init__(self, required, declared=None, requirements=None, target_capabilities=None,
                 frozen_at=None, schema_version=SCHEMA_VERSION):
        self.required = dict(required or {})
        self.declared = dict(declared) if declared else None
        self.requirements = dict(requirements or {})
        self.target_capabilities = dict(target_capabilities or {})
        self.frozen_at = frozen_at
        self.schema_version = schema_version

    @classmethod
    def freeze(cls, root, entries, settings=None, frozen_at=None):
        required = {}
        requirements = {}
        target_capabilities = {}
        for entry in entries:
            for capability, source in target_required_capabilities(entry).items():
                required.setdefault(capability, source)
            target_id = str(entry.get('id'))
            requirements[target_id] = sorted(entry.get('requirements') or [])
            target_capabilities[target_id] = sorted(entry.get('required_capabilities') or [])
        declared = declared_capabilities(root, settings)
        if declared is not None:
            declared = {'available': sorted(declared['available']),
                        'mandatory': sorted(declared['mandatory'])}
        return cls(required, declared, requirements, target_capabilities, frozen_at)

    def to_dict(self):
        return {'schema_version': self.schema_version,
                'frozen_at': self.frozen_at,
                'required': self.required,
                'declared': self.declared,
                'requirements': self.requirements,
                'target_capabilities': self.target_capabilities}

    @classmethod
    def from_dict(cls, data):
        data = data or {}
        return cls(data.get('required'), data.get('declared'), data.get('requirements'),
                   data.get('target_capabilities'), data.get('frozen_at'),
                   data.get('schema_version', SCHEMA_VERSION))

    def missing(self, declared=None):
        current = self.declared if declared is None else declared
        if current is None:
            return sorted(self.required)
        available = set(current.get('available') or [])
        return sorted(capability for capability in self.required if capability not in available)

    def preflight(self, declared=None):
        return [{'kind': 'REQUIRED_CAPABILITY_UNAVAILABLE', 'subject': capability}
                for capability in self.missing(declared)]

    def verify(self, declared_after=None, entries_after=None):
        violations = []
        if declared_after is None:
            for capability in sorted(self.required):
                violations.append({'kind': 'CAPABILITY_DECLARATION_UNAVAILABLE',
                                   'subject': capability})
        else:
            before = set((self.declared or {}).get('available') or [])
            before_mandatory = set((self.declared or {}).get('mandatory') or [])
            after = set(declared_after.get('available') or [])
            after_mandatory = set(declared_after.get('mandatory') or [])
            for capability in sorted(self.required):
                if capability in before and capability not in after:
                    violations.append({'kind': 'REQUIRED_CAPABILITY_DISAPPEARED',
                                       'subject': capability})
                elif (capability in before and capability in after and
                      capability in before_mandatory and capability not in after_mandatory):
                    violations.append({'kind': 'REQUIRED_CAPABILITY_DOWNGRADED',
                                       'subject': capability})
        if entries_after is not None:
            current = {str(entry.get('id')): sorted(entry.get('requirements') or [])
                       for entry in entries_after}
            current_caps = {str(entry.get('id')): sorted(entry.get('required_capabilities') or [])
                            for entry in entries_after}
            for target_id in sorted(self.requirements):
                if self.requirements[target_id] != current.get(target_id, []):
                    violations.append({'kind': 'REQUIREMENT_SET_CHANGED', 'subject': target_id})
                if self.target_capabilities.get(target_id, []) != current_caps.get(target_id, []):
                    violations.append({'kind': 'TARGET_CAPABILITY_SET_CHANGED',
                                       'subject': target_id})
        return violations

    def outcome_rows(self, missing=None, violations=None):
        rows = []
        flagged = set()
        for violation in (violations or []):
            subject = violation.get('subject')
            prefix = VIOLATION_PREFIX.get(violation.get('kind'), 'capability')
            rows.append({'test_case': prefix + '.' + str(subject),
                         'status': 'HARNESS_ERROR',
                         'reason_code': violation.get('kind'),
                         'gate': 'REQUIRED',
                         'severity': 'ERROR',
                         'capability': subject})
            flagged.add(subject)
        for capability in (missing or []):
            if capability in flagged:
                continue
            rows.append({'test_case': 'capability.' + capability,
                         'status': 'NOT_RUN',
                         'reason_code': 'REQUIRED_CAPABILITY_UNAVAILABLE',
                         'gate': 'REQUIRED',
                         'severity': 'ERROR',
                         'capability': capability})
        return rows
