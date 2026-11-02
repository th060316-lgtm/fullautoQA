"""Coordination boundary for the three-headquarters pipeline.

The coordinator decides what runs, in which order, and how the domains are summarised.
It never re-implements production QA: the production domain is derived from the
result rows the existing QA run already produced. Phase 2 registers management and
sales evaluators on the coordinator instead of editing windows_runner.py.

The coordinator is additive. It never rewrites the baseline fields of a result, and a
failure inside an evaluator can only make a domain worse, never better.

Standard library only.
"""
from __future__ import annotations

import json
from pathlib import Path
from types import MappingProxyType

from capability_contract import CapabilityContract, declared_capabilities
from common import inside, read_json, write_json, stamp
from headquarters import DOMAIN_ORDER, DomainReport, HeadquartersSummary
from target_identity import (TargetIdentity, bind_target, canonical, identity_components,
                             sha256_value, load_bindings, check_result_binding)
from targets import load_target_manifest

MANAGEMENT_NOT_RUN = 'MANAGEMENT_EVALUATION_NOT_PERFORMED'
SALES_NOT_RUN = 'SALES_EVALUATION_NOT_PERFORMED'
TARGET_NOT_REAL = 'TARGET_IDENTITY_NOT_REAL_TARGET'


class CoordinatorContext:
    def __init__(self, root=None, results=(), identity=None, contract=None, settings=None,
                 extras=None):
        self.root = Path(root) if root is not None else Path('.')
        self.results = list(results)
        self.identity = identity
        self.contract = contract
        self.settings = settings or {}
        self.extras = dict(extras or {})


def production_evaluator(context):
    rows = list(context.results)
    notes = []
    contract = context.contract
    if contract is not None:
        current = declared_capabilities(context.root, context.settings)
        missing = contract.missing(current)
        violations = contract.verify(current, context.extras.get('entries_after'))
        rows += contract.outcome_rows(missing, violations)
        for violation in violations:
            notes.append(violation.get('kind') + ':' + str(violation.get('subject')))
    identity = context.identity
    certifies = bool(identity is not None and identity.certifies_real_target)
    if identity is not None and not certifies:
        rows.append({'test_case': 'target.identity.real_target', 'status': 'NOT_RUN',
                     'reason_code': TARGET_NOT_REAL, 'gate': 'REQUIRED', 'severity': 'ERROR'})
        notes.append(TARGET_NOT_REAL)
    target = identity.to_dict() if isinstance(identity, TargetIdentity) else identity
    report = DomainReport.from_results('production', rows,
                                       certifies_real_target=certifies, target=target)
    report.notes = notes
    return report


def not_run_evaluator(domain, reason_code):
    def evaluator(context):
        return DomainReport.not_run(domain, reason_code)
    return evaluator


class Coordinator:
    def __init__(self, root, settings=None):
        self.root = Path(root)
        self.settings = settings or {}
        self._evaluators = {
            'production': production_evaluator,
            'management': not_run_evaluator('management', MANAGEMENT_NOT_RUN),
            'sales': not_run_evaluator('sales', SALES_NOT_RUN),
        }

    def register(self, domain, evaluator):
        if domain not in DOMAIN_ORDER:
            raise ValueError('UNKNOWN_DOMAIN:' + str(domain))
        if not callable(evaluator):
            raise ValueError('EVALUATOR_NOT_CALLABLE:' + str(domain))
        self._evaluators[domain] = evaluator
        return self

    def evaluate(self, context):
        reports = []
        for name in DOMAIN_ORDER:
            evaluator = self._evaluators.get(name)
            if evaluator is None:
                continue
            report = evaluator(context)
            if report is None:
                continue
            if report.name != name:
                raise ValueError('DOMAIN_NAME_MISMATCH:' + str(report.name))
            reports.append(report)
        return HeadquartersSummary(reports)

    def preflight(self, context):
        problems = []
        if context.contract is not None:
            current = declared_capabilities(context.root, context.settings)
            problems += context.contract.preflight(current)
        return problems

    def attach(self, result_data, summary, context=None):
        data = dict(result_data or {})
        data['headquarters'] = summary.to_dict()
        if context is not None:
            if context.contract is not None:
                data['capability_contract'] = context.contract.to_dict()
            if context.identity is not None:
                data['target_identity'] = context.identity.to_dict()
        return data


