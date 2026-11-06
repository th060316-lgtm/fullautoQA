"""Evidence-backed audience/product summary.

This module never invents game content or product quality.  It derives a small,
name/IP/price-blind description only from mechanics already packaged in the
player-review evidence.  Readability remains a separate Sales review gate.
"""
from __future__ import annotations

import re


def _ids(values):
    out = []
    for value in values or []:
        if isinstance(value, dict):
            value = value.get("id") or value.get("goal") or value.get("action")
        if value is None:
            continue
        text = str(value).strip()
        if text and text not in out:
            out.append(text)
    return sorted(out)


def _phrase(values, empty="not established"):
    values = [str(v) for v in values if str(v)]
    if not values:
        return empty
    if len(values) == 1:
        return values[0]
    if len(values) == 2:
        return values[0] + " and " + values[1]
    return ", ".join(values[:-1]) + ", and " + values[-1]


def _plain_term(value):
    # Identifier text is evidence, not prose.  Only make separators readable;
    # never infer a semantic synonym that was not present in the evidence.
    return re.sub(r"\s+", " ", re.sub(r"[_\-]+", " ", str(value))).strip()


def build_audience_summary(player_review_packet, evidence_ref="player_review_packet.json"):
    packet = player_review_packet if isinstance(player_review_packet, dict) else {}
    targets = packet.get("targets") if isinstance(packet.get("targets"), list) else []
    entries = []
    for index, target in enumerate(targets):
        if not isinstance(target, dict):
            continue
        actions = [_plain_term(x) for x in _ids(target.get("actions"))]
        goals = [_plain_term(x) for x in _ids(target.get("goals"))]
        scenarios = [_plain_term(x) for x in _ids(target.get("scenarios"))]
        if not (actions or goals or scenarios):
            continue

        what_game = (
            "The player can use %s. The declared objectives include %s. "
            "The declared play situations include %s."
            % (_phrase(actions), _phrase(goals), _phrase(scenarios))
        )
        product_description = (
            "A game centered on %s, with objectives including %s and play situations including %s."
            % (_phrase(actions), _phrase(goals), _phrase(scenarios))
        )
        entries.append({
            "target_index": index,
            "what_game": what_game,
            "product_description": product_description,
            "mechanics": {
                "actions": actions,
                "goals": goals,
                "scenarios": scenarios,
            },
            "evidence": [evidence_ref],
        })

    status = "GENERATED" if entries else "NOT_RUN"
    return {
        "schema_version": 1,
        "status": status,
        "reason_code": None if entries else "AUDIENCE_MECHANICS_EVIDENCE_ABSENT",
        "entries": entries,
        "evidence": [evidence_ref] if entries else [],
        "description_contract": {
            "basis": ["actions", "goals", "scenarios"],
            "excluded_metadata": [
                "game_id", "game_name", "title", "ip", "license", "price", "free",
            ],
            "brand_price_independent": True,
            "quality_claimed": False,
            "human_readability_claimed": False,
        },
    }


def render_audience_summary(summary):
    summary = summary if isinstance(summary, dict) else {}
    lines = [
        "AUDIENCE SUMMARY",
        "This is an evidence-backed mechanics summary, not a human satisfaction or product-acceptance verdict.",
        "",
    ]
    if summary.get("status") != "GENERATED":
        lines.append("Status: NOT_RUN (%s)" % (summary.get("reason_code") or "EVIDENCE_ABSENT"))
        return "\n".join(lines) + "\n"
    for i, entry in enumerate(summary.get("entries") or [], 1):
        lines.extend([
            "Target %d" % i,
            "What the player does / what this game is:",
            str(entry.get("what_game") or ""),
            "",
            "Name/IP/price-blind product description:",
            str(entry.get("product_description") or ""),
            "",
        ])
    lines.extend([
        "Evidence basis: " + ", ".join(summary.get("evidence") or []),
        "Readability must still be judged by the independent Sales communication/readability gate.",
    ])
    return "\n".join(lines) + "\n"
