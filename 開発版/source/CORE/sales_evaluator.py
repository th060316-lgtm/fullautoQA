"""Sales HQ evaluator.

Turns cold-start / player-review evidence into an independent
``DomainReport('sales', ...)`` plus a serializable readback.

What "sales" means here
------------------------
The Sales headquarters judges what a *player* experiences: whether a cold
start really happened and can be traced, what the first 30 seconds are like,
what the first 5 minutes are like, whether the product/shelf test held up,
and whether the communication and readability of the product were reviewed.

Rules that this module enforces
-------------------------------
* No evidence -> ``NOT_RUN``.  The Sales domain never guesses.
* A **model proxy** is not a human test.  A proxy review can never set
  ``human_test_performed = True``.
* ``QA COMPLETE``, ``Product Accepted``, ``Stable`` and ``Release Approved``
  stay four distinct, separately reported facts.  In this source phase
  ``Product Accepted``, ``Stable`` and ``Release Approved`` remain HOLD.
* Fun, sellability and understandability are never asserted by this
  evaluator - a recorded opinion in the evidence is reported as an
  observation, not as a verdict of the evaluator.
* The 30 second, 5 minute, product/shelf and readability gates stay separate:
  one of them passing never implies another one.
"""
from __future__ import annotations

from common import stamp
from hq_evidence import (ReadbackDomainReport, collect_evidence, get_any, has_any, jsonable,
                         lookup, resolve_thresholds, stable_fingerprint, truthiness)

DOMAIN = 'sales'
READBACK_SCHEMA_VERSION = 1

SALES_EVALUATION_NOT_PERFORMED = 'SALES_EVALUATION_NOT_PERFORMED'
SALES_COLD_START_EVIDENCE_ABSENT = 'SALES_COLD_START_EVIDENCE_ABSENT'
SALES_COLD_START_PROVENANCE_MISSING = 'SALES_COLD_START_PROVENANCE_MISSING'
SALES_PHASE_EVIDENCE_ABSENT = 'SALES_PHASE_EVIDENCE_ABSENT'
SALES_OBSERVATION_INCOMPLETE = 'SALES_OBSERVATION_INCOMPLETE'
SALES_PHASE_FAILED = 'SALES_PHASE_FAILED'
SALES_BLOCKING_FINDINGS_RECORDED = 'SALES_BLOCKING_FINDINGS_RECORDED'
SALES_MODEL_PROXY_IS_NOT_HUMAN_TEST = 'SALES_MODEL_PROXY_IS_NOT_HUMAN_TEST'
SALES_HUMAN_TEST_EVIDENCE_ABSENT = 'SALES_HUMAN_TEST_EVIDENCE_ABSENT'
SALES_EVIDENCE_FIXTURE = 'SALES_EVIDENCE_FIXTURE'
SALES_EVIDENCE_KIND_UNKNOWN = 'SALES_EVIDENCE_KIND_UNKNOWN'
SALES_THRESHOLD_NOT_CONFIGURED = 'SALES_THRESHOLD_NOT_CONFIGURED'
SALES_THRESHOLD_VIOLATION = 'SALES_THRESHOLD_VIOLATION'
SALES_THRESHOLD_NOT_COMPARABLE = 'SALES_THRESHOLD_NOT_COMPARABLE'
SALES_PRODUCT_ACCEPTANCE_HOLD = 'SALES_PRODUCT_ACCEPTANCE_HOLD'
SALES_STABLE_HOLD = 'SALES_STABLE_HOLD'
SALES_RELEASE_APPROVAL_HOLD = 'SALES_RELEASE_APPROVAL_HOLD'
SALES_QA_REVIEW_COMPLETE = 'SALES_QA_REVIEW_COMPLETE'
SALES_QA_REVIEW_INCOMPLETE = 'SALES_QA_REVIEW_INCOMPLETE'
SALES_AUDIENCE_SUMMARY_ABSENT = 'SALES_AUDIENCE_SUMMARY_ABSENT'
SALES_AUDIENCE_DESCRIPTION_INVALID = 'SALES_AUDIENCE_DESCRIPTION_INVALID'
SALES_READABILITY_REVIEW_REQUIRED = 'SALES_READABILITY_REVIEW_REQUIRED'

