"""Freeze declared case obligations BEFORE executing a Profile; never infer from results."""
from collections import Counter
from common import write_json,overall
from campaigns import soak_scenario
from plans import scenario_by_id,fault_plan

def validate_profile_references(p):
    scenarios=p.get('scenarios',[]);goals=p.get('goals',[]);tests=p.get('tests',[])
    ids=[s['id'] for s in scenarios];goal_ids=[g.get('id') for g in goals]
    if not scenarios or len(ids)!=len(set(ids)):raise ValueError('DUPLICATE_OR_EMPTY_SCENARIOS')
    if None in goal_ids or len(goal_ids)!=len(set(goal_ids)):raise ValueError('DUPLICATE_OR_INVALID_GOAL_ID')
    for s in scenarios:
        if s.get('goal') is not None and s['goal'] not in goal_ids:raise ValueError('UNKNOWN_SCENARIO_GOAL:'+str(s['goal']))
        if s.get('save_load') and not p.get('save'):raise ValueError('SAVE_CONTRACT_REQUIRED')
    seen=set()
    for test in tests:
        key=(test.get('scenario'),test.get('id'))
        if not test.get('id') or test.get('scenario') not in ids:raise ValueError('UNKNOWN_TEST_SCENARIO')
        if key in seen:raise ValueError('DUPLICATE_TEST_ID')
        seen.add(key)
        if not isinstance(test.get('expect'),dict) or not test['expect'].get('field'):raise ValueError('TEST_EXPECTATION_REQUIRED')

def profile_plan(p,options=None,imported=False):
    validate_profile_references(p);options=options or {};rows=[];game=p['game_id']
    def add(case,gate='REQUIRED'):rows.append({'test_case':case,'gate':gate})
    def scenario(s):
        base=game+'.'+s['id'];add(base+'.launch');add(base+('.goal' if s.get('goal') else '.execution'))
        if s.get('save_load'):
            add(base+'.save_load')
            if p['save'].get('invalid_expected'):add(base+'.invalid_save')
        if s.get('retry_test'):add(base+'.retry')
        if s.get('soak'):add(base+'.soak')
        for test in p.get('tests',[]):
            if test['scenario']==s['id']:add(base+'.'+test['id'],test.get('gate','REQUIRED'))
    add(game+'.source');add(game+'.assets');add(game+'.build','REQUIRED' if p.get('build') else 'OPTIONAL')
    for t in p.get('technical_tests',[]):add(game+'.'+t['id'],t.get('gate','REQUIRED'))
    for s in p['scenarios']:
        scenario(s)
        if s.get('verify_seed_replay'):
            scenario(dict(s,id=s['id']+'_seed_replay'));add(game+'.seed_replay')
    plan=p.get('qa_plan',{});reg=plan.get('regression')
    if reg:
        original=scenario_by_id(p,reg['scenario'])
        if not imported:scenario(dict(original,id='__qa_baseline',save_load=False,retry_test=False))
        scenario(dict(original,id='__qa_regression',save_load=False,retry_test=False))
        for kind in ('behavioral_regression','visual_regression'):add(game+'.__qa_regression.'+kind)
        add(game+'.__qa_regression.performance_regression','REQUIRED' if reg.get('performance_limits') else 'OPTIONAL')
    soak=soak_scenario(p,options.get('soak_seconds'))
    if soak:scenario(soak)
    if options.get('faults',plan.get('faults_enabled',True)):
        for fault in fault_plan(p):add(game+'.detector.'+fault['id'])
    counts=Counter(r['test_case'] for r in rows)
    if any(n>1 for n in counts.values()):raise ValueError('EXPECTED_CASE_ID_COLLISION')
    if any(r['gate'] not in ('REQUIRED','OPTIONAL') for r in rows):raise ValueError('EXPECTED_GATE_INVALID')
    return rows

def audit_plan(e,results,plan,proof_name):
    """Required NOT_RUN remains required. Repeated diagnostics outside the plan are allowed."""
    missing=[];duplicates=[]
    for obligation in plan:
        matches=[r for r in results if r['test_case']==obligation['test_case'] and not r.get('expected_fault')]
        for r in matches:r['gate']=obligation['gate']
        if not matches:
            missing.append(obligation['test_case']);results.append(e.result(obligation['test_case'],'NOT_RUN','DECLARED_CASE_NOT_EXECUTED',[proof_name],gate=obligation['gate']))
        elif len(matches)>1 and obligation['gate']=='REQUIRED':duplicates.append(obligation['test_case'])
    if duplicates:
        results.append(e.result(proof_name+'.duplicates','HARNESS_ERROR','DUPLICATE_REQUIRED_CASE',[proof_name],duplicates=duplicates,gate='REQUIRED'))
    return {'missing':missing,'duplicates':duplicates,'required':[r['test_case'] for r in plan if r['gate']=='REQUIRED']}

def prototype_summary(sessions,results):
    prefixes=tuple(s.p['game_id']+'.' for s in sessions)
    global_rows=[r for r in results if not r['test_case'].startswith(prefixes)] if prefixes else list(results)
    output={}
    for kind in ('logic','playable'):
        chosen=[s for s in sessions if s.p['prototype_type']==kind]
        if not chosen:output[kind]={'status':'NOT_RUN','reason_code':'NO_PROFILE_SELECTED','profiles':[]};continue
        rows=global_rows+[r for s in chosen for r in results if r['test_case'].startswith(s.p['game_id']+'.')]
        output[kind]={'status':overall(rows),'profiles':[{'game_id':s.p['game_id'],'game_version':s.p['game_version'],'profile_version':s.p['profile_version'],'source':s.p.get('source')} for s in chosen]}
    return output