def build_payload(root, results, summary, identity=None, contract=None, settings=None,
                  result_data=None):
    coordinator = Coordinator(root, settings)
    context = CoordinatorContext(root=root, results=results, identity=identity,
                                 contract=contract, settings=settings)
    payload = dict(result_data or {})
    return coordinator.attach(payload, summary, context)


def prepare_execution(root, manifest, settings=None):
    root = Path(root)
    entries = json.loads(canonical(manifest.get('targets') or []))
    contract = CapabilityContract.freeze(root, entries, settings=settings, frozen_at=stamp())
    identities = {}
    for entry in entries:
        profile = None
        rel = entry.get('profile')
        if rel:
            path = inside(root, rel)
            if path.is_file():
                try:
                    profile = read_json(path)
                except (OSError, ValueError):
                    profile = None
        identities[str(entry.get('id'))] = bind_target(root, entry, profile, settings=settings)
    return MappingProxyType({'contract': contract, 'identities': MappingProxyType(identities),
            'manifest_snapshot': canonical(manifest),
            'identity_snapshot': canonical({key: value.to_dict() for key, value in sorted(identities.items())})})


def attach_summary_to_result_file(path, root=None, settings=None):
    path = Path(path)
    if not path.is_file():
        return None
    if (path.parent / 'RESULT_FOR_CHATGPT.zip').exists() or (path.parent / 'evidence_manifest.json').exists():
        raise ValueError('RESULT_ALREADY_FINALIZED')
    data = read_json(path)
    coordinator = Coordinator(root if root is not None else path.parent, settings)
    context = CoordinatorContext(root=coordinator.root, results=data.get('results') or [],
                                 settings=settings)
    summary = coordinator.evaluate(context)
    data = coordinator.attach(data, summary, context)
    write_json(path, data)
    return summary



def preflight_execution(e, prepared):
    """Record a freeze before any target Session is created; never infer it from rows."""
    snapshot = {'manifest': json.loads(prepared['manifest_snapshot']),
                'capability_contract': prepared['contract'].to_dict(),
                'target_identity': json.loads(prepared['identity_snapshot'])}
    write_json(e.root / 'execution_frozen.json', snapshot)
    rows = prepared['contract'].outcome_rows(prepared['contract'].missing())
    for key, recorded in snapshot['target_identity'].items():
        if not recorded.get('ledger_persisted'):
            rows.append({'test_case': 'target.' + key + '.ledger', 'status': 'HARNESS_ERROR',
                         'reason_code': 'TARGET_BINDING_NOT_PERSISTED', 'gate': 'REQUIRED'})
    for row in rows:
        row['evidence'] = ['execution_frozen.json']
    return rows


def verify_execution(root, prepared, settings=None, current_manifest=None):
    """Read the current declaration, bytes and ledger without incrementing generation."""
    current = load_target_manifest(root, settings) if current_manifest is None else current_manifest
    entries = current['targets']
    contract = prepared['contract']
    declared = declared_capabilities(root, settings)
    violations = contract.verify(declared, entries)
    frozen = json.loads(prepared['manifest_snapshot'])
    if canonical(current) != canonical(frozen):
        violations.append({'kind': 'TARGET_MANIFEST_CHANGED', 'subject': 'targets'})
    identities = json.loads(prepared['identity_snapshot'])
    ledger = load_bindings(root, settings)
    by_id = {str(entry['id']): entry for entry in entries}
    for key, recorded in sorted(identities.items()):
        identity = TargetIdentity.from_dict(recorded)
        if not identity.ledger_persisted:
            violations.append({'kind': 'TARGET_BINDING_NOT_PERSISTED', 'subject': key})
        entry = by_id.get(key)
        if entry is None:
            violations.append({'kind': 'TARGET_IDENTITY_MISSING', 'subject': key})
            continue
        profile = read_json(inside(root, entry['profile']))
        actual = identity_components(root, entry, profile)
        if sha256_value(actual) != identity.fingerprint:
            violations.append({'kind': 'TARGET_FINGERPRINT_MISMATCH', 'subject': key})
        record = ledger['targets'].get(key) or {}
        check = dict(record, target_id=key)
        for reason in check_result_binding(identity, check):
            violations.append({'kind': reason, 'subject': key})
        # An in-memory identity replacement is as invalid as replacing the ledger.
        for reason in check_result_binding(identity, prepared['identities'][key].to_dict()):
            violations.append({'kind': reason, 'subject': key})
    return contract.outcome_rows(contract.missing(declared), violations)


