"""Target-game binding and QA requirement contract. Standard library only."""
from __future__ import annotations
from pathlib import Path
from common import inside, read_json

SCHEMA_VERSION = 1
KNOWN_REQUIREMENTS = {
    'goal','save_load','soak','regression','historical_regression',
    'faults','technical_tests','seed_replay','player_review_evidence','build'
}
KNOWN_AGENTS = {'Smoke','Goal','Explorer','Random'}
# Optional per target declaration of the Phase 1 foundation. The kind separates a real
# target from a fixture or a selftest, so a fixture can never certify a real target.
KNOWN_TARGET_KINDS = {'target','fixture','selftest'}
# Optional relative paths that take part in the target identity.
KNOWN_IDENTITY_PATHS = ('source','config','instance_marker')


def manifest_path(root, settings=None):
    settings = settings or {}
    rel = settings.get('paths', {}).get('target_manifest', 'QA_TARGETS.json')
    return inside(root, rel)


def load_target_manifest(root, settings=None):
    path = manifest_path(root, settings)
    if not path.is_file():
        raise ValueError('NO_TARGET_CONFIGURED')
    data = read_json(path)
    if data.get('schema_version') != SCHEMA_VERSION:
        raise ValueError('TARGET_SCHEMA_INCOMPATIBLE')
    targets = data.get('targets')
    if not isinstance(targets, list) or not targets:
        raise ValueError('TARGETS_EMPTY')
    ids = []
    profiles = []
    for row in targets:
        if not isinstance(row, dict):
            raise ValueError('TARGET_ENTRY_INVALID')
        ident = row.get('id')
        rel = row.get('profile')
        if not isinstance(ident, str) or not ident.strip():
            raise ValueError('TARGET_ID_REQUIRED')
        if not isinstance(rel, str) or not rel.strip():
            raise ValueError('TARGET_PROFILE_REQUIRED:'+ident)
        inside(root, rel)
        kind = row.get('kind')
        if kind is not None and kind not in KNOWN_TARGET_KINDS:
            raise ValueError('TARGET_KIND_INVALID:'+ident)
        for key in KNOWN_IDENTITY_PATHS:
            value = row.get(key)
            if value is None: continue
            if not isinstance(value,str) or not value.strip():
                raise ValueError('TARGET_PATH_INVALID:'+ident)
            inside(root, value)
        caps = row.get('required_capabilities')
        if caps is not None and (not isinstance(caps,list) or any(not isinstance(c,str) or not c.strip() for c in caps)):
            raise ValueError('TARGET_CAPABILITY_INVALID:'+ident)
        if caps is not None and len(caps) != len(set(caps)):
            raise ValueError('TARGET_CAPABILITY_DUPLICATE:'+ident)
        req = row.get('requirements', [])
        if not isinstance(req, list) or any(x not in KNOWN_REQUIREMENTS for x in req):
            raise ValueError('TARGET_REQUIREMENT_UNKNOWN:'+ident)
        if len(req) != len(set(req)):
            raise ValueError('TARGET_REQUIREMENT_DUPLICATE:'+ident)
        agents = row.get('required_agents')
        if agents is not None:
            if not isinstance(agents, list) or not agents or any(x not in KNOWN_AGENTS for x in agents):
                raise ValueError('TARGET_AGENT_INVALID:'+ident)
            if len(agents) != len(set(agents)):
                raise ValueError('TARGET_AGENT_DUPLICATE:'+ident)
        ids.append(ident); profiles.append(rel)
    if len(ids) != len(set(ids)):
        raise ValueError('TARGET_ID_DUPLICATE')
    if len(profiles) != len(set(profiles)):
        raise ValueError('TARGET_PROFILE_DUPLICATE')
    baseline = data.get('baseline')
    if baseline is not None:
        if not isinstance(baseline, str) or not baseline.strip():
            raise ValueError('TARGET_BASELINE_INVALID')
        inside(root, baseline)
    return data


def selected_profiles(manifest):
    return [row['profile'] for row in manifest['targets']]


def entry_for_profile(manifest, rel):
    matches = [row for row in manifest['targets'] if row['profile'] == rel]
    if len(matches) != 1:
        raise ValueError('TARGET_PROFILE_BINDING_MISSING:'+rel)
    return matches[0]


def required_agents(profile, entry):
    explicit = entry.get('required_agents')
    if explicit:
        return set(explicit)
    return {s.get('agent') for s in profile.get('scenarios', []) if s.get('agent') in KNOWN_AGENTS}


def target_kind(profile, entry):
    """Kind of a target declaration: 'target', 'fixture' or 'selftest'.

    A fixture/selftest profile cannot be relabelled as a real target by its manifest.
    An explicit fixture/selftest entry also narrows an otherwise real profile.
    """
    role = (profile or {}).get('qa_role')
    if role in ('selftest','fixture'):
        return role
    kind = (entry or {}).get('kind')
    if kind:
        return kind
    return 'target'


def _has_goal(profile):
    return bool(profile.get('goals')) and any(s.get('goal') for s in profile.get('scenarios', []))


def _has_save_load(profile):
    return bool(profile.get('save')) and any(s.get('save_load') for s in profile.get('scenarios', []))


def _has_seed_replay(profile):
    return any(s.get('verify_seed_replay') for s in profile.get('scenarios', []))


def requirement_coverage(profile, entry):
    plan = profile.get('qa_plan', {})
    mapping = {
        'goal': _has_goal(profile),
        'save_load': _has_save_load(profile),
        'soak': bool(plan.get('soak')),
        'regression': bool(plan.get('regression')),
        'historical_regression': bool(plan.get('regression')),
        'faults': bool(plan.get('faults')),
        'technical_tests': bool(profile.get('tests') or profile.get('technical_tests')),
        'seed_replay': _has_seed_replay(profile),
        'player_review_evidence': profile.get('prototype_type') == 'playable' and bool(profile.get('instructions')) and _has_goal(profile),
        'build': bool(profile.get('build')),
    }
    requested = list(entry.get('requirements', []))
    return {key: bool(mapping[key]) for key in requested}


def validate_target_profile(profile, entry):
    if profile.get('qa_role') == 'selftest':
        return ['SELFTEST_PROFILE_CANNOT_BE_TARGET']
    kind = target_kind(profile, entry)
    if kind == 'selftest':
        return ['SELFTEST_PROFILE_CANNOT_BE_TARGET']
    if kind == 'fixture':
        return ['FIXTURE_PROFILE_CANNOT_BE_TARGET']
    coverage = requirement_coverage(profile, entry)
    missing = [key for key, ok in coverage.items() if not ok]
    agents = required_agents(profile, entry)
    if not agents:
        missing.append('NO_REQUIRED_AGENT')
    return missing


def baseline_source(root, manifest, cli_value=None):
    if cli_value:
        return Path(cli_value).resolve()
    rel = manifest.get('baseline') if manifest else None
    return inside(root, rel) if rel else None


def target_scope_satisfied(run_mode, sessions, entries, contracts):
    if run_mode != 'target' or not sessions:
        return False
    for session in sessions:
        game_id = session.p['game_id']
        entry = entries.get(game_id)
        if not entry:
            return False
        if contracts.get(game_id, {}).get('missing'):
            return False
        if not required_agents(session.p, entry) <= set(session.coverage.get('agents', set())):
            return False
    return True
