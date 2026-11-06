"""Optional rendering helper for the Headquarters evidence readbacks.

The Phase-2 Management / Sales readbacks are attached to the result model by
the coordinator (``result['management_readback']`` and
``result['sales_readback']``, plus ``result['headquarters']['readbacks']``).
This module renders them for ``report.html`` / ``SUMMARY.txt``.

It is deliberately dependency free and defensive: it never raises, and a
missing or malformed readback simply produces no output.  Wiring it into
``common.report()`` is optional - see ``common.py.patch``.
"""
from __future__ import annotations

import html as _html

READBACK_DOMAINS = ('management', 'sales')


def _escape(value):
    try:
        return _html.escape(str(value))
    except Exception:  # pragma: no cover - defensive
        return ''


def _rows(items):
    return ''.join('<tr><td>%s</td><td>%s</td></tr>' % (_escape(key), _escape(value))
                   for key, value in items)


def _measurement_rows(readback):
    rows = []
    for metric in sorted((readback.get('measurements') or {})):
        record = (readback.get('measurements') or {}).get(metric) or {}
        value = record.get('value')
        rows.append((metric, '%s%s [%s]' % (value if value is not None else 'not recorded',
                                            ' ' + str(record.get('unit')) if record.get('unit') else '',
                                            record.get('status', 'UNKNOWN'))))
    return rows


def readback_sections(data):
    """The readback sections found in a result model."""
    sections = []
    if not isinstance(data, dict):
        return sections
    for domain in READBACK_DOMAINS:
        readback = data.get(domain + '_readback')
        if not isinstance(readback, dict):
            continue
        sections.append((domain, readback))
    headquarters = data.get('headquarters')
    if isinstance(headquarters, dict):
        for domain, readback in sorted((headquarters.get('readbacks') or {}).items()):
            if isinstance(readback, dict) and all(existing != domain for existing, _ in sections):
                sections.append((domain, readback))
    return sections


def readback_html(data):
    """HTML for the readbacks of a result model (empty string when there are none)."""
    sections = readback_sections(data)
    if not sections:
        return ''
    parts = ['<section id="hq-readbacks"><h2>Headquarters evidence readbacks</h2>']
    for domain, readback in sections:
        parts.append('<article class="hq-readback" data-domain="%s">' % _escape(domain))
        parts.append('<h3>%s HQ</h3>' % _escape(domain.capitalize()))
        parts.append('<p>status: <b>%s</b> &middot; reason: %s &middot; accepted: %s</p>' % (
            _escape(readback.get('status')), _escape(readback.get('reason_code')),
            'yes' if readback.get('accepted') else 'no'))
        if domain == 'sales':
            audience = readback.get('audience_summary') or {}
            if isinstance(audience, dict) and audience.get('status') == 'GENERATED':
                parts.append('<h4>Audience summary</h4>')
                for entry in audience.get('entries') or []:
                    if not isinstance(entry, dict):
                        continue
                    parts.append('<p><b>What this game asks the player to do:</b> %s</p>' %
                                 _escape(entry.get('what_game')))
                    parts.append('<p><b>Name/IP/price-blind description:</b> %s</p>' %
                                 _escape(entry.get('product_description')))
                parts.append('<p>Readability remains subject to the Sales communication/readability gate.</p>')
        measurements = _measurement_rows(readback)
        if measurements:
            parts.append('<h4>Measurements</h4><table><tr><th>metric</th><th>value</th></tr>%s</table>'
                         % _rows(measurements))
        unavailable = readback.get('unavailable') or []
        if unavailable:
            parts.append('<h4>Unavailable</h4><ul>%s</ul>' % ''.join(
                '<li>%s &mdash; %s</li>' % (_escape(item.get('item')), _escape(item.get('reason_code')))
                for item in unavailable))
        risks = readback.get('risks') or []
        if risks:
            parts.append('<h4>Risks</h4><ul>%s</ul>' % ''.join(
                '<li>[%s] %s</li>' % (_escape(risk.get('severity')), _escape(risk.get('detail')))
                for risk in risks))
        parts.append('</article>')
    parts.append('</section>')
    return ''.join(parts)


def readback_text(data):
    """Plain text rendering of the readbacks."""
    sections = readback_sections(data)
    if not sections:
        return ''
    lines = []
    for domain, readback in sections:
        lines.append('%s HQ: %s (%s)' % (domain.capitalize(), readback.get('status'),
                                         readback.get('reason_code')))
        if domain == 'sales':
            audience = readback.get('audience_summary') or {}
            if isinstance(audience, dict) and audience.get('status') == 'GENERATED':
                for entry in audience.get('entries') or []:
                    if not isinstance(entry, dict):
                        continue
                    lines.append('  what this game asks the player to do: %s' %
                                 (entry.get('what_game') or ''))
                    lines.append('  name/IP/price-blind description: %s' %
                                 (entry.get('product_description') or ''))
                lines.append('  readability: requires Sales communication/readability acceptance')
        for item in readback.get('unavailable') or []:
            lines.append('  unavailable: %s (%s)' % (item.get('item'), item.get('reason_code')))
        for risk in readback.get('risks') or []:
            lines.append('  risk [%s]: %s' % (risk.get('severity'), risk.get('detail')))
    return '\n'.join(lines)


def inject_html(body, data):
    """Insert the readback section into a rendered HTML body."""
    try:
        section = readback_html(data)
    except Exception:  # pragma: no cover - defensive
        return body
    if not section:
        return body
    try:
        if '</body>' in body:
            return body.replace('</body>', section + '</body>')
        return body + section
    except Exception:  # pragma: no cover - defensive
        return body