def execution_finalizer(root, prepared, settings=None, run_mode='target'):
    """Callback for finalize_run.refresh, including cleanup/report failure refreshes."""
    checked = False
    coordinator = Coordinator(root, settings)
    def attach(e, data):
        nonlocal checked
        rows = data.setdefault('results', [])
        identities = json.loads(prepared['identity_snapshot']) if prepared else {}
        if not checked:
            try:
                checks = verify_execution(root, prepared, settings,
                    current_manifest=json.loads(prepared['manifest_snapshot']) if run_mode != 'target' else None) if prepared else [
                    {'test_case': 'target.execution.freeze', 'status': 'NOT_RUN',
                     'reason_code': 'TARGET_EXECUTION_NOT_PREPARED', 'gate': 'REQUIRED'}]
            except Exception as ex:
                checks = [{'test_case': 'target.execution.verify', 'status': 'HARNESS_ERROR',
                           'reason_code': 'TARGET_EXECUTION_VERIFICATION_FAILED',
                           'detail': repr(ex), 'gate': 'REQUIRED'}]
            prior = data.get('target_identity')
            if prior is not None:
                prior_map = {prior.get('target_id'): prior} if 'fingerprint' in prior else prior
                for key, recorded in identities.items():
                    for reason in check_result_binding(TargetIdentity.from_dict(recorded), prior_map.get(key)):
                        checks.append({'test_case': 'target.' + key + '.result_binding',
                                       'status': 'HARNESS_ERROR', 'reason_code': reason,
                                       'gate': 'REQUIRED'})
            for key, identity in identities.items():
                if not identity.get('certifies_real_target') or run_mode != 'target':
                    checks.append({'test_case': 'target.' + key + '.real_target',
                                   'status': 'NOT_RUN', 'reason_code': TARGET_NOT_REAL,
                                   'gate': 'REQUIRED' if run_mode == 'target' else 'OPTIONAL'})
            if run_mode == 'target' and 'executed_target_ids' in data:
                executed = set(data['executed_target_ids'])
                for key in sorted(set(identities) - executed):
                    checks.append({'test_case': 'target.' + key + '.execution',
                                   'status': 'NOT_RUN', 'reason_code': 'TARGET_NOT_EXECUTED',
                                   'gate': 'REQUIRED'})
            write_json(e.root / 'execution_verification.json', {'checks': checks,
                       'target_identity': identities, 'run_mode': run_mode})
            for row in checks:
                row['evidence'] = ['execution_verification.json']
            rows.extend(checks)
            checked = True
        context = CoordinatorContext(root=root, results=rows, settings=settings)
        summary = coordinator.evaluate(context)
        production = summary.domains[0]
        production.target = identities
        production.certifies_real_target = bool(identities) and run_mode == 'target' and all(
            i.get('certifies_real_target') for i in identities.values()) and production.status == 'PASS'
        data['headquarters'] = summary.to_dict()
        data['capability_contract'] = prepared['contract'].to_dict() if prepared else None
        data['target_identity'] = identities
        if not production.certifies_real_target:
            data['target_qa_certified'] = False
        if not summary.accepted:
            data['completion_certified'] = False
    return attach
