"""Required read-only assets are distinct from declared writable runtime outputs."""
import fnmatch,re,shutil
from pathlib import Path
from common import inside

def runtime_paths(profile):
    paths=[]
    for key in ('generated_paths','save_paths','runtime_outputs'):
        value=profile.get(key,[])
        if isinstance(value,str):value=[value]
        paths.extend(value)
    save=profile.get('save')
    if isinstance(save,dict) and save.get('file'):paths.append(save['file'])
    bridge=profile.get('bridge')
    if isinstance(bridge,str):paths.append(bridge)
    observations=profile.get('observations',{})
    if isinstance(observations,dict) and observations.get('bridge'):paths.append(observations['bridge'])
    display=profile.get('display',{})
    if display.get('endpoint'):paths.append(display['endpoint'])
    return sorted(set(p.removeprefix('res://').replace('\\','/') for p in paths))

def generated(rel,patterns):
    rel=rel.removeprefix('res://').replace('\\','/')
    return any(fnmatch.fnmatchcase(rel,p) or rel.startswith(p.rstrip('/')+'/') for p in patterns)

def inspect_assets(work,profile):
    work=Path(work);outputs=runtime_paths(profile);required={x.removeprefix('res://').replace('\\','/') for x in profile.get('required_assets',[])};references=set()
    # Resource text formats contain actual resource references. Arbitrary GDScript
    # strings (including globalize_path and FileAccess output paths) are not imports.
    for path in work.rglob('*'):
        if not path.is_file():continue
        rel=path.relative_to(work).as_posix()
        if generated(rel,outputs):continue
        if path.suffix in ('.tscn','.tres','.godot'):
            references.update(re.findall(r'res://([^"\n]+)',path.read_text(encoding='utf-8',errors='replace')))
        elif path.suffix=='.gd':
            text=path.read_text(encoding='utf-8',errors='replace')
            references.update(re.findall(r'\b(?:preload|load|ResourceLoader\s*\.\s*load)\s*\(\s*[\"\x27]res://([^\"\x27\n]+)',text))
    missing=[];excluded=[]
    for rel in sorted(required|references):
        rel=rel.removeprefix('res://')
        if rel not in required and generated(rel,outputs):excluded.append(rel);continue
        if not inside(work,rel).is_file():missing.append(rel)
    return {'missing':missing,'required_assets':sorted(required),'resource_references':sorted(references),'runtime_outputs':outputs,'excluded_generated_references':excluded}

def copy_game(source,destination,profile,ignore=()):
    source=Path(source);outputs=runtime_paths(profile)
    def ignored(folder,names):
        prefix=Path(folder).relative_to(source)
        return [n for n in names if n in ignore or generated((prefix/n).as_posix(),outputs)]
    return shutil.copytree(source,destination,ignore=ignored)
