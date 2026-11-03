"""Shared evidence collection for the FullAutoQA Headquarters domain evaluators.

Why this module exists
----------------------
The Management and the Sales headquarters evaluator must answer the same
question honestly: *what evidence was actually produced, where did it come
from, and what could not be established?*  This module is the single
implementation of that question so the two domains cannot drift apart.

Hard rules encoded here (they are the reason this module exists at all)
-----------------------------------------------------------------------
1. An absent measurement is **not** zero.  Absent values stay ``None`` and are
   reported as unavailable.
2. An absent required evidence item is ``NOT_RUN`` / non-PASS, never ``PASS``.
3. Thresholds are only ever applied when they are *configured* - operator
   settings first, then an explicitly declared threshold block inside the
   evidence.  No numeric threshold is invented here, and a bare number is
   refused rather than guessed (a number alone does not say which direction
   it bounds).
4. Every collected value keeps provenance: the kind of source it came from,
   where it was found, and - for files - the SHA-256 of the bytes that were
   actually read.
5. Nothing raises out of this module.  A broken evidence file degrades to an
   unusable source, never to an exception that would take the whole
   headquarters evaluation down.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
from datetime import date, datetime
from pathlib import Path

from headquarters import DomainReport

__all__ = [
    'MANUAL_THRESHOLD_HINT',
    'ReadbackDomainReport',
    'collect_evidence',
    'compare_threshold',
    'fingerprint',
    'jsonable',
    'lookup',
    'merge_bundles',
    'read_measurement',
    'read_json_safe',
    'resolve_thresholds',
    'safe_join',
    'sha256_file',
    'stable_fingerprint',
    'truthiness',
    'units_compatible',
]

_MISSING = object()

#: Documented reason why a bare numeric threshold is not honoured.
MANUAL_THRESHOLD_HINT = 'bare numeric thresholds are ambiguous and are not interpreted'


class ReadbackDomainReport(DomainReport):
    """A :class:`headquarters.DomainReport` that also carries a readback.

    Additive only: ``to_dict()`` is inherited unchanged, so the Phase-1
    headquarters payload shape is not affected.  The readback travels
    alongside the report and is attached to the result model by the
    coordinator.
    """

    def __init__(self, *args, readback=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.readback = readback


# --------------------------------------------------------------------------- #
# key handling
# --------------------------------------------------------------------------- #
def normalize_key(key):
    """Lower-case, underscore separated form of ``key``."""
    return re.sub(r'[^a-z0-9]+', '_', str(key).strip().lower()).strip('_')


def compact_key(key):
    """Letter/digit-only form of ``key`` - used for tolerant key matching."""
    return re.sub(r'[^a-z0-9]+', '', str(key).strip().lower())


def lookup(mapping, names, default=None):
    """Tolerant multi-name lookup.

    Returns ``(present, value)``.  ``present`` is ``False`` when no candidate
    name matched *or* when the matched value is ``None`` (``None`` is treated
    as "not recorded" - it is never a measurement).
    """
    if not isinstance(mapping, dict):
        return False, default
    for name in names:
        if name in mapping:
            value = mapping[name]
            return (value is not None), value
    wanted = {compact_key(name) for name in names}
    for key, value in mapping.items():
        if compact_key(key) in wanted:
            return (value is not None), value
    return False, default


def get_any(mapping, names, default=None):
    """Value of the first matching name, or ``default``."""
    present, value = lookup(mapping, names, default)
    return value if present else default


def has_any(mapping, names):
    """True when at least one of ``names`` is present with a non-None value."""
    return lookup(mapping, names)[0]


# --------------------------------------------------------------------------- #
# serialization helpers
# --------------------------------------------------------------------------- #
def jsonable(value):
    """Coerce ``value`` into something ``json.dumps`` can serialize safely.

    Non-finite floats become ``None`` (they are not numbers we can report),
    unknown objects fall back to their string form.  The function never
    raises.
    """
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {str(key): jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(item) for item in value]
    if isinstance(value, (set, frozenset)):
        return sorted(jsonable(item) for item in value)
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    to_dict = getattr(value, 'to_dict', None)
    if callable(to_dict):
        try:
            return jsonable(to_dict())
        except Exception:  # pragma: no cover - defensive
            pass
    try:
        return str(value)
    except Exception:  # pragma: no cover - defensive
        return None


def fingerprint(value):
    """SHA-256 over a canonical JSON rendering of ``value``."""
    payload = json.dumps(jsonable(value), sort_keys=True, separators=(',', ':'),
                         ensure_ascii=False, default=str)
    return hashlib.sha256(payload.encode('utf-8')).hexdigest()


def stable_fingerprint(value):
    """Fingerprint that ignores volatile fields (timestamp and self-reference)."""
    if isinstance(value, dict):
        value = {key: item for key, item in value.items()
                 if key not in ('generated_at', 'fingerprint')}
    return fingerprint(value)


# --------------------------------------------------------------------------- #
# file helpers
# --------------------------------------------------------------------------- #
def safe_join(root, rel):
    """Join ``rel`` under ``root`` refusing absolute paths and ``..`` escapes.

    Returns ``None`` when the path is not acceptable - the caller then treats
    the location as "not found" rather than reading something unexpected.
    """
    text = str(rel or '').strip()
    if not text:
        return None
    candidate = Path(text)
    if candidate.is_absolute() or candidate.drive or text.startswith(('/', '\\')):
        return None
    if any(part == '..' for part in candidate.parts):
        return None
    root_path = Path(root)
    target = root_path / candidate
    try:
        resolved_root = root_path.resolve()
        resolved = target.resolve()
    except OSError:
        return None
    if resolved != resolved_root and resolved_root not in resolved.parents:
        return None
    return target


def sha256_file(path):
    """SHA-256 of a file, or ``None`` when it cannot be read."""
    try:
        digest = hashlib.sha256()
        with open(path, 'rb') as handle:
            for chunk in iter(lambda: handle.read(65536), b''):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def read_json_safe(path):
    """Read a JSON object from ``path``; ``None`` on any failure."""
    try:
        with open(path, 'r', encoding='utf-8') as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


# --------------------------------------------------------------------------- #
# evidence collection
# --------------------------------------------------------------------------- #
def merge_bundles(bundles):
    """Merge evidence bundles; later bundles win, nested dicts are merged."""
    merged = {}
    for bundle in bundles:
        if not isinstance(bundle, dict):
            continue
        for key, value in bundle.items():
            if isinstance(value, dict) and isinstance(merged.get(key), dict):
                combined = dict(merged[key])
                combined.update(value)
                merged[key] = combined
            else:
                merged[key] = value
    return merged


def _extras_bundles(extras, domain):
    """Bundles handed over directly through ``CoordinatorContext.extras``."""
    found = []
    if not isinstance(extras, dict):
        return found
    present, value = lookup(extras, [domain + '_evidence', domain + '_readback'])
    if present:
        if isinstance(value, dict):
            found.append(('extras.' + domain + '_evidence', value))
        elif isinstance(value, list):
            for index, item in enumerate(value):
                if isinstance(item, dict):
                    found.append(('extras.%s_evidence[%d]' % (domain, index), item))
    present, value = lookup(extras, ['evidence'])
    if present and isinstance(value, dict):
        present, nested = lookup(value, [domain])
        if present and isinstance(nested, dict):
            found.append(('extras.evidence.' + domain, nested))
    return found


def _row_bundles(rows, domain):
    """Evidence payloads carried by individual result rows."""
    found = []
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        test_case = str(row.get('test_case') or '')
        if not test_case.startswith(domain + '.'):
            continue
        for key in (domain + '_evidence', 'evidence_bundle', 'payload'):
            present, value = lookup(row, [key])
            if present and isinstance(value, dict):
                found.append(('result_row:' + test_case, value))
                break
    return found


def _file_bundles(root, domain, candidate_files, scan_dirs):
    """Evidence bundles read from disk."""
    found = []
    names = []
    for name in candidate_files or ():
        if name and name not in names:
            names.append(name)
    for scan_dir in scan_dirs or ():
        directory = safe_join(root, scan_dir)
        if directory is None or not directory.is_dir():
            continue
        try:
            entries = sorted(os.listdir(directory))
        except OSError:
            continue
        for entry in entries:
            if not entry.lower().endswith('.json'):
                continue
            if not entry.lower().startswith(domain.lower()):
                continue
            relative = '%s/%s' % (scan_dir, entry)
            if relative not in names:
                names.append(relative)
    for name in names:
        path = safe_join(root, name)
        if path is None or not path.is_file():
            continue
        data = read_json_safe(path)
        if data is None:
            found.append(('file:' + name, None))
            continue
        found.append(('file:' + name, data))
    return found


def collect_evidence(context, domain, candidate_files=(), scan_dirs=('evidence',)):
    """Collect the evidence bundle for ``domain`` plus its provenance.

    Returns ``(bundle, sources)``.  ``bundle`` is ``{}`` when nothing usable
    was found.  ``sources`` is an ordered list of provenance records - every
    location that was consulted, whether or not it yielded data.
    """
    sources = []
    bundles = []
    extras = getattr(context, 'extras', None) or {}
    settings = getattr(context, 'settings', None) or {}
    domain_settings = settings.get(domain) if isinstance(settings.get(domain), dict) else {}

    for location, bundle in _extras_bundles(extras, domain):
        bundles.append(bundle)
        sources.append({'kind': 'inline', 'location': location, 'present': True,
                        'source': 'context.extras'})

    for location, bundle in _row_bundles(getattr(context, 'results', None), domain):
        bundles.append(bundle)
        sources.append({'kind': 'result_row', 'location': location, 'present': True,
                        'source': 'context.results'})

    files = list(candidate_files or ())
    configured = domain_settings.get('evidence_path') if isinstance(domain_settings, dict) else None
    if isinstance(configured, str) and configured.strip():
        files.insert(0, configured.strip())
    root = getattr(context, 'evidence_root', None) or getattr(context, 'root', None) or '.'
    for location, bundle in _file_bundles(root, domain, files, scan_dirs):
        path = safe_join(root, location.split(':', 1)[1])
        record = {'kind': 'file', 'location': location, 'present': bundle is not None,
                  'source': 'evidence_file'}
        if path is not None and path.is_file():
            record['bytes'] = path.stat().st_size
            record['sha256'] = sha256_file(path)
        if bundle is None:
            record['error'] = 'EVIDENCE_FILE_UNREADABLE'
            sources.append(record)
            continue
        bundles.append(bundle)
        sources.append(record)

    return merge_bundles(bundles), sources


# --------------------------------------------------------------------------- #
# measurements
# --------------------------------------------------------------------------- #
def measurements_container(bundle):
    """The mapping that holds the numeric measurements of a bundle."""
    if not isinstance(bundle, dict):
        return {}
    for name in ('measurements', 'metrics', 'measurement', 'resources', 'observations'):
        present, value = lookup(bundle, [name])
        if present and isinstance(value, dict):
            return value
    return {}


def _as_number(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except (TypeError, ValueError):
            return None
    return None


def read_measurement(bundle, aliases, default_unit=None):
    """Read one measurement out of a bundle.

    Returns ``None`` when the measurement was not recorded at all.  The
    recorded value is preserved **exactly** as it was found - it is never
    rounded, substituted or defaulted.
    """
    container = measurements_container(bundle)
    present, raw = lookup(container, aliases)
    if not present:
        present, raw = lookup(bundle, aliases)
    if not present or raw is None:
        return None
    if isinstance(raw, dict):
        present, value = lookup(raw, ['value'])
        statistic = 'value'
        if not present:
            present, value = lookup(raw, ['mean', 'average', 'avg'])
            statistic = 'mean'
        if not present or value is None:
            return None
        unit = get_any(raw, ['unit', 'units'], default_unit)
        source = get_any(raw, ['source', 'collector', 'producer'])
        method = get_any(raw, ['method', 'measurement_method', 'how'])
        evidence = get_any(raw, ['evidence', 'evidence_files', 'artifacts', 'files'], [])
        if isinstance(evidence, str):
            evidence = [evidence]
        elif isinstance(evidence, dict):
            evidence = [str(key) for key in sorted(evidence)]
        elif not isinstance(evidence, (list, tuple)):
            evidence = []
        return {'value': value, 'unit': unit, 'statistic': statistic, 'source': source,
                'method': method, 'evidence': [str(item) for item in evidence]}
    return {'value': raw, 'unit': default_unit, 'statistic': 'value', 'source': None,
            'method': None, 'evidence': []}


# --------------------------------------------------------------------------- #
# thresholds
# --------------------------------------------------------------------------- #
def _threshold_blocks(settings, domain):
    """Threshold blocks coming from operator settings (highest priority first)."""
    blocks = []
    if not isinstance(settings, dict):
        return blocks
    present, value = lookup(settings, [domain + '_thresholds'])
    if present and isinstance(value, dict):
        blocks.append(('settings.' + domain + '_thresholds', value))
    present, value = lookup(settings, [domain])
    if present and isinstance(value, dict):
        present, nested = lookup(value, ['thresholds'])
        if present and isinstance(nested, dict):
            blocks.append(('settings.%s.thresholds' % domain, nested))
    return blocks


def resolve_thresholds(settings, domain, bundle):
    """Resolve the configured thresholds for ``domain``.

    Returns ``(table, source_map)``.  Settings win over the evidence bundle.
    A bare number is ignored (ambiguous direction) and reported as ignored.
    """
    table = {}
    sources = {}
    ignored = {}
    present, value = lookup(bundle if isinstance(bundle, dict) else {}, ['thresholds', 'threshold'])
    if present and isinstance(value, dict):
        for metric, threshold in value.items():
            table[normalize_key(metric)] = threshold
            sources[normalize_key(metric)] = 'evidence_bundle.thresholds'
    for label, block in _threshold_blocks(settings, domain):
        for metric, threshold in block.items():
            key = normalize_key(metric)
            table[key] = threshold
            sources[key] = label
    for metric, threshold in list(table.items()):
        if isinstance(threshold, bool) or not isinstance(threshold, dict):
            ignored[metric] = MANUAL_THRESHOLD_HINT
            table.pop(metric, None)
            sources.pop(metric, None)
    return table, sources, ignored


def units_compatible(measurement_unit, threshold):
    """Whether a threshold may be applied to a measurement with this unit."""
    if not isinstance(threshold, dict):
        return True, None
    declared = threshold.get('unit')
    if not declared:
        return True, None
    if measurement_unit is None:
        return True, None
    same = str(declared).strip().lower() == str(measurement_unit).strip().lower()
    return same, str(declared)


def compare_threshold(value, threshold):
    """Compare a measured value against a configured threshold.

    Returns ``(ok, detail)``.  ``ok`` is ``None`` when the comparison is not
    possible (non numeric value, threshold without a comparable bound) - the
    caller must then report the verdict as unavailable, never as PASS.
    """
    number = _as_number(value)
    if number is None:
        return None, 'measured value is not numeric'
    if not isinstance(threshold, dict):
        return None, 'threshold is not a bounds mapping'
    bounds = [key for key in ('min', 'max', 'equals') if key in threshold]
    if not bounds:
        return None, 'threshold declares no comparable bound'
    for key in bounds:
        bound = _as_number(threshold[key])
        if bound is None:
            return None, 'threshold bound %r is not numeric' % (key,)
        if key == 'min' and number < bound:
            return False, 'measured %r is below the configured minimum %r' % (value, threshold[key])
        if key == 'max' and number > bound:
            return False, 'measured %r is above the configured maximum %r' % (value, threshold[key])
        if key == 'equals' and number != bound:
            return False, 'measured %r differs from the configured value %r' % (value, threshold[key])
    return True, 'within the configured bounds'


def truthiness(value):
    """Interpret an evidence value as True / False / None (undetermined)."""
    if isinstance(value, bool):
        return value
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        text = value.strip().lower()
        if text in ('true', 'yes', 'pass', 'passed', 'ok', 'verified', 'valid', 'compliant',
                    'success', 'succeeded', 'reproduced', 'identical'):
            return True
        if text in ('false', 'no', 'fail', 'failed', 'not_verified', 'invalid', 'violated',
                    'missing', 'regression', 'regressed', 'degraded'):
            return False
        return None
    if isinstance(value, dict):
        for names in (['status', 'result', 'verdict', 'outcome'], ['ok', 'verified', 'passed'],
                      ['healthy', 'compliant']):
            present, nested = lookup(value, names)
            if present:
                interpreted = truthiness(nested)
                if interpreted is not None:
                    return interpreted
        return None
    if isinstance(value, (list, tuple)):
        return bool(value)
    return None
