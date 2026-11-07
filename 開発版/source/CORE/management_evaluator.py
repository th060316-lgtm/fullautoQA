"""Management HQ evaluator.

Turns whatever operational evidence was actually collected into an
independent ``DomainReport('management', ...)`` plus a serializable readback.

What "management" means here
----------------------------
The Management headquarters judges the *operational* qualities of a run:
resource usage (CPU, RAM, handles, runtime, disk, evidence size), long-run
growth and performance-regression signals, reproducibility / fresh-run /
target-generation integrity, the operational burden (one-click, manual
intervention, no-admin, offline) and the integrity / residual-risk record.

Rules that this module enforces
-------------------------------
* An absent measurement is **not** zero.  It stays absent and is reported as
  unavailable.
* An absent required evidence item is ``NOT_RUN`` / non-PASS - never ``PASS``.
* Fixture / self-test / synthetic evidence can never be presented as
  real-game acceptance.
* No numeric threshold is invented.  When no threshold is configured the
  observed value is preserved verbatim and the quality verdict stays
  ``INCONCLUSIVE``.  Measurement coverage is judged separately, so absence of
  an invented limit does not become an extra completion requirement.
* Every value keeps its provenance.
"""
from __future__ import annotations

from pathlib import Path
import math

from common import stamp
from hq_evidence import (ReadbackDomainReport, collect_evidence, compare_threshold, fingerprint,
                         get_any, has_any, jsonable, lookup, read_measurement,
                         resolve_thresholds, safe_join, stable_fingerprint, truthiness,
                         units_compatible)

DOMAIN = 'management'
READBACK_SCHEMA_VERSION = 1

MANAGEMENT_EVALUATION_NOT_PERFORMED = 'MANAGEMENT_EVALUATION_NOT_PERFORMED'
MANAGEMENT_MEASUREMENT_UNAVAILABLE = 'MANAGEMENT_MEASUREMENT_UNAVAILABLE'
MANAGEMENT_THRESHOLD_NOT_CONFIGURED = 'MANAGEMENT_THRESHOLD_NOT_CONFIGURED'
MANAGEMENT_THRESHOLD_NOT_COMPARABLE = 'MANAGEMENT_THRESHOLD_NOT_COMPARABLE'
MANAGEMENT_THRESHOLD_UNIT_MISMATCH = 'MANAGEMENT_THRESHOLD_UNIT_MISMATCH'
MANAGEMENT_THRESHOLD_VIOLATION = 'MANAGEMENT_THRESHOLD_VIOLATION'
MANAGEMENT_SIGNAL_ABSENT = 'MANAGEMENT_SIGNAL_ABSENT'
MANAGEMENT_SIGNAL_UNDETERMINED = 'MANAGEMENT_SIGNAL_UNDETERMINED'
MANAGEMENT_SIGNAL_FALSE = 'MANAGEMENT_SIGNAL_FALSE'
MANAGEMENT_EVIDENCE_KIND_UNKNOWN = 'MANAGEMENT_EVIDENCE_KIND_UNKNOWN'
MANAGEMENT_EVIDENCE_FIXTURE_NOT_REAL_GAME = 'MANAGEMENT_EVIDENCE_FIXTURE_NOT_REAL_GAME'
MANAGEMENT_MANUAL_INTERVENTION_REQUIRED = 'MANAGEMENT_MANUAL_INTERVENTION_REQUIRED'
MANAGEMENT_PERFORMANCE_REGRESSION_DETECTED = 'MANAGEMENT_PERFORMANCE_REGRESSION_DETECTED'
MANAGEMENT_GROWTH_DETECTED = 'MANAGEMENT_GROWTH_DETECTED'
MANAGEMENT_RESIDUAL_RISK_BLOCKING = 'MANAGEMENT_RESIDUAL_RISK_BLOCKING'
MANAGEMENT_IDENTITY_MISMATCH = 'MANAGEMENT_IDENTITY_MISMATCH'
MANAGEMENT_IDENTITY_UNAVAILABLE = 'MANAGEMENT_IDENTITY_UNAVAILABLE'
MANAGEMENT_TARGET_GENERATION_EVIDENCE_ABSENT = 'MANAGEMENT_TARGET_GENERATION_EVIDENCE_ABSENT'

MANAGEMENT_EVIDENCE_FILES = (
    'management_evidence.json',
    'management/evidence.json',
    'evidence/management.json',
    'evidence/management_evidence.json',
    'hq/management.json',
    'hq/management_evidence.json',
)

_REAL_GAME_KINDS = frozenset({'real_game', 'realgame', 'real_target', 'realtarget',
                              'real_run', 'realrun', 'target'})
_FIXTURE_KINDS = frozenset({'fixture', 'fixtures', 'selftest', 'self_test', 'unittest',
                            'unit_test', 'unit', 'synthetic', 'mock', 'simulated',
                            'simulation', 'stub', 'placeholder', 'dry_run', 'dryrun'})
_KIND_ALIASES = ('evidence_kind', 'kind', 'mode', 'run_mode', 'execution_kind')

