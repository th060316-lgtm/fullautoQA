"""QA tasks are selected from profile contracts, never from game IDs or list order."""
import copy

def scenario_by_id(profile,identifier):
    scenario=next((s for s in profile['scenarios'] if s['id']==identifier),None)
    if scenario is None:raise ValueError('QA_SCENARIO_NOT_DECLARED:'+str(identifier))
    return copy.deepcopy(scenario)
def goal_scenario(profile):
    return next((copy.deepcopy(s) for s in profile['scenarios'] if s.get('goal')),None)
def fault_plan(profile):
    configs=profile.get('qa_plan',{}).get('faults',[])
    for config in configs:
        if not config.get('id') or not config.get('scenario') or not config.get('expected'):raise ValueError('FAULT_CONTRACT_INCOMPLETE')
        if config['expected']['status'] not in ('FAIL','HARNESS_ERROR'):raise ValueError('FAULT_MUST_EXPECT_FAILURE')
        actions={**profile['actions'],**config.get('actions',{})}
        if any(a not in actions for a in config['scenario'].get('sequence',[])):raise ValueError('FAULT_ACTION_NOT_DECLARED')
    return copy.deepcopy(configs)
