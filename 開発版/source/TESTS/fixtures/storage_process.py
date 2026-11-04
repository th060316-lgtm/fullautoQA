"""Synthetic child fixture; never evidence of real target acceptance."""
import json,sys
from pathlib import Path
root=Path(sys.argv[1]);root.mkdir(exist_ok=True);state={'value':0,'slot':'a','error':None,'version':2}
def save():(root/(state['slot']+'.json')).write_text(json.dumps({'value':state['value'],'version':2}))
def load():
    try:
        data=json.loads((root/(state['slot']+'.json')).read_text());state.update(value=data['value'],version=2,error=None)
        if data.get('version',1)<2:save()
    except Exception:state['error']='corrupt'
for line in sys.stdin:
    action=json.loads(line)['action']
    if action=='save':save()
    elif action=='change':state['value']+=7
    elif action=='load':load()
    elif action=='slot_a':state['slot']='a'
    elif action=='slot_b':state['slot']='b'
    elif action=='autosave':state['value']+=11;save()
    elif action!='observe':raise ValueError(action)
    print(json.dumps(state),flush=True)