SALES_EVIDENCE_FILES = (
    'sales_evidence.json',
    'sales/evidence.json',
    'evidence/sales.json',
    'evidence/sales_evidence.json',
    'hq/sales.json',
    'hq/sales_evidence.json',
)

#: The four player-facing review phases, each with its own gate.
PHASES = (
    ('first_30_seconds', ('first_30_seconds', 'first30seconds', 'first_30s',
                           'first_30_second', 'thirty_seconds', 'first_thirty_seconds',
                           '0_30_seconds', 'seconds_0_30', 'first30s')),
    ('first_5_minutes', ('first_5_minutes', 'first5minutes', 'first_5_min',
                          'first_five_minutes', '0_5_minutes', 'minutes_0_5', 'five_minutes')),
    ('product_shelf_test', ('product_shelf_test', 'productshelftest', 'shelf_test', 'shelftest',
                             'product_test', 'productshelf', 'shelf_product')),
    ('communication_readability', ('communication_readability', 'communicationreadability',
                                   'readability', 'communication', 'readability_test',
                                   'communication_test', 'clarity')),
)

# The reviewer classification is owned by the review intake so that the
# intake and this judgement can never disagree about what counts as a human.
from review_intake import FIXTURE_KINDS as _FIXTURE_KINDS
from review_intake import HUMAN_KINDS as _HUMAN_KINDS
from review_intake import PROXY_KINDS as _PROXY_KINDS
from review_intake import sanitize_sales_bundle

_KIND_ALIASES = ('evidence_kind', 'kind', 'mode', 'run_mode', 'execution_kind')
_REVIEWER_ALIASES = ('reviewer', 'reviewed_by', 'human_test', 'reviewer_kind', 'evaluator')
_PASS_WORDS = ('pass', 'passed', 'ok', 'okay', 'good', 'success', 'succeeded', 'acceptable',
               'no_blocking_findings', 'clear')
_FAIL_WORDS = ('fail', 'failed', 'failure', 'not_acceptable', 'blocked', 'blocking', 'rejected')


def _aggregate(rows):
    """Domain status over the REQUIRED rows (same precedence as management)."""
    required = [row for row in rows if row.get('gate') == 'REQUIRED']
    if not required:
        return 'NOT_RUN'
    for status in ('HARNESS_ERROR', 'FAIL', 'NOT_RUN', 'INCONCLUSIVE'):
        if any(row.get('status') == status for row in required):
            return status
    return 'PASS'


def _row(gate, status, reason_code=None, evidence=None, detail=None, required=True, **extra):
    row = {'test_case': gate, 'status': status, 'reason_code': reason_code,
           'gate': 'REQUIRED' if required else 'ADVISORY',
           'severity': 'ERROR' if required else 'WARNING',
           'evidence': [str(item) for item in (evidence or [])],
           'detail': detail}
    row.update(extra)
    return row


def _gate_rows(rows):
    """Gates that are not PASS - same shape as ``headquarters.DomainReport``."""
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
    for status in ('HARNESS_ERROR', 'FAIL', 'NOT_RUN', 'INCONCLUSIVE'):
        for row in rows:
            if row.get('gate') == 'REQUIRED' and row.get('status') == status:
                return row.get('reason_code')
    return None


# --------------------------------------------------------------------------- #
# session / phase extraction
# --------------------------------------------------------------------------- #
def _sessions(bundle):
    """All review sessions found in the bundle."""
    present, raw = lookup(bundle, ['sessions', 'reviews', 'player_reviews'])
    if present:
        if isinstance(raw, list):
            return [item for item in raw if isinstance(item, dict)]
        if isinstance(raw, dict):
            return [raw]
    for name, aliases in PHASES:
        if has_any(bundle, aliases):
            return [bundle]
    return []


def _phases_of(session):
    """The phase mapping of one session."""
    present, raw = lookup(session, ['phases', 'observations', 'review'])
    if present and isinstance(raw, dict):
        return raw
    return session


