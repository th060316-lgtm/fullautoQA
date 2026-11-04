"""Read-only source to isolated copy, applying only explicit Profile recipes."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path


def inside(root,rel):
    p=(root/rel).resolve()
    if not p.is_relative_to(root):raise ValueError('RECIPE_PATH_ESCAPE:'+str(rel))
    return p


def inventory(root):
    rows={}
    for p in sorted(root.rglob('*')):
        if p.is_symlink():raise ValueError('SOURCE_SYMLINK_UNSUPPORTED')
        if p.is_file() and not any(x in p.parts for x in ('.godot','.git','__pycache__')):
            rows[p.relative_to(root).as_posix()]=hashlib.sha256(p.read_bytes()).hexdigest()
    return rows


def prepare(source,destination,profile):
    source=Path(source).resolve();destination=Path(destination).resolve()
    if source==destination or source in destination.parents or destination in source.parents:
        raise ValueError('ISOLATED_NONOVERLAPPING_COPY_REQUIRED')
    if destination.exists():raise ValueError('DESTINATION_EXISTS')
    recipe=profile['copy_recipe'];before=inventory(source)
    expected=recipe.get('source_inventory_sha256')
    if expected and hashlib.sha256(json.dumps(before,sort_keys=True,separators=(',',':')).encode()).hexdigest()!=expected:
        raise ValueError('FROZEN_SOURCE_INVENTORY_MISMATCH')
    # Validate all recipe paths before creating anything.
    for row in recipe.get('replace',[]):inside(destination,row['file'])
    for rel in recipe.get('remove',[]):inside(destination,rel)
    shutil.copytree(source,destination,ignore=shutil.ignore_patterns('.git','.godot','__pycache__'))
    for row in recipe.get('replace',[]):
        path=inside(destination,row['file']);text=path.read_text(encoding='utf-8')
        count=text.count(row['old'])
        if count!=row['expected_count']:raise ValueError('RECIPE_MATCH_COUNT:'+row['file'])
        path.write_text(text.replace(row['old'],row['new']),encoding='utf-8')
    for rel in recipe.get('remove',[]):
        p=inside(destination,rel)
        if p.is_dir():shutil.rmtree(p)
        elif p.exists():p.unlink()
    after=inventory(destination)
    if before!=inventory(source):raise RuntimeError('SOURCE_CHANGED')
    return {'source_read_only_unchanged':True,'source_inventory':before,'copy_inventory':after,
        'removed':sorted(set(before)-set(after)),
        'changed':sorted(k for k in after if k in before and before[k]!=after[k]),
        'origin':profile.get('source_origin'),'acceptance':'NOT_RUN'}


if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--profile',required=True);ap.add_argument('--source',required=True)
    ap.add_argument('--destination',required=True);ap.add_argument('--proof',required=True);a=ap.parse_args()
    profile=json.loads(Path(a.profile).read_text(encoding='utf-8'))
    proof=prepare(a.source,a.destination,profile)
    Path(a.proof).write_text(json.dumps(proof,ensure_ascii=False,indent=2),encoding='utf-8')
