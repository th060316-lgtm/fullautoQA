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


def starter_profile(game_id, launch_argv, source=None):
    """Generate an unvalidated, unbound draft. Gameplay still needs authoring."""
    if not isinstance(game_id,str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*',game_id):
        raise ValueError('INTAKE_GAME_ID_INVALID')
    if not isinstance(launch_argv,list) or not launch_argv or any(not isinstance(x,str) or not x for x in launch_argv):
        raise ValueError('INTAKE_LAUNCH_ARGV_INVALID')
    return {'schema_version':1,'game_id':game_id,'game_version':'UNVERIFIED',
        'profile_version':'draft-1','prototype_type':'playable','intake_status':'UNVALIDATED_STARTER',
        'source':source or 'GAME/'+game_id,'launch':{'argv':launch_argv},
        'actions':{'observe':{'inputs':[{'kind':'wait','duration':1}]}},'goals':[],
        'scenarios':[{'id':'startup','agent':'Smoke','sequence':['observe'],'action_budget':1,'time_budget':10}],
        'tests':[],'observations':['window','screenshot','process'],'display':{'kind':'windows'},
        'instructions':'Unvalidated draft. Declare real controls, goals and observations before selection.'}


def select_profile(root, profile_path, target_id=None, replace=False):
    """Select one explicitly supplied target; selection never means acceptance.

    Existing matching target requirements and baseline are preserved. A previous
    selection is replaced only with explicit replace=True. Source and adapter
    deployment remain explicit prerequisites, never inferred from discovery.
    """
    import copy
    from common import inside, read_json, write_json
    from targets import manifest_path, load_target_manifest, validate_target_profile
    from profile import load
    root=Path(root).resolve();origin=Path(profile_path).resolve()
    data=load_and_validate_profile(origin)
    if data.get('intake_status')=='UNVALIDATED_STARTER':raise ValueError('INTAKE_STARTER_NOT_VALIDATED')
    ident=data.get('game_id')
    if not isinstance(ident,str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*',ident):
        raise ValueError('INTAKE_GAME_ID_INVALID')
    settings_path=inside(root,'acceptance_manifest.json')
    settings=read_json(settings_path) if settings_path.is_file() else {}
    manifest=manifest_path(root,settings);existed=manifest.exists()
    if existed and not replace:raise ValueError('INTAKE_SELECTION_EXISTS_USE_REPLACE')
    previous=load_target_manifest(root,settings) if existed else None
    load(root,origin)  # canonical runner schema, no adapter code is executed
    if not data.get('source'):raise ValueError('INTAKE_SOURCE_REQUIRED')
    for key in ('source','adapter','save_directory'):
        if data.get(key) and not inside(root,data[key]).exists():raise ValueError('INTAKE_PATH_MISSING:'+key)
    try:rel=origin.relative_to(root).as_posix();destination=origin
    except ValueError:
        rel='PROFILES/intake/'+ident+'.json';destination=inside(root,rel)
        if destination.exists():raise ValueError('INTAKE_PROFILE_DESTINATION_EXISTS')
    matches=[r for r in (previous or {}).get('targets',[]) if r['profile']==rel]
    entry=copy.deepcopy(matches[0]) if matches else {'id':ident,'kind':'target','profile':rel,
        'source':data['source'],'requirements':[],
        'required_agents':sorted({s['agent'] for s in data['scenarios']})}
    if target_id is not None:
        if not isinstance(target_id,str) or not target_id.strip():raise ValueError('TARGET_ID_REQUIRED')
        entry['id']=target_id
    errors=validate_target_profile(data,entry)
    if errors:raise ValueError('INTAKE_TARGET_INVALID:'+','.join(errors))
    selection={'schema_version':1,'targets':[entry]}
    if matches and previous.get('baseline') is not None:selection['baseline']=previous['baseline']
    if destination!=origin:write_json(destination,data)
    write_json(manifest,selection)
    return {'status':'SELECTED_UNRUN','manifest':str(manifest),'profile':rel,'target_id':entry['id'],
        'auto_bound':False,'acceptance':'NOT_RUN','manifest_readback_ok':load_target_manifest(root,settings)==selection,
        'files_created':int(not existed)+int(destination!=origin),'files_written':1+int(destination!=origin),
        'profile_copied':destination!=origin,'existing_contract_preserved':bool(matches)}


def main(argv=None):
    import argparse
    from common import inside, write_json
    ap=argparse.ArgumentParser(description='Explicit Target/Profile intake; selection is not QA acceptance.')
    ap.add_argument('--root',default=str(Path(__file__).resolve().parents[1]))
    sub=ap.add_subparsers(dest='command',required=True)
    d=sub.add_parser('discover');d.add_argument('--search',action='append',required=True)
    s=sub.add_parser('starter');s.add_argument('--game-id',required=True);s.add_argument('--launch-json',required=True)
    s.add_argument('--source');s.add_argument('--output')
    b=sub.add_parser('select');b.add_argument('--profile',required=True);b.add_argument('--target-id');b.add_argument('--replace',action='store_true')
    args=ap.parse_args(argv)
    if args.command=='discover':result=summarize_discovered(args.search)
    elif args.command=='starter':
        data=starter_profile(args.game_id,json.loads(args.launch_json),args.source)
        dest=inside(args.root,args.output or 'PROFILES/intake/'+args.game_id+'.json')
        if dest.exists():raise ValueError('INTAKE_PROFILE_DESTINATION_EXISTS')
        write_json(dest,data);result={'status':'UNVALIDATED_STARTER','profile':str(dest),'bound':False,'acceptance':'NOT_RUN','files_created':1}
    else:result=select_profile(args.root,args.profile,args.target_id,args.replace)
    print(json.dumps(result,ensure_ascii=False,indent=2));return 0


if __name__=='__main__':raise SystemExit(main())