def _phase_record(session, aliases):
    """The recorded evidence of one review phase, or ``None``."""
    phases = _phases_of(session)
    present, raw = lookup(phases, aliases)
    if not present:
        return None
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, list):
        return {'findings': raw}
    if isinstance(raw, bool):
        return {'observed': raw}
    return {'observed': True, 'notes': str(raw)}


def _findings_of(record):
    """The findings list of a phase record."""
    present, raw = lookup(record, ['findings', 'issues', 'defects', 'observations',
                                    'observations_log', 'problems'])
    if present:
        if isinstance(raw, list):
            return list(raw)
        if isinstance(raw, dict):
            return [raw]
        return [raw]
    return None


def _blocking_findings(findings):
    """Split findings into blocking and non blocking ones."""
    blocking = []
    informational = []
    for item in findings or []:
        severity = None
        if isinstance(item, dict):
            severity = str(get_any(item, ['severity', 'level', 'impact'], '') or '').strip().lower()
            explicit = truthiness(get_any(item, ['blocking', 'blocks_release']))
        else:
            explicit = None
        if explicit is True or (explicit is None and severity not in
                                ('info', 'information', 'note', 'nit', 'observation', 'minor')):
            blocking.append(item)
        else:
            informational.append(item)
    return blocking, informational


def _explicit_status(record):
    """An explicit verdict recorded in a phase record, if any."""
    present, raw = lookup(record, ['status', 'result', 'verdict', 'outcome'])
    if present:
        text = str(raw).strip().lower()
        if text in _PASS_WORDS:
            return True
        if text in _FAIL_WORDS:
            return False
        interpreted = truthiness(raw)
        if interpreted is not None:
            return interpreted
    present, raw = lookup(record, ['passed', 'ok', 'acceptable', 'verified'])
    if present:
        interpreted = truthiness(raw)
        if interpreted is not None:
            return interpreted
    return None


def _evidence_list(record):
    present, raw = lookup(record, ['evidence', 'evidence_files', 'artifacts', 'recording',
                                   'video', 'transcript'])
    if not present:
        return []
    if isinstance(raw, str):
        return [raw]
    if isinstance(raw, dict):
        return [str(key) for key in sorted(raw)]
    if isinstance(raw, (list, tuple)):
        return [str(item) for item in raw]
    return []


# --------------------------------------------------------------------------- #
# gates
# --------------------------------------------------------------------------- #
def _cold_start_session(sessions):
    """The session that was started cold, if the evidence says so."""
    cold_words = ('cold_start', 'cold start', 'cold', 'fresh', 'fresh_install', 'clean_install',
                  'new_install', 'first_run', 'first run', 'pristine')
    for session in sessions:
        present, flag = lookup(session, ['cold_start', 'is_cold_start', 'coldstart'])
        if present and truthiness(flag) is True:
            return session
        provenance = get_any(session, ['provenance', 'origin', 'session_provenance'], {}) or {}
        present, flag = lookup(provenance, ['cold_start', 'is_cold_start'])
        if present and truthiness(flag) is True:
            return session
        for key in ('source', 'state', 'start_state', 'startup_state', 'installation_state',
                    'profile_state', 'kind'):
            value = get_any(provenance, [key])
            if value is None:
                value = get_any(session, [key])
            if value is None:
                continue
            text = str(value).strip().lower().replace('-', '_')
            if any(word.replace(' ', '_') == text or text.startswith(word.replace(' ', '_'))
                   for word in cold_words):
                return session
    return None


def _provenance_of(session):
    provenance = get_any(session, ['provenance', 'origin', 'session_provenance'])
    if isinstance(provenance, dict):
        return provenance
    return {}