# Numeric measurements.  ``unit`` is only the *default* unit used when the
# evidence does not declare one; a threshold that declares a different unit
# makes the comparison inapplicable instead of silently wrong.
MEASUREMENT_GATES = (
    {'gate': 'management.cpu', 'metric': 'cpu_percent', 'required': False, 'unit': 'percent',
     'aliases': ('cpu_percent', 'cpu_usage_percent', 'cpu_usage', 'cpu_load_percent', 'cpu')},
    {'gate': 'management.ram', 'metric': 'ram_mb', 'required': False, 'unit': 'mb',
     'aliases': ('ram_mb', 'ram_megabytes', 'memory_mb', 'ram_usage_mb',
                 'memory_usage_mb', 'resident_memory_mb')},
    {'gate': 'management.handles', 'metric': 'handles', 'required': False, 'unit': 'count',
     'aliases': ('handles', 'handle_count', 'open_handles', 'num_handles')},
    {'gate': 'management.runtime', 'metric': 'runtime_seconds', 'required': False, 'unit': 'seconds',
     'aliases': ('runtime_seconds', 'runtime_s', 'run_time_seconds', 'duration_seconds',
                 'elapsed_seconds')},
    {'gate': 'management.disk', 'metric': 'disk_bytes', 'required': False, 'unit': 'bytes',
     'aliases': ('disk_bytes', 'disk_usage_bytes', 'disk_space_bytes', 'disk_mb',
                 'disk_usage_mb')},
    {'gate': 'management.evidence_size', 'metric': 'evidence_bytes', 'required': False, 'unit': 'bytes',
     'aliases': ('evidence_bytes', 'evidence_size_bytes', 'evidence_bundle_bytes',
                 'artifact_bytes', 'evidence_bytes_total')},
    {'gate': 'management.long_run_growth', 'metric': 'growth_bytes_per_hour', 'required': False,
     'unit': 'bytes_per_hour',
     'aliases': ('growth_bytes_per_hour', 'growth_rate_bytes_per_hour',
                 'memory_growth_bytes_per_hour', 'growth_bytes')},
)

REQUIRED_MEASUREMENT_METRICS = frozenset({
    'cpu_percent', 'ram_mb', 'handles', 'runtime_seconds', 'disk_bytes', 'evidence_bytes',
})

# Evidence signals.  ``expect`` documents what a PASS means:
#   'true'   -> the signal must be present and true
#   'false'  -> the signal must be present and false (absence of the burden)
#   'present'-> the subject must have been documented at all
SIGNAL_GATES = (
    {'gate': 'management.performance_regression', 'metric': 'performance_regression',
     'required': False, 'enforce_when_present': True, 'expect': 'false',
     'aliases': ('performance_regression', 'regression_detected', 'performance_regressed'),
     'meaning': 'PASS means no performance regression was detected',
     'fail_reason': MANAGEMENT_PERFORMANCE_REGRESSION_DETECTED},
    {'gate': 'management.reproducibility', 'metric': 'reproducibility', 'required': True,
     'expect': 'true', 'aliases': ('reproducibility', 'reproducible', 'repeat_run_identical'),
     'meaning': 'PASS means the run was reproduced identically',
     'fail_reason': 'MANAGEMENT_REPRODUCIBILITY_NOT_ESTABLISHED'},
    {'gate': 'management.fresh_run', 'metric': 'fresh_run', 'required': True, 'expect': 'true',
     'meaning': 'PASS means a fresh run was evidenced',
     'aliases': ('fresh_run', 'fresh_run_evidence', 'ran_fresh', 'fresh_execution'),
     'fail_reason': 'MANAGEMENT_FRESH_RUN_NOT_EVIDENCED'},
    {'gate': 'management.target_generation_integrity', 'metric': 'target_generation_integrity',
     'required': True, 'expect': 'true',
     'meaning': 'PASS means the recorded target identity matches the frozen identity',
     'aliases': ('target_generation_integrity', 'target_identity_integrity', 'generation_integrity'),
     'fail_reason': 'MANAGEMENT_TARGET_GENERATION_INTEGRITY_FAILED'},
    {'gate': 'management.one_click', 'metric': 'one_click', 'required': True, 'expect': 'true',
     'meaning': 'PASS means the run is operable with one click',
     'aliases': ('one_click', 'one_click_run', 'single_click_run', 'one_click_operational'),
     'fail_reason': 'MANAGEMENT_ONE_CLICK_NOT_ESTABLISHED'},
    {'gate': 'management.manual_intervention', 'metric': 'manual_intervention', 'required': True,
     'expect': 'false',
     'meaning': 'PASS means no manual intervention was required',
     'aliases': ('manual_intervention', 'manual_intervention_required', 'manual_steps_required'),
     'fail_reason': MANAGEMENT_MANUAL_INTERVENTION_REQUIRED},
    {'gate': 'management.no_admin', 'metric': 'no_admin', 'required': True, 'expect': 'true',
     'meaning': 'PASS means the run needs no administrator rights',
     'aliases': ('no_admin', 'no_admin_required', 'admin_free', 'no_elevated_privileges'),
     'fail_reason': 'MANAGEMENT_ADMIN_RIGHTS_REQUIRED'},
    {'gate': 'management.offline', 'metric': 'offline', 'required': True, 'expect': 'true',
     'meaning': 'PASS means the run is fully offline',
     'aliases': ('offline', 'fully_offline', 'offline_compliant', 'no_network', 'network_free'),
     'fail_reason': 'MANAGEMENT_OFFLINE_COMPLIANCE_NOT_ESTABLISHED'},
    {'gate': 'management.integrity', 'metric': 'integrity', 'required': True, 'expect': 'true',
     'meaning': 'PASS means the evidence integrity was verified',
     'aliases': ('integrity', 'integrity_verified', 'evidence_integrity', 'integrity_ok'),
     'fail_reason': 'MANAGEMENT_INTEGRITY_NOT_VERIFIED'},
    {'gate': 'management.residual_risk', 'metric': 'residual_risk', 'required': True,
     'expect': 'present',
     'meaning': 'PASS means the residual risk was documented',
     'aliases': ('residual_risk', 'residual_risks', 'known_risks', 'residual_risk_record'),
     'fail_reason': MANAGEMENT_RESIDUAL_RISK_BLOCKING},
)

