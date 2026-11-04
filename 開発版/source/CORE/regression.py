"""Hashed, portable, offline baselines: behavior, trajectory, visual, resources."""
import math,shutil,zipfile
from pathlib import Path
from common import inside,read_json,write_json,digest
from adapters import image_features
from profile import get

def selected(state,fields):
    output={}
    for key in fields:
        value=get(state,key)
        if value is None:raise ValueError('REGRESSION_STATE_FIELD_UNAVAILABLE:'+key)
        output[key]=value
    return output

def masked_distance(left,right,masks=()):
    a=image_features(left);b=image_features(right);differences=[]
    for y in range(32):
        for x in range(48):
            if any(m[0]<=(x+.5)/48<=m[2] and m[1]<=(y+.5)/32<=m[3] for m in masks):continue
            i=(y*48+x)*3;differences.extend(abs(a[j]-b[j]) for j in range(i,i+3))
    if not differences:raise ValueError('VISUAL_MASK_REMOVES_ALL_PIXELS')
    return sum(differences)/(255*len(differences))

def export_baseline(root,p,scenario,seed,state,actions,transitions,performance,screenshot,scope,target_identity=None):
    root=Path(root);root.mkdir(parents=True,exist_ok=True);fields=p['qa_plan']['regression']['state_fields'];data={'schema_version':1,'game_id':p['game_id'],'game_version':p['game_version'],'profile_version':p['profile_version'],'scenario':scenario,'seed':seed,'fields':fields,'state':selected(state,fields),'actions':list(actions),'transitions':[selected(x,fields) for x in transitions],'performance':performance,'scope':scope,'human_approved':False}
    if target_identity is not None:data['target_identity']=target_identity.to_dict() if hasattr(target_identity,'to_dict') else dict(target_identity)
    write_json(root/'checkpoint.json',data);shutil.copy2(screenshot,root/'screen.bmp');write_json(root/'bundle.json',{'schema_version':1,'files':[{'path':name,'size':(root/name).stat().st_size,'sha256':digest(root/name)} for name in ('checkpoint.json','screen.bmp')]});return data

def load_baseline(root,p,scenario,seed,identity=None,identity_root=None,settings=None):
    root=Path(root);m=read_json(root/'bundle.json')
    if m.get('schema_version')!=1:raise ValueError('BASELINE_SCHEMA_INCOMPATIBLE')
    if len(m['files'])!=2 or {f['path'] for f in m['files']}!={'checkpoint.json','screen.bmp'}:raise ValueError('BASELINE_FILE_SET')
    for f in m['files']:
        path=inside(root,f['path'])
        if not path.is_file() or path.stat().st_size!=f['size'] or digest(path)!=f['sha256']:raise ValueError('BASELINE_HASH_MISMATCH')
    data=read_json(root/'checkpoint.json')
    if data.get('schema_version')!=1:raise ValueError('BASELINE_SCHEMA_INCOMPATIBLE')
    if data['game_id']!=p['game_id'] or data['scenario']!=scenario or data['seed']!=seed:raise ValueError('BASELINE_IDENTITY_MISMATCH')
    if identity is not None:
        from target_identity import check_baseline_reuse
        violations=check_baseline_reuse(identity,data.get('target_identity'),root=identity_root,settings=settings)
        if violations:raise ValueError('BASELINE_BINDING_REJECTED:'+','.join(violations))
    if data['fields']!=p['qa_plan']['regression']['state_fields']:raise ValueError('BASELINE_FIELDS_INCOMPATIBLE')
    return data

def import_baseline(source,evidence_root):
    source=Path(source).resolve();dst=Path(evidence_root)/'IMPORTED_BASELINES'
    if dst.exists():raise ValueError('BASELINE_IMPORT_ALREADY_EXISTS')
    if source.is_file():
        with zipfile.ZipFile(source) as z:
            members=[i for i in z.infolist() if i.filename.startswith('baseline_exports/') and not i.is_dir()]
            if not members:raise ValueError('BASELINE_EXPORT_NOT_FOUND')
            if len(members)>10000 or sum(i.file_size for i in members)>128*1024*1024:raise ValueError('BASELINE_EXPORT_TOO_LARGE')
            for i in members:
                target=inside(dst,i.filename[len('baseline_exports/'):]);target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(z.read(i))
    else:
        exported=source/'baseline_exports' if (source/'baseline_exports').is_dir() else source
        if not exported.is_dir():raise ValueError('BASELINE_SOURCE_NOT_FOUND')
        if any(p.is_symlink() for p in exported.rglob('*')):raise ValueError('BASELINE_SYMLINK_FORBIDDEN')
        shutil.copytree(exported,dst)
    write_json(dst/'provenance.json',{'source':str(source),'sha256':digest(source) if source.is_file() else None,'scope':'USER_SPECIFIED_PREVIOUS_RUN','human_approval_inferred':False});return dst

def equal(a,b,tolerance):
    if isinstance(a,(int,float)) and not isinstance(a,bool) and isinstance(b,(int,float)) and not isinstance(b,bool):return math.isfinite(a) and math.isfinite(b) and abs(a-b)<=tolerance
    return a==b

def compare(baseline,p,state,actions,transitions,performance,left_image,right_image):
    cfg=p['qa_plan']['regression'];actual=selected(state,cfg['state_fields']);tolerance=cfg.get('field_tolerances',{});path=[selected(x,cfg['state_fields']) for x in transitions];old=baseline['transitions'];trajectory_equal=len(old)==len(path) and all(all(equal(v,b[k],tolerance.get(k,0)) for k,v in a.items()) for a,b in zip(old,path));state_equal=all(equal(v,actual[k],tolerance.get(k,0)) for k,v in baseline['state'].items());actions_equal=list(actions)==baseline['actions'];behavior_ok=state_equal and actions_equal and (trajectory_equal or not cfg.get('compare_trajectory',True));distance=masked_distance(left_image,right_image,cfg.get('visual_masks',[]));visual_ok=distance<=cfg.get('visual_tolerance',.08)
    output=[('behavioral_regression','PASS' if behavior_ok else 'FAIL','BASELINE_MATCH' if behavior_ok else 'BEHAVIORAL_REGRESSION',{'baseline_state':baseline['state'],'actual_state':actual,'trajectory_equal':trajectory_equal,'actions_equal':actions_equal}),('visual_regression','PASS' if visual_ok else 'FAIL','VISUAL_WITHIN_TOLERANCE' if visual_ok else 'VISUAL_REGRESSION',{'distance':distance,'tolerance':cfg.get('visual_tolerance',.08),'masks':cfg.get('visual_masks',[])})];details={}
    for key,limit in cfg.get('performance_limits',{}).items():
        old=baseline['performance'].get(key);now=performance.get(key)
        if old is None or now is None:raise ValueError('PERFORMANCE_METRIC_UNAVAILABLE:'+key)
        maximum=limit.get('maximum',old*limit.get('ratio',1.5)+limit.get('absolute_tolerance',0));details[key]={'baseline':old,'actual':now,'maximum':maximum,'ok':now<=maximum}
    if details:
        ok=all(v['ok'] for v in details.values());output.append(('performance_regression','PASS' if ok else 'FAIL','PERFORMANCE_WITHIN_LIMIT' if ok else 'PERFORMANCE_REGRESSION',details))
    else:output.append(('performance_regression','NOT_RUN','PERFORMANCE_LIMITS_NOT_DECLARED',{}))
    return output