def _evaluate_phase(gate, name, session, threshold):
    """Evaluate one player-facing review phase."""
    if session is None:
        record = {'phase': name, 'session_id': None, 'status': 'NOT_RUN',
                  'reason_code': SALES_PHASE_EVIDENCE_ABSENT, 'observations': [],
                  'findings': [], 'blocking_findings': [], 'evidence': [],
                  'available': False, 'threshold': jsonable(threshold)}
        return (_row(gate, 'NOT_RUN', SALES_PHASE_EVIDENCE_ABSENT,
                     detail='no evidence was recorded for the %s phase' % name),
                record)
    record_raw = _phase_record(session, dict(PHASES)[name])
    if record_raw is None:
        record = {'phase': name, 'session_id': _session_id(session), 'status': 'NOT_RUN',
                  'reason_code': SALES_PHASE_EVIDENCE_ABSENT, 'observations': [],
                  'findings': [], 'blocking_findings': [], 'evidence': [],
                  'available': False, 'threshold': jsonable(threshold)}
        return (_row(gate, 'NOT_RUN', SALES_PHASE_EVIDENCE_ABSENT,
                     detail='the %s phase was not recorded' % name),
                record)
    present, observed = lookup(record_raw, ['observed', 'performed', 'reviewed'])
    if present and truthiness(observed) is False:
        record = {'phase': name, 'session_id': _session_id(session), 'status': 'NOT_RUN',
                  'reason_code': SALES_PHASE_EVIDENCE_ABSENT, 'observations': [],
                  'findings': [], 'blocking_findings': [], 'evidence': _evidence_list(record_raw),
                  'available': False, 'threshold': jsonable(threshold)}
        return (_row(gate, 'NOT_RUN', SALES_PHASE_EVIDENCE_ABSENT,
                     evidence=record['evidence'],
                     detail='the %s phase is explicitly recorded as not observed' % name),
                record)
    findings = _findings_of(record_raw)
    evidence = _evidence_list(record_raw)
    notes = get_any(record_raw, ['notes', 'note', 'comment', 'summary', 'description'])
    explicit = _explicit_status(record_raw)
    blocking, informational = _blocking_findings(findings) if findings is not None else ([], [])
    threshold_violation = False
    if isinstance(threshold, dict) and 'max_findings' in threshold:
        try:
            limit = int(threshold['max_findings'])
            threshold_violation = len(blocking) > limit
        except (TypeError, ValueError):
            threshold_violation = False
    base = {'phase': name, 'session_id': _session_id(session),
            'observations': jsonable(notes) if notes is not None else [],
            'findings': jsonable(findings) if findings is not None else [],
            'blocking_findings': jsonable(blocking),
            'informational_findings': jsonable(informational),
            'evidence': evidence, 'available': True,
            'threshold': jsonable(threshold)}
    if threshold_violation:
        base['status'] = 'FAIL'
        base['reason_code'] = SALES_THRESHOLD_VIOLATION
        return (_row(gate, 'FAIL', SALES_THRESHOLD_VIOLATION, evidence=evidence,
                     detail='%d blocking findings exceed the configured maximum of %s'
                            % (len(blocking), threshold['max_findings'])),
                base)
    if explicit is False:
        base['status'] = 'FAIL'
        base['reason_code'] = SALES_PHASE_FAILED
        return (_row(gate, 'FAIL', SALES_PHASE_FAILED, evidence=evidence,
                     detail='the %s phase was recorded as failed' % name),
                base)
    if explicit is True:
        base['status'] = 'PASS'
        base['reason_code'] = None
        return (_row(gate, 'PASS', None, evidence=evidence,
                     detail='the %s phase was reviewed and recorded a positive outcome' % name),
                base)
    if findings is not None:
        if blocking:
            base['status'] = 'FAIL'
            base['reason_code'] = SALES_BLOCKING_FINDINGS_RECORDED
            return (_row(gate, 'FAIL', SALES_BLOCKING_FINDINGS_RECORDED, evidence=evidence,
                         detail='%d blocking finding(s) were recorded in the %s phase'
                                % (len(blocking), name)),
                    base)
        base['status'] = 'PASS'
        base['reason_code'] = None
        return (_row(gate, 'PASS', None, evidence=evidence,
                     detail='the %s phase was reviewed and no blocking finding was recorded'
                            % name),
                base)
    base['status'] = 'NOT_RUN'
    base['reason_code'] = SALES_OBSERVATION_INCOMPLETE
    return (_row(gate, 'NOT_RUN', SALES_OBSERVATION_INCOMPLETE, evidence=evidence,
                 detail='the %s phase was recorded but carries no outcome and no findings'
                        % name),
            base)


