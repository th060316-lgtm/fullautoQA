extends Node2D
var mode := "grid"
var bridge := ""
var seed_value := 12345
var fault := ""
var rng := RandomNumberGenerator.new()
var s := {"scene":"play", "position":{"x":0,"y":0}, "turn":0,"money":100,"score":0,"branch":"","dialogue":0,"goal":false,"saved":false,"loaded":false,"load_error":false,"reaction":0,"event":"","retry":0,"failed":false}
var timer := 0.0
var last_write := 0.0
var label: Label
var save_path := ""
func _ready():
    var args := OS.get_cmdline_user_args()
    for i in range(args.size()):
        if args[i] == "--mode" and i+1<args.size(): mode=args[i+1]
        if args[i] == "--bridge" and i+1<args.size(): bridge=args[i+1]
        if args[i] == "--seed" and i+1<args.size(): seed_value=int(args[i+1])
        if args[i] == "--fault" and i+1<args.size(): fault=args[i+1]
    rng.seed=seed_value
    save_path=ProjectSettings.globalize_path("res://qa_save.json")
    label=Label.new();label.position=Vector2(25,20);label.add_theme_font_size_override("font_size",22);add_child(label)
    publish()
func _process(delta: float) -> void:
    timer+=delta
    if mode=="realtime" and not s.failed and fault!="stall" and fault!="loop" and s.scene=="play":
        var speed: float = 3.0 * delta
        if Input.is_physical_key_pressed(KEY_RIGHT): s.position.x=minf(float(s.position.x)+speed,5.0)
        if Input.is_physical_key_pressed(KEY_LEFT): s.position.x=maxf(float(s.position.x)-speed,0.0)
        if Input.is_physical_key_pressed(KEY_DOWN): s.position.y=minf(float(s.position.y)+speed,5.0)
        if Input.is_physical_key_pressed(KEY_UP): s.position.y=maxf(float(s.position.y)-speed,0.0)
        if float(s.position.x)>=4.0: s.goal=true
    if timer-last_write>0.1:
        last_write=timer;publish()
    label.text="QA Fixture: "+mode+"\nArrows: Move/Select | Enter: Confirm/Next\n1/2: Choice | B: Build | N: Next turn\nF5: Save | F9: Load | Esc: Menu | R: Retry\n"+JSON.stringify(s,"  ")
    queue_redraw()
func _draw():
    draw_rect(Rect2(0,0,800,600),Color(0.08,0.12,0.20) if fault!="visual" else Color(0.5,0.1,0.1))
    if mode in ["grid","realtime","procedural"]:
        for x in range(6):
            for y in range(6):draw_rect(Rect2(460+x*48,230+y*48,46,46),Color(0.2,0.3,0.4))
        draw_circle(Vector2(483+float(s.position.x)*48,253+float(s.position.y)*48),16,Color.CYAN)
func _unhandled_key_input(event):
    if not event is InputEventKey or not event.pressed or event.echo:return
    var k: int=event.physical_keycode
    if fault=="crash" and k==KEY_Q: OS.crash("Injected crash")
    if fault in ["stall","loop"]:return
    s.reaction+=1
    if k==KEY_ESCAPE:s.scene="play" if s.scene=="menu" else "menu"
    if k==KEY_F5:
        if fault=="save":s.event="save_failed"
        else:
            var f:=FileAccess.open(save_path,FileAccess.WRITE)
            if f:f.store_string(JSON.stringify(s));f.close();s.saved=true;s.event="saved"
    if k==KEY_F9:
        if FileAccess.file_exists(save_path):
            var data=JSON.parse_string(FileAccess.get_file_as_string(save_path))
            if data is Dictionary:
                s=data;s.loaded=true;s.event="loaded"
            else:s.load_error=true;s.event="invalid_save_rejected"
        else:s.load_error=true;s.event="missing_save_rejected"
    if k==KEY_R:
        s.failed=false;s.retry+=1;s.scene="play"
    if k==KEY_F:s.failed=true;s.scene="failure"
    if s.scene!="play":publish();return
    if mode=="grid":
        if k==KEY_RIGHT:s.position.x=mini(int(s.position.x)+1,5)
        if k==KEY_DOWN:s.position.y=mini(int(s.position.y)+1,5)
        if k==KEY_LEFT:s.position.x=maxi(int(s.position.x)-1,0)
        if k==KEY_UP:s.position.y=maxi(int(s.position.y)-1,0)
        if k==KEY_N or k==KEY_ENTER:s.turn+=1
        s.goal=int(s.position.x)==3 and int(s.position.y)==3 and int(s.turn)>=1
    if mode=="management":
        if k==KEY_B and s.money>=20:s.money-=20;s.score+=1
        if k==KEY_N or k==KEY_ENTER:s.turn+=1;s.money+=int(s.score)*10
        if k==KEY_TAB:s.event="tab_selected"
        s.goal=int(s.score)>=3 and int(s.turn)>=2
    if mode=="narrative":
        if k==KEY_ENTER:s.dialogue+=1
        if k==KEY_1:s.branch="north";s.event="choice_north"
        if k==KEY_2:s.branch="south";s.event="choice_south"
        s.goal=int(s.dialogue)>=3 and s.branch!=""
    if mode=="procedural":
        if k==KEY_ENTER or k==KEY_N:
            s.turn+=1;s.score+=rng.randi_range(1,6);s.event="roll_"+str(s.score)
        s.goal=int(s.turn)>=5
    publish()
func publish():
    s["timer"]=snappedf(timer,0.01);s["seed"]=seed_value;s["mode"]=mode
    if bridge!="":
        var f:=FileAccess.open(bridge+".tmp",FileAccess.WRITE)
        if f:
            f.store_string(JSON.stringify(s));f.close();DirAccess.rename_absolute(bridge+".tmp",bridge)