#: Ordering used to pick the single reason code of a non-PASS domain.
_STATUS_PRECEDENCE = ('HARNESS_ERROR', 'FAIL', 'NOT_RUN', 'INCONCLUSIVE')


def _aggregate(rows):
    """Domain status over the REQUIRED rows.

    The ordering is deliberate: a hard failure outranks an absent measurement,
    and an absent measurement outranks a measurement that could not be judged
    because no threshold was configured.  All three are non-PASS.
    """
    required = [row for row in rows if row.get('gate') == 'REQUIRED']
    if not required:
        return 'NOT_RUN'
    for status in _STATUS_PRECEDENCE:
        if any(row.get('status') == status for row in required):
            return status
    return 'PASS'


def _row(gate, status, reason_code=None, evidence=None, detail=None, required=True, **extra):
    row = {'test_case': gate, 'status': status,
           'reason_code': reason_code,
           'gate': 'REQUIRED' if required else 'ADVISORY',
           'severity': 'ERROR' if required else 'WARNING',
           'evidence': [str(item) for item in (evidence or [])],
           'detail': detail}
    row.update(extra)
    return row


def _gate_rows(rows):
    """Gate rows in the shape used by ``headquarters.DomainReport``.

    Like ``DomainReport.from_results`` this only lists the gates that are not
    PASS - the full list is available through :func:`_all_gate_rows`.
    """
    return [{'name': row['test_case'], 'status': row['status'],
             'required': row.get('gate') == 'REQUIRED',
             'reason_code': row.get('reason_code'),
             'evidence': list(row.get('evidence') or []),
             'severity': row.get('severity')} for row in rows if row.get('status') != 'PASS']


def _all_gate_rows(rows):
    """Every gate, PASS ones included - the full auditable picture."""
    return [{'name': row['test_case'], 'status': row['status'],
             'required': row.get('gate') == 'REQUIRED',
             'reason_code': row.get('reason_code'),
             'evidence': list(row.get('evidence') or []),
             'severity': row.get('severity'),
             'detail': row.get('detail')} for row in rows]


def _counts(rows):
    counts = {'total': len(rows)}
    for row in rows:
        counts[row['status']] = counts.get(row['status'], 0) + 1
    return counts


def _domain_reason(rows):
    for status in _STATUS_PRECEDENCE:
        for row in rows:
            if row.get('gate') == 'REQUIRED' and row.get('status') == status:
                return row.get('reason_code')
    return None


# --------------------------------------------------------------------------- #
# evidence kind
# --------------------------------------------------------------------------- #
def _evidence_kind(bundle, settings):
    """Classify the evidence: real-game, fixture/self-test or unknown."""
    value = get_any(bundle, _KIND_ALIASES)
    source = 'evidence_bundle'
    if value is None:
        value = get_any(settings, ['run_mode', 'evidence_kind'])
        source = 'settings'
    if value is None:
        return None, source
    kind = str(value).strip().lower().replace('-', '_')
    if kind in _REAL_GAME_KINDS:
        return 'real_game', source
    if kind in _FIXTURE_KINDS:
        return 'fixture', source
    return 'unknown', source


# --------------------------------------------------------------------------- #
# frozen identity cross-check
# --------------------------------------------------------------------------- #
def _frozen_identity(context):
    """The frozen target identity, if the run recorded one."""
    identity = getattr(context, 'identity', None)
    if identity is not None:
        data = identity.to_dict() if hasattr(identity, 'to_dict') else identity
        if isinstance(data, dict) and data:
            return data, 'context.identity'
    extras = getattr(context, 'extras', None) or {}
    if isinstance(extras, dict):
        present, value = lookup(extras, ['target_identity', 'identities'])
        if present and isinstance(value, dict) and value:
            return value, 'context.extras.target_identity'
    root = Path(getattr(context, 'evidence_root', None) or getattr(context, 'root', None) or '.')
    path = safe_join(root, 'execution_frozen.json')
    if path is not None and path.is_file():
        from hq_evidence import read_json_safe
        data = read_json_safe(path)
        if isinstance(data, dict):
            present, value = lookup(data, ['target_identity'])
            if present and isinstance(value, dict) and value:
                return value, 'execution_frozen.json'
    return None, None


