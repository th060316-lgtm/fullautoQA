"""Install a hash-checked immutable source into a fresh isolated Candidate copy."""
import argparse,hashlib,json,shutil,sys
from pathlib import Path

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--candidate-root',required=True);args=ap.parse_args()
    root=Path(args.candidate_root).resolve();here=Path(__file__).resolve().parent
    meta=json.loads((here/'snapshot.json').read_text(encoding='utf-8'))
    rows=json.loads((here/'source_inventory.json').read_text(encoding='utf-8'))
    actual={p.relative_to(here/'source').as_posix() for p in (here/'source').rglob('*') if p.is_file()}
    if actual!={r['path'] for r in rows}:raise ValueError('SOURCE_FILE_SET_CHANGED')
    for row in rows:
        path=here/'source'/row['path'];data=path.read_bytes()
        blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
        if len(data)!=row['size'] or blob!=row['git_blob_sha']:raise ValueError('FROZEN_SOURCE_CHANGED:'+row['path'])
    dest=root/'GAME/targets/politicstrasport'
    if dest.exists():raise ValueError('TARGET_DESTINATION_NOT_FRESH')
    shutil.copytree(here/'source',dest)
    project=dest/'project.godot';text=project.read_text(encoding='utf-8')
    if text.count('[autoload]')!=1:raise ValueError('AUTOLOAD_AMBIGUOUS')
    project.write_text(text.replace('[autoload]','[autoload]\nFullAutoQAObserver="*res://qa_observer.gd"',1),encoding='utf-8')
    shutil.copy2(here/'observer.gd',dest/'qa_observer.gd');shutil.copy2(here/'adapter.py',dest/'qa_adapter.py')
    profile=json.loads((here/'profile.json').read_text(encoding='utf-8'))
    rel='PROFILES/targets/politicstrasport.json';path=root/rel;path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(profile,ensure_ascii=False,indent=2),encoding='utf-8')
    entry={'id':'politicstrasport-development','kind':'target','profile':rel,'source':profile['source'],'config':rel,
           'requirements':['goal','regression','soak','technical_tests'],
           'required_agents':['Smoke','Goal','Explorer','Random'],
           'required_capabilities':['game_launch','autoplay','screenshots','video','regression','soak','state_log','action_log','target_binding']}
    sys.path.insert(0,str(root/'CORE'))
    from targets import validate_target_profile
    from target_identity import identity_components,sha256_value
    missing=validate_target_profile(profile,entry)
    if missing:raise ValueError('TARGET_CONTRACT_INCOMPLETE:'+','.join(missing))
    target={'schema_version':1,'baseline':None,'targets':[entry]}
    (root/'QA_TARGETS.json').write_text(json.dumps(target,indent=2),encoding='utf-8')
    components=identity_components(root,entry,profile)
    proof={'origin':meta,'original_source_inventory':rows,'profile':profile,'target_manifest':target,
           'instrumentation':{'read_only_observer':'qa_observer.gd','game_side_adapter':'qa_adapter.py','state_mutation_by_observer':False},
           'target_fingerprint':sha256_value(components),'unsupported_features':profile['unsupported_features'],'product_acceptance':'HOLD','human_test':'NOT_RUN'}
    (root/'TARGET_PREPARATION.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2),encoding='utf-8')

if __name__=='__main__':main()
