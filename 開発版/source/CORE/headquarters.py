"""Three-headquarters gate model: independent domains and a stable serializable summary.

Domain status semantics are reused from common.overall so v0.3.3 behaviour is
preserved: only rows marked REQUIRED decide a domain status, and a REQUIRED row that
never ran is surfaced as HARNESS_ERROR (never as PASS).

Cross-domain reduction is deliberately independent. Every registered domain keeps its
own status, the aggregate is the most severe domain status, and a domain can never be
masked by the PASS of another domain.

Standard library only.
"""
from __future__ import annotations

from common import overall, stamp

SCHEMA_VERSION = 1

# Fixed order of the three headquarters. The order of the serialized summary never
# depends on registration order.
DOMAIN_ORDER = ('production', 'management', 'sales')

# Severity used for the cross-domain reduction. It mirrors the severity order of
# common.overall, but NOT_RUN stays explicit instead of being upgraded silently.
SEVERITY = {'PASS': 0, 'NOT_RUN': 1, 'INCONCLUSIVE': 2, 'FAIL': 3, 'HARNESS_ERROR': 4}

UNRESOLVED_STATUSES = ('NOT_RUN', 'INCONCLUSIVE', 'FAIL', 'HARNESS_ERROR')


def worst_status(statuses):
    """Most severe status of the given statuses; PASS only when all of them are PASS."""
    worst = 'PASS'
    for status in statuses:
        if status not in SEVERITY:
            raise ValueError('UNKNOWN_STATUS:' + str(status))
        if SEVERITY[status] > SEVERITY[worst]:
            worst = status
    return worst


def _gate_row(name, status, gate, reason_code=None, evidence=None, severity=None):
    return {'name': name, 'status': status, 'required': gate == 'REQUIRED',
            'reason_code': reason_code, 'evidence': list(evidence or []),
            'severity': severity}


class DomainReport:
    """Status of one headquarters domain. Never merged with another domain's status."""

    def __init__(self, name, status, reason_code=None, gates=None, counts=None,
                 certifies_real_target=False, target=None, notes=None):
        if status not in SEVERITY:
            raise ValueError('UNKNOWN_STATUS:' + str(status))
        self.name = name
        self.status = status
        self.reason_code = reason_code
        self.gates = list(gates or [])
        self.counts = dict(counts or {})
        self.certifies_real_target = bool(certifies_real_target)
        self.target = dict(target) if target else None
        self.notes = list(notes or [])

    @classmethod
    def from_results(cls, name, results, reason_code=None, certifies_real_target=False, target=None):
        """Build a domain report from result rows using baseline overall() semantics.

        PASS rows are represented by the counts, every non PASS row keeps its own gate
        entry so a domain can never hide a NOT_RUN / FAIL / HARNESS_ERROR.
        """
        rows = list(results)
        counts = {'total': len(rows)}
        gates = []
        for row in rows:
            status = row.get('status', 'NOT_RUN')
            counts[status] = counts.get(status, 0) + 1
            if status != 'PASS':
                gates.append(_gate_row(row.get('test_case', 'run'), status,
                                       row.get('gate', 'REQUIRED'), row.get('reason_code'),
                                       row.get('evidence'), row.get('severity')))
        return cls(name, overall(rows), reason_code, gates, counts,
                   certifies_real_target, target)

    @classmethod
    def not_run(cls, name, reason_code, note=None):
        """Explicit NOT_RUN domain, used when an evaluation was not performed."""
        return cls(name, 'NOT_RUN', reason_code, [], {'total': 0}, False, None,
                   [note] if note else None)

    def to_dict(self):
        return {'name': self.name,
                'status': self.status,
                'reason_code': self.reason_code,
                'certifies_real_target': self.certifies_real_target,
                'counts': self.counts,
                'gates': self.gates,
                'target': self.target,
                'notes': self.notes}


class HeadquartersSummary:
    """Stable, serializable summary of the three headquarters domains."""

    def __init__(self, domains, generated_at=None, schema_version=SCHEMA_VERSION):
        by_name = {}
        for domain in domains:
            if domain.name not in DOMAIN_ORDER:
                raise ValueError('UNKNOWN_DOMAIN:' + str(domain.name))
            if domain.name in by_name:
                raise ValueError('DUPLICATE_DOMAIN:' + str(domain.name))
            by_name[domain.name] = domain
        # Missing headquarters are explicit harness failures, never silently omitted.
        self.domains = [
            by_name.get(name) or DomainReport(
                name, 'HARNESS_ERROR', 'HEADQUARTERS_DOMAIN_MISSING',
                gates=[_gate_row('headquarters.' + name, 'HARNESS_ERROR', 'REQUIRED',
                                 'HEADQUARTERS_DOMAIN_MISSING')],
                counts={'total': 1, 'HARNESS_ERROR': 1})
            for name in DOMAIN_ORDER
        ]
        self.generated_at = generated_at or stamp()
        self.schema_version = schema_version

    @property
    def overall(self):
        if not self.domains:
            return 'NOT_RUN'
        return worst_status(domain.status for domain in self.domains)

    @property
    def blocked_by(self):
        return [{'domain': domain.name, 'status': domain.status, 'reason_code': domain.reason_code}
                for domain in self.domains if domain.status != 'PASS']

    @property
    def accepted(self):
        """True only when every domain of the pipeline resolved to PASS."""
        return bool(self.domains) and self.overall == 'PASS'

    def readback(self, name):
        """Return one optional domain evidence readback without changing Phase-1 serialization."""
        for domain in self.domains:
            if domain.name == name:
                return getattr(domain, 'readback', None)
        return None

    def readbacks(self):
        """Return available evidence readbacks keyed by independent headquarters domain."""
        return {domain.name: getattr(domain, 'readback')
                for domain in self.domains if getattr(domain, 'readback', None) is not None}

    def to_dict(self):
        return {'schema_version': self.schema_version,
                'generated_at': self.generated_at,
                'overall': self.overall,
                'accepted': self.accepted,
                'decision': 'ACCEPTED' if self.accepted else 'NOT_ACCEPTED',
                'blocked_by': self.blocked_by,
                'domains': [domain.to_dict() for domain in self.domains]}
