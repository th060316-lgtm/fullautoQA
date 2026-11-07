"""Intake for review evidence produced outside the automated run.

Why this module exists
----------------------
The Sales headquarters must be able to consume review evidence that was not
produced by the automated run itself: a human cold-start playtest, or a
validated review analyser.  Two rules make that intake safe, and they are the
reason this module exists:

1. **A model proxy is never promoted to a human.**  ``human_test_performed``
   is only ever true when the recorded reviewer kind is a human kind.  A
   proxy review may contribute observations, but the Sales domain still stays
   non-PASS because its ``sales.human_test`` gate remains ``NOT_RUN``.
2. **Evidence that is absent stays absent.**  Nothing here can turn a
   ``NOT_RUN`` into a ``PASS`` without a review that actually says so, and a
   malformed review file is reported, not guessed at.

The reviewer classification lives here (and not in the evaluator) so that the
intake and the judgement can never disagree about what counts as a human.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

#: Environment variable that points at an explicit review evidence file.
REVIEW_EVIDENCE_ENV = 'FULLAUTOQA_SALES_REVIEW_EVIDENCE'

#: Default location of the review evidence inside a run's evidence root.
REVIEW_EVIDENCE_RELATIVE = 'review_evidence/sales_review.json'

#: The four player-facing review phases the Sales gate knows about.
REVIEW_PHASES = ('first_30_seconds', 'first_5_minutes', 'product_shelf_test',
                 'communication_readability')

HUMAN_KINDS = frozenset({'human', 'human_reviewer', 'real_human', 'person', 'player',
                         'tester', 'manual_reviewer', 'human_tester'})
PROXY_KINDS = frozenset({'model', 'model_proxy', 'llm', 'ai', 'proxy', 'synthetic',
                          'simulated', 'agent', 'automated', 'self_review'})
FIXTURE_KINDS = frozenset({'fixture', 'selftest', 'self_test', 'unit', 'unit_test',
                            'synthetic', 'mock', 'stub', 'dry_run'})

#: Accepted outcomes for a reviewed phase.
PHASE_STATUSES = ('PASS', 'FAIL', 'INCONCLUSIVE', 'NOT_RUN')


def normalize_kind(kind):
    """Canonical reviewer kind, or ``None`` when the kind is unknown."""
    if kind is None:
        return None
    text = str(kind).strip().lower().replace('-', '_').replace(' ', '_')
    if text in HUMAN_KINDS:
        return 'human'
    if text in PROXY_KINDS:
        return 'model_proxy'
    if text in FIXTURE_KINDS:
        return 'fixture'
    return None


def find_review_evidence(root, explicit_path=''):
    """Locate the review evidence file for a run.

    Returns ``(path, source)``.  ``path`` is ``None`` when no review evidence
    is present, which is the normal case for an automated-only run.
    """
    candidate = explicit_path or os.environ.get(REVIEW_EVIDENCE_ENV, '')
    if candidate:
        path = Path(candidate)
        return (path if path.is_file() else None, 'explicit')
    if not root:
        return (None, 'absent')
    path = Path(root) / REVIEW_EVIDENCE_RELATIVE
    if path.is_file():
        return (path, 'default')
    return (None, 'absent')


def validate_review_evidence(data, run_id=None):
    """Validate a review evidence document.

    Returns ``(normalized, problems)``.  ``normalized`` is ``None`` when the
    document cannot be used at all.  Problems are human readable strings; they
    never silently repair the document.
    """
    problems = []
    if not isinstance(data, dict):
        return None, ['REVIEW_EVIDENCE_NOT_AN_OBJECT']
    if int(data.get('schema_version') or 0) != 1:
        problems.append('REVIEW_EVIDENCE_SCHEMA_VERSION_UNSUPPORTED')
    reviewer = data.get('reviewer')
    if not isinstance(reviewer, dict):
        problems.append('REVIEW_EVIDENCE_REVIEWER_MISSING')
        reviewer = {}
    raw_kind = reviewer.get('kind') or reviewer.get('type') or reviewer.get('role')
    kind = normalize_kind(raw_kind)
    if kind is None:
        problems.append('REVIEW_EVIDENCE_REVIEWER_KIND_UNKNOWN')
    sessions = data.get('sessions')
    if not isinstance(sessions, list) or not sessions:
        problems.append('REVIEW_EVIDENCE_SESSIONS_MISSING')
        sessions = []
    normalized_sessions = []
    for index, session in enumerate(sessions):
        if not isinstance(session, dict):
            problems.append('REVIEW_EVIDENCE_SESSION_INVALID:%d' % index)
            continue
        phases = session.get('phases')
        if not isinstance(phases, dict) or not phases:
            problems.append('REVIEW_EVIDENCE_PHASES_MISSING:%d' % index)
            continue
        normalized_phases = {}
        for name in REVIEW_PHASES:
            record = phases.get(name)
            if not isinstance(record, dict):
                continue
            status = str(record.get('status') or '').strip().upper()
            findings = record.get('findings')
            if status and status not in PHASE_STATUSES:
                problems.append('REVIEW_EVIDENCE_PHASE_STATUS_INVALID:%s:%s' % (name, status))
                continue
            if not status and not isinstance(findings, list):
                problems.append('REVIEW_EVIDENCE_PHASE_OUTCOME_MISSING:%s' % name)
                continue
            evidence = list(record.get('evidence') or []) if isinstance(record.get('evidence'), list) else []
            evidence = [str(item) for item in evidence if str(item)]
            if status == 'PASS' and not evidence:
                problems.append('REVIEW_EVIDENCE_PHASE_EVIDENCE_MISSING:%s' % name)
                continue
            normalized_phases[name] = {
                'status': status or None,
                'findings': list(findings) if isinstance(findings, list) else [],
                'evidence': evidence,
            }
        if not normalized_phases:
            problems.append('REVIEW_EVIDENCE_NO_REVIEWED_PHASE:%d' % index)
            continue
        normalized_sessions.append({
            'session_id': str(session.get('session_id') or ''),
            'cold_start': bool(session.get('cold_start')),
            'provenance': dict(session.get('provenance') or {}) if isinstance(session.get('provenance'), dict) else {},
            'phases': normalized_phases,
        })
    if not normalized_sessions:
        problems.append('REVIEW_EVIDENCE_NO_USABLE_SESSION')
    human_test_claimed = bool(data.get('human_test_performed'))
    reviewer_id = reviewer.get('id') or reviewer.get('name')
    if kind == 'human' and human_test_claimed:
        # A bare "kind=human, performed=true" assertion is not enough to buy
        # the required Human gate.  The intake must preserve at least who
        # reviewed, a cold-start session, and provenance for that session.
        if not reviewer_id:
            problems.append('REVIEW_EVIDENCE_HUMAN_REVIEWER_ID_MISSING')
        cold_sessions = [session for session in normalized_sessions if session.get('cold_start')]
        if not cold_sessions:
            problems.append('REVIEW_EVIDENCE_HUMAN_COLD_START_MISSING')
        elif not any(session.get('provenance') for session in cold_sessions):
            problems.append('REVIEW_EVIDENCE_HUMAN_PROVENANCE_MISSING')
    if run_id is not None:
        declared = str(data.get('run_id') or '')
        if declared and declared != str(run_id):
            problems.append('REVIEW_EVIDENCE_RUN_ID_MISMATCH:%s' % declared)
    normalized = {
        'schema_version': 1,
        'run_id': data.get('run_id'),
        'reviewer': {'kind': kind, 'id': reviewer_id},
        'human_test_performed': bool(data.get('human_test_performed')),
        'sessions': normalized_sessions,
    }
    if isinstance(data.get('series_binding'), dict):
        normalized['series_binding'] = dict(data.get('series_binding'))
    if problems:
        return None, problems
    return normalized, []


def load_review_evidence(root, explicit_path='', run_id=None):
    """Load, validate and return the review evidence for a run.

    Returns ``(normalized, problems, source)``.  ``normalized`` is ``None``
    when there is no usable review evidence; the problems then say why.
    """
    path, source = find_review_evidence(root, explicit_path)
    if path is None:
        return None, [], source
    try:
        raw = path.read_text(encoding='utf-8-sig')
        data = json.loads(raw)
    except Exception as ex:
        return None, ['REVIEW_EVIDENCE_UNREADABLE:%s' % type(ex).__name__], source
    normalized, problems = validate_review_evidence(data, run_id=run_id)
    if normalized is not None:
        normalized['source'] = str(path)
    return normalized, problems, source


def merge_review_evidence(sales_bundle, review):
    """Merge validated review evidence into a Sales evidence bundle.

    The reviewer kind is preserved and a proxy is never promoted to a human.
    The automated session is kept, so the automated observation is not
    overwritten; the reviewed phases are added to the cold-start session.
    """
    bundle = dict(sales_bundle or {})
    if not review:
        return bundle, ['REVIEW_EVIDENCE_ABSENT']
    kind = review.get('reviewer', {}).get('kind')
    reviewer = {'kind': kind, 'id': review.get('reviewer', {}).get('id')}
    bundle['reviewer'] = reviewer
    bundle['evidence_kind'] = 'human_review' if kind == 'human' else 'model_proxy'
    bundle['human_test_performed'] = bool(kind == 'human' and review.get('human_test_performed'))
    bundle['review_evidence_source'] = review.get('source')
    if isinstance(review.get('series_binding'), dict):
        bundle['review_binding'] = dict(review.get('series_binding'))
    sessions = list(bundle.get('sessions') or [])
    cold = None
    for session in sessions:
        if isinstance(session, dict) and session.get('cold_start'):
            cold = session
            break
    if cold is None:
        cold = {'session_id': review.get('run_id') or 'review', 'cold_start': True,
                'provenance': {'source': 'review_evidence'}, 'phases': {}}
        sessions.append(cold)
    phases = dict(cold.get('phases') or {})
    for session in review.get('sessions') or []:
        for name, record in (session.get('phases') or {}).items():
            phases[name] = dict(record)
    cold['phases'] = phases
    bundle['sessions'] = sessions
    return bundle, []


def sanitize_sales_bundle(bundle):
    """Refuse to let a bundle claim a human test it cannot prove.

    This is applied to whatever evidence the Sales evaluator collected, so a
    raw evidence file that claims ``human_test_performed`` while naming a
    model proxy cannot buy a PASS.
    """
    if not isinstance(bundle, dict):
        return bundle, []
    notes = []
    reviewer = bundle.get('reviewer')
    kind = None
    if isinstance(reviewer, dict):
        kind = normalize_kind(reviewer.get('kind') or reviewer.get('type') or reviewer.get('role'))
    elif isinstance(reviewer, str):
        kind = normalize_kind(reviewer)
    if kind is None:
        kind = normalize_kind(bundle.get('evidence_kind'))
    if kind != 'human' and bundle.get('human_test_performed') is True:
        notes.append('SALES_HUMAN_TEST_CLAIM_REJECTED:%s' % (kind or 'unknown'))
        bundle['human_test_performed'] = False
    return bundle, notes
