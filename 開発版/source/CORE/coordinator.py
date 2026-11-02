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

from pathlib import Path

from capability_contract import CapabilityContract, declared_capabilities
from common import inside, read_json, write_json
from headquarters import DOMAIN_ORDER, DomainReport, HeadquartersSummary
from target_identity import TargetIdentity, bind_target

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
    entries = manifest.get('targets') or []
    contract = CapabilityContract.freeze(root, entries, settings=settings)
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
    return {'contract': contract, 'identities': identities}


def attach_summary_to_result_file(path, root=None, settings=None):
    path = Path(path)
    if not path.is_file():
        return None
    data = read_json(path)
    coordinator = Coordinator(root if root is not None else path.parent, settings)
    context = CoordinatorContext(root=coordinator.root, results=data.get('results') or [],
                                 settings=settings)
    summary = coordinator.evaluate(context)
    data = coordinator.attach(data, summary, context)
    write_json(path, data)
    return summary