def _identity_facts(identity):
    """Extract ``{'target','generation','fingerprint'}`` facts from an identity."""
    facts = []
    if not isinstance(identity, dict):
        return facts
    for key, value in sorted(identity.items()):
        mapping = value if isinstance(value, dict) else {key: value}
        generation = get_any(mapping, ['generation', 'target_generation', 'generation_counter'])
        fingerprint_value = get_any(mapping, ['fingerprint', 'target_fingerprint', 'identity_sha256'])
        facts.append({'target': str(key), 'generation': generation, 'fingerprint': fingerprint_value})
    return facts


# --------------------------------------------------------------------------- #
# gate evaluation
# --------------------------------------------------------------------------- #
def _required_sets(settings):
    """Required / advisory gate names, honouring an explicit configuration."""
    domain_settings = settings.get('management') if isinstance(settings.get('management'), dict) else {}
    required = {spec['gate'] for spec in MEASUREMENT_GATES if spec['required']}
    required |= {spec['gate'] for spec in SIGNAL_GATES if spec['required']}
    required.add('management.evidence_kind')
    required.add('management.measurement_coverage')
    advisory = {spec['gate'] for spec in MEASUREMENT_GATES if not spec['required']}
    advisory |= {spec['gate'] for spec in SIGNAL_GATES if not spec['required']}
    if isinstance(domain_settings, dict):
        forced = domain_settings.get('required_gates')
        if isinstance(forced, (list, tuple, set)):
            required |= {str(item) for item in forced}
            advisory -= {str(item) for item in forced}
        relaxed = domain_settings.get('advisory_gates')
        if isinstance(relaxed, (list, tuple, set)):
            advisory |= {str(item) for item in relaxed}
            required -= {str(item) for item in relaxed}
    return required, advisory


def _evaluate_measurement(spec, bundle, threshold, threshold_source):
    """Evaluate one numeric measurement gate."""
    measurement = read_measurement(bundle, spec['aliases'], spec['unit'])
    metric = spec['metric']
    if measurement is None:
        return (_row(spec['gate'], 'NOT_RUN', MANAGEMENT_MEASUREMENT_UNAVAILABLE,
                     detail='no %s measurement was recorded' % metric),
                {'metric': metric, 'available': False, 'value': None, 'unit': spec['unit'],
                 'status': 'NOT_RUN', 'reason_code': MANAGEMENT_MEASUREMENT_UNAVAILABLE,
                 'threshold': None, 'threshold_source': None, 'source': None,
                 'method': None, 'evidence': []}, None)
    value = measurement['value']
    unit = measurement['unit']
    try:
        valid = not isinstance(value, bool) and math.isfinite(float(value))
    except (ValueError, TypeError, OverflowError):
        valid = False
    if not valid:
        return (_row(spec['gate'], 'NOT_RUN', MANAGEMENT_MEASUREMENT_UNAVAILABLE,
                     evidence=measurement['evidence'], detail='recorded measurement is not finite numeric data'),
                {'metric': metric, 'available': False, 'recorded': True, 'value': value,
                 'unit': unit, 'status': 'NOT_RUN', 'reason_code': MANAGEMENT_MEASUREMENT_UNAVAILABLE,
                 'threshold': jsonable(threshold), 'threshold_source': threshold_source,
                 'source': measurement['source'], 'method': measurement['method'],
                 'evidence': measurement['evidence']}, None)
    record = {'metric': metric, 'available': True, 'value': value, 'unit': unit,
              'statistic': measurement['statistic'], 'status': 'PASS',
              'reason_code': None, 'threshold': None, 'threshold_source': None,
              'source': measurement['source'], 'method': measurement['method'],
              'evidence': measurement['evidence']}
    if threshold is None:
        record['status'] = 'INCONCLUSIVE'
        record['reason_code'] = MANAGEMENT_THRESHOLD_NOT_CONFIGURED
        return (_row(spec['gate'], 'INCONCLUSIVE', MANAGEMENT_THRESHOLD_NOT_CONFIGURED,
                     evidence=measurement['evidence'],
                     detail='measured %r (%s); no threshold is configured, so no PASS/FAIL '
                            'verdict can be produced' % (value, unit)),
                record, None)
    record['threshold'] = jsonable(threshold)
    record['threshold_source'] = threshold_source
    compatible, declared_unit = units_compatible(unit, threshold)
    if not compatible:
        record['status'] = 'INCONCLUSIVE'
        record['reason_code'] = MANAGEMENT_THRESHOLD_UNIT_MISMATCH
        return (_row(spec['gate'], 'INCONCLUSIVE', MANAGEMENT_THRESHOLD_UNIT_MISMATCH,
                     evidence=measurement['evidence'],
                     detail='threshold is declared in %r but the measurement is in %r'
                            % (declared_unit, unit)),
                record, None)
    ok, detail = compare_threshold(value, threshold)
    if ok is None:
        record['status'] = 'INCONCLUSIVE'
        record['reason_code'] = MANAGEMENT_THRESHOLD_NOT_COMPARABLE
        return (_row(spec['gate'], 'INCONCLUSIVE', MANAGEMENT_THRESHOLD_NOT_COMPARABLE,
                     evidence=measurement['evidence'], detail=detail),
                record, None)
    if ok:
        record['status'] = 'PASS'
        return (_row(spec['gate'], 'PASS', None, evidence=measurement['evidence'],
                     detail=detail),
                record, None)
    record['status'] = 'FAIL'
    record['reason_code'] = MANAGEMENT_THRESHOLD_VIOLATION
    return (_row(spec['gate'], 'FAIL', MANAGEMENT_THRESHOLD_VIOLATION,
                 evidence=measurement['evidence'], detail=detail),
            record, MANAGEMENT_THRESHOLD_VIOLATION)