def _session_id(session):
    value = get_any(session, ['session_id', 'session', 'id', 'run_id'])
    return None if value is None else str(value)


def _reviewer_kind(bundle):
    """The kind of reviewer, its provenance and whether it is a real human."""
    reviewer = get_any(bundle, _REVIEWER_ALIASES)
    kind = None
    reviewer_id = None
    if isinstance(reviewer, dict):
        kind = get_any(reviewer, ['kind', 'type', 'role', 'who'])
        reviewer_id = get_any(reviewer, ['id', 'name', 'identifier'])
    elif isinstance(reviewer, str):
        kind = reviewer
    if kind is None:
        kind = get_any(bundle, ['reviewer_kind', 'human_test_performed_kind'])
    source = 'bundle.reviewer'
    if kind is None:
        kind = get_any(bundle, _KIND_ALIASES)
        source = 'bundle.evidence_kind'
    if kind is None:
        return 'unknown', None, source
    text = str(kind).strip().lower().replace('-', '_').replace(' ', '_')
    if text in _HUMAN_KINDS:
        return 'human', reviewer_id, source
    if text in _PROXY_KINDS:
        return 'model_proxy', reviewer_id, source
    if text in _FIXTURE_KINDS:
        return 'fixture', reviewer_id, source
    return 'unknown', reviewer_id, source


def _certifications(rows):
    """The four distinct certifications - each one separately reported."""
    unresolved = [row['test_case'] for row in rows
                  if row.get('gate') == 'REQUIRED' and row.get('status') != 'PASS']
    qa_complete = not unresolved
    return {
        'qa_complete': {
            'granted': qa_complete,
            'scope': 'sales_hq_evaluation',
            'basis': SALES_QA_REVIEW_COMPLETE if qa_complete else SALES_QA_REVIEW_INCOMPLETE,
            'unresolved_gates': unresolved,
            'note': 'scope is the Sales headquarters evaluation only; it is not the global '
                    'QA-complete certification of the candidate',
        },
        'product_accepted': {
            'granted': False,
            'scope': 'global_release_pipeline',
            'basis': SALES_PRODUCT_ACCEPTANCE_HOLD,
            'note': 'Product Acceptance remains HOLD in this source phase',
        },
        'stable': {
            'granted': False,
            'scope': 'global_release_pipeline',
            'basis': SALES_STABLE_HOLD,
            'note': 'Stable remains HOLD in this source phase',
        },
        'release_approved': {
            'granted': False,
            'scope': 'global_release_pipeline',
            'basis': SALES_RELEASE_APPROVAL_HOLD,
            'note': 'Release Approved remains HOLD in this source phase',
        },
    }


def _claims(bundle):
    """The subjective claims - reported as observations, never as verdicts."""
    names = ('fun', 'sellable', 'understandable', 'product_acceptance', 'enjoyable')
    claims = {}
    for name in names:
        value = get_any(bundle, [name, name + '_claim', 'claim_' + name])
        recorded = value is not None
        claims[name] = {
            'evaluator_claim': False,
            'basis': 'SALES_SUBJECTIVE_CLAIM_NOT_EVALUATED_BY_THIS_EVALUATOR',
            'recorded_in_evidence': recorded,
            'recorded_value': jsonable(value) if recorded else None,
            'note': 'the value above is an observation copied from the evidence, not a '
                    'statement of this evaluator',
        }
    return claims


