"""Phase 3 low-burden Target/Profile intake helpers.

Discovery is advisory only. Binding remains owned by coordinator/target_identity.
The structural schema mirrors CORE/profile.py; no arbitrary discovered file is auto-bound.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

PROFILE_REQUIRED = (
    "game_id","game_version","profile_version","schema_version","prototype_type",
    "launch","actions","goals","scenarios","tests","observations","instructions",
)
_TOOL_TOKEN = re.compile(r"\{([A-Za-z0-9_.-]+)\}")


def _read_json(path):
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


def validate_profile_structure(data):
    if not isinstance(data, dict):
        return ["PROFILE_NOT_OBJECT"]
    errors = ["PROFILE_MISSING_KEY:" + key for key in PROFILE_REQUIRED if key not in data]
    if data.get("schema_version") not in (None, 1):
        errors.append("PROFILE_SCHEMA_INCOMPATIBLE")
    if "prototype_type" in data and data.get("prototype_type") not in ("logic", "playable"):
        errors.append("PROFILE_PROTOTYPE_TYPE")
    if "launch" in data and not isinstance(data.get("launch"), dict):
        errors.append("PROFILE_LAUNCH_NOT_OBJECT")
    if "actions" in data and not isinstance(data.get("actions"), dict):
        errors.append("PROFILE_ACTIONS_NOT_OBJECT")
    if "scenarios" in data and not isinstance(data.get("scenarios"), list):
        errors.append("PROFILE_SCENARIOS_NOT_ARRAY")
    for key in ("tools_required", "tools_optional"):
        value = data.get(key)
        if value is not None and (not isinstance(value, list) or
                                  not all(isinstance(item, str) for item in value)):
            errors.append("PROFILE_%s_INVALID" % key.upper())
    return errors


def discover_profile_files(search_roots, patterns=("*.json",)):
    found, seen = [], set()
    excluded = {
        "tool_manifest.json","python_manifest.json","core_manifest.json",
        "capability_contract.json","git_runtime_manifest.json","acceptance_manifest.json",
        "qa_targets.json","manifest.json",
    }
    for root in search_roots:
        root = Path(root)
        if not root.is_dir():
            continue
        for pattern in patterns:
            for path in sorted(root.rglob(pattern)):
                if not path.is_file() or path.name.lower() in excluded:
                    continue
                try:
                    resolved = str(path.resolve())
                except OSError:
                    continue
                if resolved in seen:
                    continue
                seen.add(resolved)
                found.append(path)
    return found


def load_and_validate_profile(path):
    path = Path(path)
    if not path.is_file():
        raise ValueError("PROFILE_FILE_MISSING:" + str(path))
    data = _read_json(path)
    errors = validate_profile_structure(data)
    if errors:
        raise ValueError("PROFILE_INVALID:" + ",".join(errors))
    return data


def summarize_discovered(search_roots):
    rows = []
    for path in discover_profile_files(search_roots):
        try:
            data = _read_json(path)
            errors = validate_profile_structure(data)
            rows.append({
                "path": str(path),
                "game_id": data.get("game_id") if isinstance(data, dict) else None,
                "structural_ok": not errors,
                "errors": errors,
                "auto_bound": False,
            })
        except Exception as ex:
            rows.append({"path": str(path), "game_id": None, "structural_ok": False,
                         "errors": ["LOAD_ERROR:" + repr(ex)], "auto_bound": False})
    return rows


def _walk_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _walk_strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _walk_strings(item)


def tool_ids_from_profile(profile, declared_ids=()):
    """Return only tool ids explicitly named or referenced as {tool} tokens.

    This never invents a tool family. It is used before Runtime preparation so a
    profile-referenced tool becomes REQUIRED rather than merely best-effort.
    """
    declared = {str(item) for item in declared_ids}
    required = {str(x) for x in (profile.get("tools_required") or [])}
    for text in _walk_strings({
        "launch": profile.get("launch"),
        "build": profile.get("build"),
        "technical_tests": profile.get("technical_tests"),
        "adapter": profile.get("adapter"),
    }):
        for token in _TOOL_TOKEN.findall(text):
            if token in declared:
                required.add(token)
    return sorted(required)


def optional_tool_ids_from_profile(profile, declared_ids=()):
    declared = {str(item) for item in declared_ids}
    return sorted({str(x) for x in (profile.get("tools_optional") or []) if str(x) in declared})
