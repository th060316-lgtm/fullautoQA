"""Install this selected target snapshot into a validated fresh Candidate.
Original game files stay untouched. Instrumentation is recorded separately.
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('--candidate-root', required=True)
ns = ap.parse_args()
root = Path(ns.candidate_root).resolve()
here = Path(__file__).resolve().parent
meta = json.loads((here / 'snapshot.json').read_text(encoding='utf-8'))
dest = root / 'GAME/targets/codegeas'
if dest.exists():
    raise SystemExit('TARGET_DESTINATION_NOT_FRESH')
shutil.copytree(here / 'source', dest)
original_rows = []
for path in sorted(dest.rglob('*')):
    if path.is_file():
        original_rows.append({'path': path.relative_to(dest).as_posix(), 'size': path.stat().st_size,
                              'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
project = dest / 'project.godot'
text = project.read_text(encoding='utf-8')
match = re.search(r'^config/name="([^"]+)"', text, re.M)
if not match or text.count('[autoload]') != 1:
    raise SystemExit('PROJECT_IDENTITY_OR_AUTOLOAD_AMBIGUOUS')
app_name = match.group(1)
if any(c in app_name for c in '/\\:'):
    raise SystemExit('UNSAFE_APP_NAME')
text = text.replace('[autoload]', '[autoload]\nFullAutoQAObserver="*res://qa_observer.gd"', 1)
project.write_text(text, encoding='utf-8')
shutil.copy2(here / 'observer.gd', dest / 'qa_observer.gd')
shutil.copy2(here / 'save_observer.gd', dest / 'qa_save_observer.gd')
scene = dest / 'scenes/Main.tscn'
scene_text = scene.read_text(encoding='utf-8')
if scene_text.count('path="res://save/SaveManager.gd"') != 1:
    raise SystemExit('SAVE_OBSERVER_BINDING_AMBIGUOUS')
scene.write_text(scene_text.replace('path="res://save/SaveManager.gd"', 'path="res://qa_save_observer.gd"', 1), encoding='utf-8')
profile = json.loads((here / 'profile.json').read_text(encoding='utf-8'))
profile['save']['file'] = 'isolated_user/APPDATA/Godot/app_userdata/' + app_name + '/saves/slot1.json'
# The declared storage location is derived from the target's own identity
# (the Godot application name) so it can never drift away from where the game
# actually writes its save.  When the checked-in profile already declares a
# location, it MUST agree with the derived one: a silent substitution would
# hide an unobservable required storage contract.
derived_locations = ['APPDATA/Godot/app_userdata/' + app_name + '/saves']
declared_locations = list((profile.get('storage') or {}).get('locations') or [])
if declared_locations and declared_locations != derived_locations:
    raise SystemExit('STORAGE_LOCATION_DECLARATION_DIVERGES_FROM_TARGET_IDENTITY')
profile['storage']['locations'] = derived_locations
profile['storage']['required'] = True
profile_path = root / 'PROFILES/targets/codegeas.json'
profile_path.parent.mkdir(parents=True, exist_ok=True)
profile_path.write_text(json.dumps(profile, ensure_ascii=False, indent=2), encoding='utf-8')
target = {'schema_version': 1, 'baseline': None, 'targets': [{
    'id': 'codegeas-development', 'kind': 'target', 'profile': 'PROFILES/targets/codegeas.json',
    'source': 'GAME/targets/codegeas', 'config': 'PROFILES/targets/codegeas.json',
    'requirements': ['goal', 'save_load', 'regression', 'soak', 'technical_tests', 'player_review_evidence'],
    'required_agents': ['Smoke', 'Goal', 'Explorer', 'Random'],
    'required_capabilities': ['game_launch', 'autoplay', 'screenshots', 'video', 'save_load',
                              'regression', 'soak', 'state_log', 'action_log', 'target_binding']}]}
sys.path.insert(0, str(root / 'CORE'))
from targets import validate_target_profile
missing = validate_target_profile(profile, target['targets'][0])
if missing:
    raise SystemExit('TARGET_CONTRACT_INCOMPLETE:' + ','.join(missing))
(root / 'QA_TARGETS.json').write_text(json.dumps(target, indent=2), encoding='utf-8')
proof = {'origin': meta, 'original_source_inventory': original_rows,
         'instrumentation': {'read_only_observer': 'qa_observer.gd', 'autoload_added': 'FullAutoQAObserver', 'save_method_return_observer': 'qa_save_observer.gd'},
         'profile': profile, 'target_manifest': target,
         'product_acceptance': 'HOLD', 'human_test': 'NOT_RUN'}
(root / 'TARGET_PREPARATION.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2), encoding='utf-8')
