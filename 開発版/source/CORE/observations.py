"""Explicit predicate sources: game internals and external measurements stay separate."""
from common import inside
from profile import condition

SOURCES=('internal_state','external_observations')


def condition_source(predicate):
    source=predicate.get('observation_source','internal_state')
    if source not in SOURCES:raise ValueError('OBSERVATION_SOURCE_UNKNOWN:'+str(source))
    return source


def observation_values(observation,predicate,evidence_root=None):
    source=condition_source(predicate)
    if source=='internal_state':
        state=observation.get('internal_state',{})
        if not isinstance(state,dict):raise ValueError('INTERNAL_STATE_NOT_OBJECT')
        return state
    external=observation.get('external_observations')
    if not isinstance(external,dict) or not isinstance(external.get('values'),dict):
        raise ValueError('EXTERNAL_OBSERVATIONS_NOT_OBJECT')
    provenance=external.get('provenance')
    if not isinstance(provenance,dict) or not provenance.get('method') or not provenance.get('claim_scope'):
        raise ValueError('EXTERNAL_OBSERVATION_PROVENANCE_REQUIRED')
    evidence=provenance.get('evidence')
    if not isinstance(evidence,list) or not evidence or any(not isinstance(p,str) or not p for p in evidence):
        raise ValueError('EXTERNAL_OBSERVATION_EVIDENCE_REQUIRED')
    if evidence_root is not None:
        for rel in evidence:
            if not inside(evidence_root,rel).is_file():raise ValueError('EXTERNAL_OBSERVATION_EVIDENCE_MISSING:'+rel)
    return external['values']


def observation_condition(observation,predicate,evidence_root=None):
    return condition(observation_values(observation,predicate,evidence_root),predicate)


def predicate_evidence(observation,predicate,evidence_root=None):
    values=observation_values(observation,predicate,evidence_root)
    source=condition_source(predicate)
    proof={'expect':predicate,'observation_source':source}
    if source=='internal_state':proof['state']=values
    else:
        proof['external_observations']=observation['external_observations']
        proof['claim_scope']=observation['external_observations']['provenance']['claim_scope']
        proof['semantic_game_outcome']='UNVERIFIED'
    return proof


def validate_profile_observation_sources(profile):
    # Existing Goal semantics are game-state based. A screen difference alone
    # must never become GOAL_REACHED through an explicitly selected data source.
    for goal in profile.get('goals',[]):
        if condition_source(goal)!='internal_state':raise ValueError('EXTERNAL_OBSERVATION_NOT_GAME_GOAL')
    for test in profile.get('tests',[]):
        if isinstance(test.get('expect'),dict):condition_source(test['expect'])