# --------------------------------------------------------------------------- #
# public API
# --------------------------------------------------------------------------- #
def evaluate_sales(context):
    """Evaluate the Sales headquarters domain.

    Never raises for missing or malformed evidence: missing evidence yields
    ``NOT_RUN`` for its own gate and the domain stays non-PASS.
    """
    settings = getattr(context, 'settings', None) or {}
    bundle, sources = collect_evidence(context, DOMAIN, SALES_EVIDENCE_FILES)
    # A collected bundle may claim a human test it cannot prove.  The intake
    # owns that rule, so it is applied here as well: a proxy review may add
    # observations, but it can never buy the human gate.
    bundle, sanitizer_notes = sanitize_sales_bundle(bundle)
    table, threshold_sources, ignored = resolve_thresholds(settings, DOMAIN, bundle)

    rows = []
    risks = []
    notes = []
    for note in sanitizer_notes:
        risks.append({'code': note, 'severity': 'ERROR',
                      'detail': 'a collected human-test claim was rejected because the '
                                'recorded reviewer is not a real human'})
        notes.append(note)
    sessions = _sessions(bundle)

    cold_session = _cold_start_session(sessions)
    provenance = _provenance_of(cold_session) if cold_session is not None else {}
    provenance_recorded = bool([key for key, value in provenance.items() if value not in (None, '', [], {})])

    # -- cold start session -------------------------------------------------- #
    observed_phases = 0
    if cold_session is not None:
        for name, aliases in PHASES:
            if _phase_record(cold_session, aliases) is not None:
                observed_phases += 1
    if cold_session is None:
        cold_row = _row('sales.cold_start_session', 'NOT_RUN', SALES_COLD_START_EVIDENCE_ABSENT,
                        detail='no cold-start session was found in the sales evidence')
        risks.append({'code': SALES_COLD_START_EVIDENCE_ABSENT, 'severity': 'ERROR',
                      'detail': 'no cold-start session was found; the cold-start review never happened'})
    elif observed_phases == 0:
        cold_row = _row('sales.cold_start_session', 'NOT_RUN', SALES_COLD_START_EVIDENCE_ABSENT,
                        detail='the cold-start session carries no review phase')
        risks.append({'code': SALES_COLD_START_EVIDENCE_ABSENT, 'severity': 'ERROR',
                      'detail': 'the cold-start session carries no review phase evidence'})
    else:
        cold_row = _row('sales.cold_start_session', 'PASS', None,
                        detail='a cold-start session with %d reviewed phase(s) was recorded'
                               % observed_phases)
    rows.append(cold_row)

    # -- cold start provenance ----------------------------------------------- #
    if cold_session is None:
        provenance_row = _row('sales.cold_start_provenance', 'NOT_RUN',
                              SALES_COLD_START_EVIDENCE_ABSENT,
                              detail='there is no cold-start session to carry provenance')
    elif not provenance_recorded:
        provenance_row = _row('sales.cold_start_provenance', 'NOT_RUN',
                              SALES_COLD_START_PROVENANCE_MISSING,
                              detail='the cold-start session does not record where it came from')
        risks.append({'code': SALES_COLD_START_PROVENANCE_MISSING, 'severity': 'ERROR',
                      'detail': 'the cold-start session carries no provenance'})
    else:
        provenance_row = _row('sales.cold_start_provenance', 'PASS', None,
                              detail='the cold-start session records its provenance')
    rows.append(provenance_row)

    # -- the four review phases ---------------------------------------------- #
    phase_records = {}
    phase_rows = {}
    for name, aliases in PHASES:
        gate = 'sales.' + name
        threshold = table.get(name)
        row, record = _evaluate_phase(gate, name, cold_session, threshold)
        rows.append(row)
        phase_rows[name] = row
        phase_records[name] = record
        if row['status'] == 'NOT_RUN':
            risks.append({'code': row.get('reason_code'), 'severity': 'ERROR',
                          'detail': row.get('detail')})
        elif row['status'] == 'FAIL':
            risks.append({'code': row.get('reason_code'), 'severity': 'ERROR',
                          'detail': row.get('detail')})

    # -- evidence-backed audience/product communication ----------------------- #
    audience = bundle.get('audience_summary') if isinstance(bundle, dict) else None
    audience = audience if isinstance(audience, dict) else {}
    audience_entries = audience.get('entries') if isinstance(audience.get('entries'), list) else []
    audience_evidence = bundle.get('audience_summary_evidence') if isinstance(bundle, dict) else []
    if isinstance(audience_evidence, str):
        audience_evidence = [audience_evidence]
    elif not isinstance(audience_evidence, (list, tuple)):
        audience_evidence = []
    audience_evidence = [str(x) for x in audience_evidence if str(x)]
    contract = audience.get('description_contract') if isinstance(audience.get('description_contract'), dict) else {}
    generated = audience.get('status') == 'GENERATED' and bool(audience_entries)
    descriptions = [
        str(entry.get('product_description') or '').strip()
        for entry in audience_entries if isinstance(entry, dict)
    ]
    what_game = [
        str(entry.get('what_game') or '').strip()
        for entry in audience_entries if isinstance(entry, dict)
    ]

    if generated and audience_evidence and descriptions and all(descriptions) and contract.get('brand_price_independent') is True:
        product_description_row = _row(
            'sales.product_description_independent', 'PASS', None,
            evidence=audience_evidence,
            detail='mechanics-only product description was generated without game/IP/price/free metadata'
        )
    else:
        product_description_row = _row(
            'sales.product_description_independent', 'NOT_RUN',
            SALES_AUDIENCE_DESCRIPTION_INVALID if audience else SALES_AUDIENCE_SUMMARY_ABSENT,
            evidence=audience_evidence,
            detail='no valid name/IP/price-blind mechanics description was available'
        )
    rows.append(product_description_row)

    if generated and audience_evidence and what_game and all(what_game):
        what_game_row = _row(
            'sales.what_game_summary', 'PASS', None, evidence=audience_evidence,
            detail='what-the-player-does summary was derived from packaged mechanics evidence'
        )
    else:
        what_game_row = _row(
            'sales.what_game_summary', 'NOT_RUN',
            SALES_AUDIENCE_SUMMARY_ABSENT, evidence=audience_evidence,
            detail='no evidence-backed what-game summary was available'
        )
    rows.append(what_game_row)

    communication_row = phase_rows.get('communication_readability') or {}
    if not (generated and audience_evidence):
        nontechnical_row = _row(
            'sales.nontechnical_report', 'NOT_RUN', SALES_AUDIENCE_SUMMARY_ABSENT,
            evidence=audience_evidence,
            detail='the audience report was not generated from evidence'
        )
    elif communication_row.get('status') == 'PASS':
        nontechnical_row = _row(
            'sales.nontechnical_report', 'PASS', None,
            evidence=audience_evidence + list(communication_row.get('evidence') or []),
            detail='the generated audience report also passed the independent communication/readability review'
        )
    elif communication_row.get('status') == 'FAIL':
        nontechnical_row = _row(
            'sales.nontechnical_report', 'FAIL', communication_row.get('reason_code') or SALES_PHASE_FAILED,
            evidence=audience_evidence + list(communication_row.get('evidence') or []),
            detail='the generated audience report did not pass the communication/readability review'
        )
    else:
        nontechnical_row = _row(
            'sales.nontechnical_report', 'NOT_RUN', SALES_READABILITY_REVIEW_REQUIRED,
            evidence=audience_evidence,
            detail='the audience report exists, but nontechnical readability has not been accepted'
        )
    rows.append(nontechnical_row)

    for audience_row in (product_description_row, what_game_row, nontechnical_row):
        if audience_row['status'] in ('NOT_RUN', 'FAIL'):
            risks.append({
                'code': audience_row.get('reason_code'),
                'severity': 'ERROR',
                'detail': audience_row.get('detail'),
            })

    # -- human test ---------------------------------------------------------- #
    reviewer_kind, reviewer_id, reviewer_source = _reviewer_kind(bundle)
    human_evidence = False
    if reviewer_kind == 'human':
        present, value = lookup(bundle, ['human_test_performed', 'human_test_evidence'])
        # Human identity alone is not evidence that a human test occurred.
        # The performed flag must be present and explicitly true; missing or
        # indeterminate evidence stays NOT_RUN.
        human_evidence = bool(present and truthiness(value) is True)
    if reviewer_kind == 'model_proxy':
        human_row = _row('sales.human_test', 'NOT_RUN', SALES_MODEL_PROXY_IS_NOT_HUMAN_TEST,
                         detail='the review was produced by a model proxy; a model proxy is '
                                'not a human test')
        risks.append({'code': SALES_MODEL_PROXY_IS_NOT_HUMAN_TEST, 'severity': 'ERROR',
                      'detail': 'a model proxy review cannot be reported as a human test'})
    elif reviewer_kind == 'fixture':
        human_row = _row('sales.human_test', 'NOT_RUN', SALES_EVIDENCE_FIXTURE,
                         detail='fixture evidence cannot stand in for a human test')
        risks.append({'code': SALES_EVIDENCE_FIXTURE, 'severity': 'ERROR',
                      'detail': 'the sales evidence is fixture evidence'})
    elif reviewer_kind == 'human' and human_evidence:
        human_row = _row('sales.human_test', 'PASS', None,
                         detail='a real human reviewer produced the evidence')
    else:
        human_row = _row('sales.human_test', 'NOT_RUN', SALES_HUMAN_TEST_EVIDENCE_ABSENT,
                         detail='no real human review evidence was found')
        risks.append({'code': SALES_HUMAN_TEST_EVIDENCE_ABSENT, 'severity': 'ERROR',
                      'detail': 'no real human review evidence was found'})
    rows.append(human_row)
    human_test_performed = human_row['status'] == 'PASS'

    if not bundle:
        risks.append({'code': SALES_EVALUATION_NOT_PERFORMED, 'severity': 'ERROR',
                      'detail': 'no sales evidence was found; nothing could be evaluated'})
    for metric, hint in sorted(ignored.items()):
        risks.append({'code': 'SALES_THRESHOLD_IGNORED', 'severity': 'WARNING',
                      'detail': 'the threshold for %s was ignored: %s' % (metric, hint)})

    status = _aggregate(rows)
    reason_code = (_domain_reason(rows) if bundle else SALES_EVALUATION_NOT_PERFORMED)
    unresolved = [{'gate': row['test_case'], 'status': row['status'],
                   'reason_code': row.get('reason_code'), 'detail': row.get('detail')}
                  for row in rows if row.get('gate') == 'REQUIRED' and row.get('status') != 'PASS']

    if sources:
        notes.append('SALES_EVIDENCE_SOURCES:' + ','.join(
            str(source.get('location')) for source in sources))
    if not bundle:
        notes.append(SALES_EVALUATION_NOT_PERFORMED)

    readback = {
        'schema_version': READBACK_SCHEMA_VERSION,
        'domain': DOMAIN,
        'status': status,
        'reason_code': reason_code,
        'accepted': status == 'PASS',
        'evidence_present': bool(bundle),
        'evidence_sources': sources,
        'evidence_kind': reviewer_kind,
        'reviewer': {'kind': reviewer_kind, 'id': jsonable(reviewer_id), 'source': reviewer_source},
        'human_test_performed': bool(human_test_performed),
        'human_test_evidence': {
            'present': bool(human_test_performed),
            'kind': reviewer_kind,
            'reason_code': None if human_test_performed else human_row.get('reason_code'),
            'determinate': reviewer_kind in ('human', 'model_proxy', 'fixture'),
            'note': 'a model proxy review is never reported as a human test',
        },
        'sessions': [{'session_id': _session_id(session),
                      'cold_start': session is cold_session,
                      'provenance': jsonable(_provenance_of(session))}
                     for session in sessions],
        'phases': phase_records,
        'audience_summary': jsonable(audience),
        'certifications': _certifications(rows),
        'claims': _claims(bundle),
        'unresolved_gates': unresolved,
        'gates': _gate_rows(rows),
        'gate_status': _all_gate_rows(rows),
        'risks': risks,
        'notes': notes,
        'generated_at': str(stamp()),
    }
    readback['fingerprint'] = stable_fingerprint(readback)

    return ReadbackDomainReport(DOMAIN, status, reason_code, _gate_rows(rows), _counts(rows),
                                 False, None, notes, readback=readback)


def sales_readback(report):
    """Readback of a sales report (helper for the coordinator)."""
    return getattr(report, 'readback', None)


__all__ = ['DOMAIN', 'SALES_EVALUATION_NOT_PERFORMED', 'evaluate_sales', 'sales_readback']