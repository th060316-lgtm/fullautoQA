"""Versioned data-only contract. Game adapters are explicitly trusted game code."""
from common import inside,read_json
REQUIRED=('game_id','game_version','profile_version','schema_version','prototype_type','launch','actions','goals','scenarios','tests','observations','instructions')
GOALS=('reach','survive','acquire','defeat','build','produce','transport','select','finish_dialogue','finish_turn','reach_score','reach_resource','trigger_event','save_successfully','load_successfully')
OPS=('eq','ne','gt','ge','lt','le','contains','exists')
def load(root,path):
    p=read_json(path)
    missing=[k for k in REQUIRED if k not in p]
    if missing:raise ValueError('PROFILE_REQUIRED:'+','.join(missing))
    if p['schema_version']!=1:raise ValueError('PROFILE_SCHEMA_INCOMPATIBLE; no automatic lossy migration')
    if p['prototype_type'] not in ('logic','playable'):raise ValueError('PROFILE_PROTOTYPE_TYPE')
    if not p['actions'] or not p['scenarios']:raise ValueError('PROFILE_EMPTY')
    for k,a in p['actions'].items():
        if k in p.get('forbidden_actions',[]):raise ValueError('FORBIDDEN_ACTION:'+k)
        for x in a.get('inputs',[]):
            if x.get('kind') not in ('key','hold','combo','text','click','double_click','move','drag','wheel','wait'):raise ValueError('INPUT_KIND')
            if not 0<=x.get('duration',0)<=60:raise ValueError('INPUT_DURATION')
    for g in p['goals']:
        if g['type'] not in GOALS or g['op'] not in OPS:raise ValueError('GOAL_SCHEMA')
    for s in p['scenarios']:
        if s['agent'] not in ('Smoke','Goal','Explorer','Random'):raise ValueError('AGENT_SCHEMA')
        if s.get('action_budget',100)<1 or not 0<s.get('time_budget',60)<=86400:raise ValueError('BUDGET_SCHEMA')
        if any(a not in p['actions'] for a in s.get('sequence',[])):raise ValueError('UNKNOWN_ACTION')
    for k in ('source','save_directory'):
        if p.get(k):inside(root,p[k])
    from observations import validate_profile_observation_sources
    validate_profile_observation_sources(p)
    return p

def get(state,path):
    x=state
    for k in path.split('.'):
        if not isinstance(x,dict) or k not in x:return None
        x=x[k]
    return x

def condition(state,c):
    a=get(state,c['field']); b=c.get('value'); op=c.get('op','eq')
    if op=='exists':return (a is not None)==bool(c.get('value',True))
    if a is None:return False
    try:
        if op=='eq':return a==b
        if op=='ne':return a!=b
        if op=='gt':return a>b
        if op=='ge':return a>=b
        if op=='lt':return a<b
        if op=='le':return a<=b
        if op=='contains':return b in a
    except TypeError:return False
    return False