def _evaluate_signal(spec, bundle):
    """Evaluate one evidence signal gate."""
    raw = get_any(bundle, spec['aliases'])
    present = has_any(bundle, spec['aliases'])
    metric = spec['metric']
    record = {'metric': metric, 'available': bool(present), 'value': jsonable(raw),
              'status': 'NOT_RUN', 'reason_code': MANAGEMENT_SIGNAL_ABSENT,
              'evidence': [], 'expect': spec['expect'],
              'meaning': spec.get('meaning', '')}
    if not present:
        return (_row(spec['gate'], 'NOT_RUN', MANAGEMENT_SIGNAL_ABSENT,
                     detail='the %s signal was not recorded' % metric),
                record, None)
    evidence = raw.get('evidence') if isinstance(raw, dict) else None
    if isinstance(evidence, str):
        evidence = [evidence]
    elif not isinstance(evidence, (list, tuple)):
        evidence = []
    record['evidence'] = [str(item) for item in evidence]
    if isinstance(raw, dict):
        for key in ('scope', 'source', 'test_cases'):
            if key in raw:
                record[key] = jsonable(raw[key])
    expect = spec['expect']
    if expect == 'present':
        risk = None
        if isinstance(raw, (list, tuple)):
            risk = _blocking_residual_risk(raw)
        elif isinstance(raw, dict):
            risk = _blocking_residual_risk(get_any(raw, ['risks', 'entries', 'items'], []) or [])
        if risk:
            record['status'] = 'FAIL'
            record['reason_code'] = MANAGEMENT_RESIDUAL_RISK_BLOCKING
            return (_row(spec['gate'], 'FAIL', MANAGEMENT_RESIDUAL_RISK_BLOCKING,
                         evidence=record['evidence'],
                         detail='a blocking residual risk was recorded: %s' % risk),
                    record, MANAGEMENT_RESIDUAL_RISK_BLOCKING)
        record['status'] = 'PASS'
        return (_row(spec['gate'], 'PASS', None, evidence=record['evidence'],
                     detail='the %s subject was documented' % metric),
                record, None)
    value = truthiness(raw)
    if value is None:
        record['reason_code'] = MANAGEMENT_SIGNAL_UNDETERMINED
        return (_row(spec['gate'], 'NOT_RUN', MANAGEMENT_SIGNAL_UNDETERMINED,
                     evidence=record['evidence'],
                     detail='the %s signal was recorded but carries no usable verdict' % metric),
                record, None)
    expected = (expect == 'true')
    if metric == 'reproducibility' and value is True:
        scope = record.get('scope')
        if scope == 'same_run_seed_replay':
            record['status'] = 'INCONCLUSIVE'
            record['reason_code'] = 'MANAGEMENT_REPRODUCIBILITY_SCOPE_LIMITED'
            return (_row(spec['gate'], 'INCONCLUSIVE', record['reason_code'],
                         evidence=record['evidence'],
                         detail='same-run seed replay is established; independent-run reproducibility was not established'),
                    record, None)
        if scope != 'cross_run_same_target':
            record['status'] = 'INCONCLUSIVE'
            record['reason_code'] = 'MANAGEMENT_REPRODUCIBILITY_SCOPE_UNSUPPORTED'
            return (_row(spec['gate'], 'INCONCLUSIVE', record['reason_code'],
                         evidence=record['evidence'],
                         detail='reproducibility evidence is true, but its scope is not the accepted independent-run scope'),
                    record, None)
    if value == expected:
        record['status'] = 'PASS'
        return (_row(spec['gate'], 'PASS', None, evidence=record['evidence'],
                     detail='the %s signal is %s%s' % (metric, 'true' if value else 'false',
                         ' (scope: %s)' % record['scope'] if record.get('scope') else '')),
                record, None)
    record['status'] = 'FAIL'
    record['reason_code'] = spec.get('fail_reason') or MANAGEMENT_SIGNAL_FALSE
    return (_row(spec['gate'], 'FAIL', record['reason_code'], evidence=record['evidence'],
                 detail='the %s signal is %s but %s was required'
                        % (metric, 'true' if value else 'false',
                           'true' if expected else 'false')),
            record, record['reason_code'])


