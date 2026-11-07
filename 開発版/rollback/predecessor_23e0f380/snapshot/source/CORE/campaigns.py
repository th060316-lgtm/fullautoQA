"""Profile-owned campaigns shared by native Windows and transport validation."""
import copy,math
from common import inside,write_json
from plans import fault_plan,scenario_by_id
from regression import load_baseline

def soak_scenario(profile,seconds=None):
    cfg=copy.deepcopy(profile.get('qa_plan',{}).get('soak'))
    if not cfg:return None
    if seconds is not None:cfg['seconds']=seconds
    duration=cfg.get('seconds',0);loops=cfg.get('loops',0)
    if not all(math.isfinite(x) and x>=0 for x in (duration,loops)) or not (duration or loops):raise ValueError('SOAK_TARGET_REQUIRED')
    if cfg.get('memory_limit',1024)<16 or cfg.get('action_budget',2147483647)<1:raise ValueError('SOAK_BUDGET_INVALID')
    return {'id':'__qa_soak','agent':cfg.get('agent','Random'),'soak':True,'soak_seconds':duration,'soak_loops':loops,'time_budget':cfg.get('max_seconds',max(duration+30,duration*1.25,60)),'action_budget':cfg.get('action_budget',2147483647),'stop_on_goal':False,'memory_limit':cfg.get('memory_limit',1024),'observation_delay':cfg.get('observation_delay',.06),'screenshot_interval':cfg.get('screenshot_interval',60)}

def soak_complete(elapsed,actions,scenario,alive):return bool(alive and elapsed>=scenario.get('soak_seconds',0) and actions>=scenario.get('soak_loops',0))

def fault_detected(rows,expected):
    return any(r['status']==expected['status'] and r['reason_code']==expected['reason'] for r in rows) and not any(r['status']=='HARNESS_ERROR' and not (expected['status']=='HARNESS_ERROR' and r['reason_code']==expected['reason']) for r in rows)

def validate_campaigns(p):
    plan=p.get('qa_plan',{});reg=plan.get('regression')
    if reg:
        scenario_by_id(p,reg['scenario'])
        if not reg.get('state_fields') or len(set(reg['state_fields']))!=len(reg['state_fields']):raise ValueError('REGRESSION_FIELDS_REQUIRED_UNIQUE')
        for m in reg.get('visual_masks',[]):
            if len(m)!=4 or not all(math.isfinite(v) and 0<=v<=1 for v in m) or m[0]>=m[2] or m[1]>=m[3]:raise ValueError('VISUAL_MASK_SCHEMA')
        if not 0<=reg.get('visual_tolerance',.08)<=1:raise ValueError('VISUAL_TOLERANCE_SCHEMA')
    if plan.get('soak'):soak_scenario(p)
    configs=fault_plan(p)
    if len({c['id'] for c in configs})!=len(configs):raise ValueError('DUPLICATE_FAULT_ID')
    for cfg in configs:
        s=cfg['scenario']
        if any(a in p.get('forbidden_actions',[]) for a in s.get('sequence',[])):raise ValueError('FORBIDDEN_FAULT_ACTION')
        if not math.isfinite(s.get('time_budget',60)) or s.get('time_budget',60)<=0:raise ValueError('FAULT_TIME_BUDGET_INVALID')

def inject_faults(session,seed):
    original=session.p
    try:
        for cfg in fault_plan(original):
            session.p=copy.deepcopy(original);session.p['actions'].update(cfg.get('actions',{}));session.p['launch']['extra_args']=session.p['launch'].get('extra_args',[])+cfg.get('args',[])
            s=copy.deepcopy(cfg['scenario']);s.update(id='__qa_fault_'+cfg['id'],fault_injection=True,recovery_attempts=cfg.get('recovery_attempts',0))
            if cfg.get('missing_asset'):s['missing_asset']=cfg['missing_asset']
            if cfg.get('baseline_scenario'):s.update(regression_key=cfg['baseline_scenario'],compare_baseline=True)
            first=len(session.results);session.run_scenario(s,seed);rows=session.results[first:]
            for row in rows:row.update(gate='INFORMATIONAL',expected_fault=cfg['id'])
            matched=fault_detected(rows,cfg['expected']);name=original['game_id']+'_fault_'+cfg['id']+'.json';write_json(session.e.root/name,{'configuration':cfg,'expected':cfg['expected'],'detected':matched,'raw_verdicts':rows});session.verdict(original['game_id']+'.detector.'+cfg['id'],'PASS' if matched else 'FAIL','KNOWN_FAULT_DETECTED' if matched else 'KNOWN_FAULT_MISSED',[name])
    finally:session.p=original

def execute_plans(session,seed,options=None):
    options=options or {};p=session.p;plan=p.get('qa_plan',{});reg=plan.get('regression')
    if reg:
        original=scenario_by_id(p,reg['scenario']);key=original['id']
        if session.imported_baselines:base=inside(session.imported_baselines,p['game_id']+'/'+key)
        else:
            session.run_scenario(dict(original,id='__qa_baseline',regression_key=key,export_baseline=True,save_load=False,evaluation=False,retry_test=False),seed);base=inside(session.e.root,'baseline_exports/'+p['game_id']+'/'+key)
        try:
            reference=load_baseline(base,p,key,seed);session.comparison_baselines[(p['game_id'],key)]=base
            session.run_scenario(dict(original,id='__qa_regression',regression_key=key,compare_baseline=True,save_load=False,evaluation=False,retry_test=False),seed,replay=reference['actions'])
        except Exception as ex:
            name=p['game_id']+'_baseline_error.json';write_json(session.e.root/name,{'error':repr(ex)});session.verdict(p['game_id']+'.baseline','HARNESS_ERROR','BASELINE_UNAVAILABLE_OR_INCOMPATIBLE',[name])
    else:session.verdict(p['game_id']+'.regression_plan','NOT_RUN','NO_PROFILE_REGRESSION_PLAN')
    soak=soak_scenario(p,options.get('soak_seconds'))
    if soak:session.run_scenario(soak,seed)
    else:session.verdict(p['game_id']+'.soak_plan','NOT_RUN','NO_PROFILE_SOAK_PLAN')
    if options.get('faults',plan.get('faults_enabled',True)):
        if fault_plan(p):inject_faults(session,seed)
        else:session.verdict(p['game_id']+'.fault_suite','NOT_RUN','NO_PROFILE_FAULT_CONTRACT')
    else:session.verdict(p['game_id']+'.fault_suite','NOT_RUN','FAULT_SUITE_DISABLED_BY_CONFIGURATION')
