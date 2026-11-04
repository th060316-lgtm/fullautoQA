"""Game-side selectors from observed UI/viewport/grid metadata; physical input only."""
from adapters import Adapter
import math

def normalized_point(state,x,y):
    mapping=state['input_mapping']
    keys=('xx','xy','yx','yy','origin_x','origin_y','client_width','client_height')
    if not all(math.isfinite(float(mapping[k])) for k in keys):raise ValueError('INVALID_OBSERVED_INPUT_MAPPING')
    width=float(mapping['client_width']);height=float(mapping['client_height'])
    if width<=0 or height<=0:raise ValueError('INVALID_OBSERVED_CLIENT_SIZE')
    nx=(mapping['xx']*x+mapping['xy']*y+mapping['origin_x'])/width
    ny=(mapping['yx']*x+mapping['yy']*y+mapping['origin_y'])/height
    if not 0<=nx<1 or not 0<=ny<1:raise ValueError('MAPPED_SELECTOR_OFFSCREEN')
    return nx,ny

class TargetAdapter(Adapter):
    def __init__(self,profile,context):
        super().__init__(profile,context)
        self.tile_attempt=0

    def act(self,name):
        action=self.profile['actions'][name]
        selector=action.get('selector')
        if not selector:return super().act(name)
        state=self.observe()['internal_state']
        vp=state['viewport'];width=float(vp['width']);height=float(vp['height'])
        if width<=0 or height<=0:raise ValueError('INVALID_OBSERVED_VIEWPORT')
        if selector['kind']=='button':
            matches=[b for b in state['ui_buttons'] if b['text']==selector['text'] and not b.get('disabled')]
            if len(matches)!=1:raise ValueError('UI_SELECTOR_NOT_UNIQUE:'+selector['text'])
            x,y=matches[0]['x'],matches[0]['y']
        elif selector['kind']=='terminal_neighbor':
            towns=sorted((s for s in state['settlements'] if s['active'] and not s['is_supply_base']),key=lambda s:s['id'])
            if not towns:raise ValueError('NO_OBSERVED_SETTLEMENT')
            town=towns[0];g=state['grid']
            neighbors=[(1,0),(0,1),(-1,0),(0,-1)]
            dx,dy=neighbors[self.tile_attempt%len(neighbors)];self.tile_attempt+=1
            tx,ty=town['terminal_x']+dx,town['terminal_y']+dy
            if not 0<=tx<g['cols'] or not 0<=ty<g['rows']:raise ValueError('OBSERVED_TILE_OUTSIDE_GRID')
            x=g['origin_x']+(tx+.5)*g['tile_size'];y=g['origin_y']+(ty+.5)*g['tile_size']
        else:raise ValueError('UNKNOWN_GAME_SELECTOR')
        if not 0<=x<width or not 0<=y<height:raise ValueError('OBSERVED_SELECTOR_OFFSCREEN')
        nx,ny=normalized_point(state,x,y)
        inputs=[dict(item) for item in action.get('inputs',[])]+[{'kind':'click','x':nx,'y':ny}]
        self.desktop.focus()
        for item in inputs:
            self.desktop.perform(item)
            self.context['evidence'].event('physical_input',self.profile['game_id'],action=name,selector=selector,observed_viewport={'width':width,'height':height},observed_position={'x':x,'y':y},input_mapping=state['input_mapping'],input=item)

def create(profile,context):return TargetAdapter(profile,context)
