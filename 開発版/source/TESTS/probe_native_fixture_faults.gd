extends SceneTree
func _initialize():
    call_deferred("_probe")
func _probe():
    var rows = []
    var failed = false
    for fault_name in ["", "stall", "loop"]:
        var fixture = load("res://fixture.gd").new()
        root.add_child(fixture)
        fixture.set_process(false)
        fixture.mode = "realtime"
        fixture.fault = fault_name
        var key = InputEventKey.new()
        key.physical_keycode = KEY_RIGHT
        key.keycode = KEY_RIGHT
        key.pressed = true
        Input.parse_input_event(key)
        var held = Input.is_physical_key_pressed(KEY_RIGHT)
        var before = float(fixture.s.position.x)
        fixture._process(0.5)
        var after = float(fixture.s.position.x)
        key.pressed = false
        Input.parse_input_event(key)
        var expected_movement = fault_name == ""
        var passed = held and ((after > before) == expected_movement)
        if not passed: failed = true
        rows.append({"fault":fault_name,"held":held,"before":before,"after":after,"expected_movement":expected_movement,"status":"PASS" if passed else "FAIL"})
        root.remove_child(fixture)
        fixture.free()
    print("NATIVE_FIXTURE_PROBE=" + JSON.stringify({"rows":rows,"status":"FAIL" if failed else "PASS"}))
    quit(2 if failed else 0)
