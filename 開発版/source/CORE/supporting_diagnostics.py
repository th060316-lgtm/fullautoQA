"""Preserve out-of-contract historical diagnostics without changing QA gates."""
import shutil
from common import digest,inside,read_json,write_json

def attach_diagnostics(root,e,profile):
    rows=[]
    for item in profile.get('supporting_diagnostics',[]):
        if item.get('scope')!='outside_target_acceptance_contract':raise ValueError('DIAGNOSTIC_SCOPE_INVALID')
        copied=[]
        for source in item['files']:
            path=inside(root,source['path'])
            if not path.is_file() or digest(path)!=source['sha256']:raise ValueError('DIAGNOSTIC_INTEGRITY_FAILURE')
            rel='SUPPORTING_DIAGNOSTICS/'+source['sha256']+'_'+path.name
            dest=inside(e.root,rel);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,dest);copied.append(rel)
        record=read_json(inside(e.root,copied[0]))
        if record.get('scope')!=item['scope'] or not record.get('historical_only'):raise ValueError('DIAGNOSTIC_PROVENANCE_INVALID')
        row={'id':item['id'],'scope':item['scope'],'classification':record['classification'],
             'historical_only':True,'status':record['status'],'origin':record['origin'],
             'affects_required_gate':False,'evidence':copied}
        rows.append(row)
        e.event('supporting_diagnostic',profile['game_id'],**row)
    return rows