def _blocking_residual_risk(items):
    """Return the first blocking residual risk, or ``None``."""
    if not isinstance(items, (list, tuple)):
        return None
    for item in items:
        if isinstance(item, str):
            return item
        if isinstance(item, dict):
            severity = str(get_any(item, ['severity', 'level', 'impact'], '') or '').strip().lower()
            blocking = truthiness(get_any(item, ['blocking', 'blocks_release']))
            if blocking is True or severity in ('critical', 'blocker', 'blocking', 'fatal'):
                return jsonable(item)
    return None


def _evaluate_evidence_kind(kind, kind_source):
    """The real-game acceptance gate: fixture evidence never satisfies it."""
    if kind == 'real_game':
        return (_row('management.evidence_kind', 'PASS', None,
                     detail='evidence kind is real game (source: %s)' % kind_source),
                {'kind': kind, 'source': kind_source, 'real_game_acceptance': True})
    if kind == 'fixture':
        return (_row('management.evidence_kind', 'NOT_RUN',
                     MANAGEMENT_EVIDENCE_FIXTURE_NOT_REAL_GAME,
                     detail='evidence kind is fixture/self-test; fixture results are not '
                            'real-game acceptance'),
                {'kind': kind, 'source': kind_source, 'real_game_acceptance': False})
    return (_row('management.evidence_kind', 'NOT_RUN', MANAGEMENT_EVIDENCE_KIND_UNKNOWN,
                 detail='the evidence kind is unknown, so real-game acceptance cannot be claimed'),
            {'kind': kind or 'unknown', 'source': kind_source, 'real_game_acceptance': False})


def _evaluate_target_generation(bundle, context):
    """Cross-check the recorded target identity against the frozen identity."""
    recorded_generation = get_any(bundle, ['target_generation', 'generation', 'target_generation_counter'])
    recorded_fingerprint = get_any(bundle, ['target_fingerprint', 'fingerprint', 'target_identity_fingerprint'])
    if recorded_generation is None and recorded_fingerprint is None:
        return (_row('management.target_generation_integrity', 'NOT_RUN',
                     MANAGEMENT_TARGET_GENERATION_EVIDENCE_ABSENT,
                     detail='the evidence records no target generation or fingerprint'),
                {'recorded_generation': jsonable(recorded_generation),
                 'recorded_fingerprint': jsonable(recorded_fingerprint),
                 'identity_source': None, 'identity_facts': [], 'verdict': 'unavailable'})
    identity, identity_source = _frozen_identity(context)
    facts = _identity_facts(identity) if identity else []
    if not facts:
        return (_row('management.target_generation_integrity', 'NOT_RUN',
                     MANAGEMENT_IDENTITY_UNAVAILABLE,
                     detail='no frozen target identity is available to compare against'),
                {'recorded_generation': jsonable(recorded_generation),
                 'recorded_fingerprint': jsonable(recorded_fingerprint),
                 'identity_source': identity_source, 'identity_facts': [], 'verdict': 'unavailable'})
    for fact in facts:
        if recorded_generation is not None and fact.get('generation') is not None:
            if str(fact['generation']) == str(recorded_generation):
                return (_row('management.target_generation_integrity', 'PASS', None,
                             detail='target generation %s matches the frozen identity'
                                    % recorded_generation),
                        {'recorded_generation': jsonable(recorded_generation),
                         'recorded_fingerprint': jsonable(recorded_fingerprint),
                         'identity_source': identity_source, 'identity_facts': facts,
                         'verdict': 'generation_matches'})
            return (_row('management.target_generation_integrity', 'FAIL',
                         MANAGEMENT_IDENTITY_MISMATCH,
                         detail='recorded generation %s does not match the frozen generation %s'
                                % (recorded_generation, fact.get('generation'))),
                    {'recorded_generation': jsonable(recorded_generation),
                     'recorded_fingerprint': jsonable(recorded_fingerprint),
                     'identity_source': identity_source, 'identity_facts': facts,
                     'verdict': 'generation_mismatch'})
        if recorded_fingerprint is not None and fact.get('fingerprint') is not None:
            if str(fact['fingerprint']) == str(recorded_fingerprint):
                return (_row('management.target_generation_integrity', 'PASS', None,
                             detail='target fingerprint matches the frozen identity'),
                        {'recorded_generation': jsonable(recorded_generation),
                         'recorded_fingerprint': jsonable(recorded_fingerprint),
                         'identity_source': identity_source, 'identity_facts': facts,
                         'verdict': 'fingerprint_matches'})
            return (_row('management.target_generation_integrity', 'FAIL',
                         MANAGEMENT_IDENTITY_MISMATCH,
                         detail='recorded fingerprint does not match the frozen fingerprint'),
                    {'recorded_generation': jsonable(recorded_generation),
                     'recorded_fingerprint': jsonable(recorded_fingerprint),
                     'identity_source': identity_source, 'identity_facts': facts,
                     'verdict': 'fingerprint_mismatch'})
    return (_row('management.target_generation_integrity', 'NOT_RUN',
                 MANAGEMENT_IDENTITY_UNAVAILABLE,
                 detail='the frozen identity carries no comparable generation or fingerprint'),
            {'recorded_generation': jsonable(recorded_generation),
             'recorded_fingerprint': jsonable(recorded_fingerprint),
             'identity_source': identity_source, 'identity_facts': facts, 'verdict': 'unavailable'})


