"""Game-side selectors from observed UI/viewport/grid metadata; physical input only."""
from adapters import Adapter

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
        self.desktop.focus()
        for item in action.get('inputs',[]):self.desktop.perform(item)
        self.desktop.perform({'kind':'click','x':x/width,'y':y/height})

def create(profile,context):return TargetAdapter(profile,context)