# --------------------------------------------------------------------------- #
# public API
# --------------------------------------------------------------------------- #
def evaluate_management(context):
    """Evaluate the Management headquarters domain.

    Returns a ``ReadbackDomainReport`` named ``management``.  The function
    never raises for missing or malformed evidence: an absent evidence item
    degrades to ``NOT_RUN`` for its own gate and the domain stays non-PASS.
    """
    settings = getattr(context, 'settings', None) or {}
    bundle, sources = collect_evidence(context, DOMAIN, MANAGEMENT_EVIDENCE_FILES)
    table, threshold_sources, ignored = resolve_thresholds(settings, DOMAIN, bundle)
    required, advisory = _required_sets(settings)

    rows = []
    measurements = {}
    signals = {}
    risks = []
    notes = []

    kind, kind_source = _evidence_kind(bundle, settings)
    kind_row, kind_record = _evaluate_evidence_kind(kind, kind_source)
    rows.append(kind_row)
    if kind_record['kind'] == 'fixture':
        risks.append({'code': MANAGEMENT_EVIDENCE_FIXTURE_NOT_REAL_GAME,
                      'severity': 'ERROR',
                      'detail': 'the collected evidence is fixture/self-test evidence; it can '
                                'never be presented as real-game acceptance'})
    elif kind_record['kind'] != 'real_game':
        risks.append({'code': MANAGEMENT_EVIDENCE_KIND_UNKNOWN, 'severity': 'ERROR',
                      'detail': 'the evidence kind is unknown, so real-game acceptance cannot '
                                'be claimed'})

    for spec in MEASUREMENT_GATES:
        threshold = table.get(spec['metric'])
        source = threshold_sources.get(spec['metric'])
        is_required = spec['gate'] in required
        if spec['gate'] in advisory and threshold is not None:
            # A configured threshold means the operator intends this gate to be enforced.
            is_required = True
        row, record, risk_code = _evaluate_measurement(spec, bundle, threshold, source)
        row['gate'] = 'REQUIRED' if is_required else 'ADVISORY'
        row['severity'] = 'ERROR' if is_required else 'WARNING'
        rows.append(row)
        measurements[spec['metric']] = record
        if record.get('status') == 'INCONCLUSIVE' and record.get('reason_code') == MANAGEMENT_THRESHOLD_NOT_CONFIGURED:
            risks.append({'code': MANAGEMENT_THRESHOLD_NOT_CONFIGURED, 'severity': 'WARNING',
                          'detail': 'no threshold is configured for %s; the observed value %r is '
                                    'preserved but no threshold verdict can be produced'
                                    % (spec['metric'], record.get('value'))})
        if risk_code:
            risks.append({'code': risk_code, 'severity': 'ERROR',
                          'detail': 'the %s gate failed' % spec['gate']})

    missing_measurements = sorted(
        metric for metric in REQUIRED_MEASUREMENT_METRICS
        if not measurements.get(metric, {}).get('available')
    )
    if missing_measurements:
        coverage_row = _row(
            'management.measurement_coverage', 'NOT_RUN', MANAGEMENT_MEASUREMENT_UNAVAILABLE,
            detail='required numeric measurements unavailable: ' + ','.join(missing_measurements)
        )
    else:
        coverage_row = _row(
            'management.measurement_coverage', 'PASS', None,
            detail='all required numeric measurements were recorded'
        )
    coverage_row['gate'] = 'REQUIRED'
    coverage_row['severity'] = 'ERROR'
    rows.append(coverage_row)

    for spec in SIGNAL_GATES:
        if spec['gate'] == 'management.target_generation_integrity':
            row, record = _evaluate_target_generation(bundle, context)
            signals[spec['metric']] = {'metric': spec['metric'], 'available': True,
                                       'value': record.get('verdict'), 'status': row['status'],
                                       'reason_code': row.get('reason_code'),
                                       'evidence': [], 'expect': spec['expect'],
                                       'detail': row.get('detail')}
            rows.append(row)
            if row['status'] == 'FAIL':
                risks.append({'code': MANAGEMENT_IDENTITY_MISMATCH, 'severity': 'ERROR',
                              'detail': row.get('detail')})
            elif row['status'] == 'NOT_RUN':
                risks.append({'code': row.get('reason_code'), 'severity': 'WARNING',
                              'detail': row.get('detail')})
            continue
        row, record, risk_code = _evaluate_signal(spec, bundle)
        is_required = spec['gate'] in required
        if (not is_required and spec.get('enforce_when_present') and record.get('available')):
            is_required = True
        row['gate'] = 'REQUIRED' if is_required else 'ADVISORY'
        row['severity'] = 'ERROR' if is_required else 'WARNING'
        rows.append(row)
        signals[spec['metric']] = record
        if risk_code:
            risks.append({'code': risk_code, 'severity': 'ERROR',
                          'detail': 'the %s gate failed' % spec['gate']})
        elif row['status'] == 'NOT_RUN':
            risks.append({'code': row.get('reason_code'), 'severity': 'WARNING',
                          'detail': row.get('detail')})

    growth_detected = truthiness(get_any(bundle, ['growth_detected', 'memory_growth_detected',
                                                   'unbounded_growth']))
    if growth_detected:
        for row in rows:
            if row['test_case'] == 'management.long_run_growth':
                row['status'] = 'FAIL'
                row['reason_code'] = MANAGEMENT_GROWTH_DETECTED
                row['detail'] = 'the evidence reports unbounded resource growth'
        risks.append({'code': MANAGEMENT_GROWTH_DETECTED, 'severity': 'ERROR',
                      'detail': 'the evidence reports unbounded resource growth'})

    if not bundle:
        risks.append({'code': MANAGEMENT_EVALUATION_NOT_PERFORMED, 'severity': 'ERROR',
                      'detail': 'no management evidence was found; nothing could be evaluated'})
    if not table:
        risks.append({'code': MANAGEMENT_THRESHOLD_NOT_CONFIGURED, 'severity': 'WARNING',
                      'detail': 'no management threshold is configured; no threshold based '
                                'verdict can be produced for any measurement'})
    for metric, hint in sorted(ignored.items()):
        risks.append({'code': 'MANAGEMENT_THRESHOLD_IGNORED', 'severity': 'WARNING',
                      'detail': 'the threshold for %s was ignored: %s' % (metric, hint)})

    status = _aggregate(rows)
    reason_code = (_domain_reason(rows) if bundle else MANAGEMENT_EVALUATION_NOT_PERFORMED)

    unavailable = [{'item': row['test_case'], 'status': row['status'],
                    'required': row.get('gate') == 'REQUIRED',
                    'reason_code': row.get('reason_code'), 'detail': row.get('detail')}
                   for row in rows if row['status'] == 'NOT_RUN']
    unavailable_required = [entry for entry in unavailable if entry['required']]

    if sources:
        notes.append('MANAGEMENT_EVIDENCE_SOURCES:' + ','.join(
            str(source.get('location')) for source in sources))
    if table:
        notes.append('MANAGEMENT_THRESHOLDS_SOURCE:' + ','.join(
            sorted({str(value) for value in threshold_sources.values()})))
    else:
        notes.append('MANAGEMENT_THRESHOLDS_SOURCE:none')
    if not bundle:
        notes.append(MANAGEMENT_EVALUATION_NOT_PERFORMED)

    readback = {
        'schema_version': READBACK_SCHEMA_VERSION,
        'domain': DOMAIN,
        'status': status,
        'reason_code': reason_code,
        'accepted': status == 'PASS',
        'evidence_present': bool(bundle),
        # Execution describes the evaluator call only; it does not certify evidence or quality.
        'evaluator_execution': 'COMPLETED',
        'measurement_availability': {
            'status': coverage_row['status'],
            'scope': 'required_numeric_measurements',
            'missing': missing_measurements,
        },
        'measurement_quality': {
            'status': (_aggregate([
                row for row in rows
                if row['test_case'] in {s['gate'] for s in MEASUREMENT_GATES}
                and row.get('gate') == 'REQUIRED'
            ]) if any(
                row['test_case'] in {s['gate'] for s in MEASUREMENT_GATES}
                and row.get('gate') == 'REQUIRED' for row in rows
            ) else 'INCONCLUSIVE'),
            'scope': 'configured_thresholds_only',
        },
        'evidence_sources': sources,
        'evidence_kind': kind_record['kind'],
        'evidence_kind_source': kind_source,
        'real_game_acceptance': bool(kind_record['real_game_acceptance']),
        'measurements': measurements,
        'signals': signals,
        'thresholds': {metric: {'configured': metric in table,
                                'threshold': jsonable(table.get(metric)),
                                'source': threshold_sources.get(metric)}
                       for metric in sorted(set(list(table.keys()) +
                                                [spec['metric'] for spec in MEASUREMENT_GATES]))},
        'unavailable': unavailable,
        'unavailable_required': unavailable_required,
        'gates': _gate_rows(rows),
        'gate_status': _all_gate_rows(rows),
        'risks': risks,
        'notes': notes,
        'generated_at': str(stamp()),
    }
    readback['fingerprint'] = stable_fingerprint(readback)

    return ReadbackDomainReport(DOMAIN, status, reason_code, _gate_rows(rows), _counts(rows),
                                 False, None, notes, readback=readback)


def management_readback(report):
    """Readback of a management report (helper for the coordinator)."""
    return getattr(report, 'readback', None)


__all__ = ['DOMAIN', 'MANAGEMENT_EVALUATION_NOT_PERFORMED', 'evaluate_management',
           'management_readback', 'fingerprint']
