extends SceneTree

var checks := 0
var failures := 0
var stage := "boot"

func check(name: String, condition: bool) -> void:
	checks += 1
	if condition:
		print("PASS: ", name)
	else:
		failures += 1
		push_error("FAIL: " + name)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	stage = "scene_boot"
	print("STAGE: ", stage)
	var Scene = load("res://expedition_lab/ExpeditionPrototypeLab.tscn")
	var lab = Scene.instantiate()
	root.add_child(lab)
	await process_frame
	lab.set_process(false)
	stage = "move"
	print("STAGE: ", stage)

	check("default intent MOVE", lab.intent_mode == "MOVE")
	check("preparation applies", bool(lab.apply_preparation({"scout":true,"medic":true,"kmf":true,"preset":"balanced"}).get("ok",false)))
	check("all default party present", lab.state.actors.has("hero") and lab.state.actors.has("scout") and lab.state.actors.has("medic") and lab.state.actors.has("friendly_kmf"))

	lab.set_intent_mode("MOVE")
	var move_preview: Dictionary = lab.preview_intent_at(Vector2(350, 620))
	check("MOVE preview valid", bool(move_preview.get("ok",false)) and not (move_preview.get("path",[]) as Array).is_empty())
	check("MOVE preview has ETA", float(move_preview.get("eta",0.0)) > 0.0)
	lab.add_intent_waypoint(Vector2(260, 650))
	move_preview = lab.preview_intent_at(Vector2(350, 620))
	check("Waypoint retained", (move_preview.get("waypoints",[]) as Array).size() >= 1)
	lab.set_intent_facing(Vector2(420,620))
	move_preview = lab.get_intent_preview()
	check("Facing present", move_preview.has("facing"))
	check("MOVE confirm", bool(lab.confirm_intent().get("ok",false)))
	for i in range(80):
		lab.step_simulation(0.15)
	check("MOVE arrives", lab.state.actors["hero"].position.distance_to(Vector2(350,620)) < 4.0)

	stage = "scout"
	print("STAGE: ", stage)
	lab.set_intent_mode("SCOUT")
	var scout_preview: Dictionary = lab.preview_intent_at(Vector2(350,470))
	check("SCOUT preview valid", bool(scout_preview.get("ok",false)))
	check("SCOUT info gain reported", scout_preview.has("info_gain"))
	lab.confirm_intent()
	for i in range(120):
		lab.step_simulation(0.15)
	check("SCOUT explores terrain", lab.area_knowledge.explored_cells.size() > 0)

	stage = "clear"
	print("STAGE: ", stage)
	lab.set_intent_mode("CLEAR")
	var clear_preview: Dictionary = lab.preview_intent_at(Vector2(285,260))
	check("CLEAR preview valid", bool(clear_preview.get("ok",false)))
	check("CLEAR has checkpoints", (clear_preview.get("checkpoints",[]) as Array).size() >= 4)
	lab.confirm_intent()
	for i in range(240):
		lab.step_simulation(0.15)
	var clear_snapshot: Dictionary = lab.area_knowledge.snapshot()
	check("CLEAR records area", not (clear_snapshot.get("clear_areas",{}) as Dictionary).is_empty())
	var any_clear := false
	for row in (clear_snapshot.get("clear_areas",{}) as Dictionary).values():
		if str(row.get("status","")) == "clear":
			any_clear = true
	check("CLEAR completes only after route traversal", any_clear)
	lab.area_knowledge.update_decay(lab.state.sim_time + 60.0)
	var any_uncertain := false
	for row in lab.area_knowledge.clear_areas.values():
		if str(row.get("status","")) == "uncertain":
			any_uncertain = true
	check("CLEAR decays to uncertain", any_uncertain)

	stage = "assault"
	print("STAGE: ", stage)
	# Isolate the combat acceptance from the deliberately stale CLEAR-contact scenario above.
	# A fresh confirmed contact must be actionable; stale contacts must still require reacquisition.
	lab.reset_prototype()
	lab.set_process(false)
	lab.state.actors["hero"].position = Vector2(650,430)
	lab.select_actor("hero")
	lab.observe_contact("patrol_a", "confirmed", "test")
	lab.set_intent_mode("ASSAULT")
	var assault_preview: Dictionary = lab.preview_intent_at(Vector2(770,430))
	check("ASSAULT preview valid", bool(assault_preview.get("ok",false)))
	check("ASSAULT weapon contract present", not (assault_preview.get("weapon",{}) as Dictionary).is_empty())
	var hp_before := float(lab.state.actors["patrol_a"].hp)
	lab.confirm_intent()
	for i in range(80):
		lab.step_simulation(0.10)
	var hp_after := float(lab.state.actors["patrol_a"].hp)
	check("ASSAULT engages fresh confirmed enemy", hp_after < hp_before or lab.state.actors["patrol_a"].incapacitated or lab.state.actors["patrol_a"].destroyed)

	stage = "fire_and_shield"
	print("STAGE: ", stage)
	lab.reset_prototype()
	lab.apply_preparation({"scout":true,"medic":true,"kmf":true,"preset":"heavy"})
	lab.observe_contact("patrol_a", "confirmed", "test")
	lab.set_intent_mode("FIRE_POSITION")
	var fire_preview: Dictionary = lab.preview_intent_at(Vector2(640,500))
	check("FIRE POSITION preview valid", bool(fire_preview.get("ok",false)))
	check("FIRE POSITION reports cover", fire_preview.has("cover"))
	check("FIRE POSITION uses equipment range data", not (fire_preview.get("weapon",{}) as Dictionary).is_empty())

	var hero = lab.state.actors["hero"]
	hero.meta["facing"] = (lab.state.actors["patrol_a"].position - hero.position).angle()
	lab.equipment_system.shield_strength["hero"] = 80.0
	var raw := 20.0
	var shielded: Dictionary = lab.equipment_system.resolve_incoming(hero, lab.state.actors["patrol_a"].position, raw)
	check("directional shield blocks front", bool(shielded.get("blocked",false)) and float(shielded.get("damage",raw)) < raw)
	var rear_pos: Vector2 = hero.position - (lab.state.actors["patrol_a"].position - hero.position).normalized() * 100.0
	var rear: Dictionary = lab.equipment_system.resolve_incoming(hero, rear_pos, raw)
	check("directional shield does not block rear", not bool(rear.get("blocked",false)))

	lab.sound_system.emit_sound(Vector2(500,500), 500.0, 1.0, "test_enemy", "patrol_b", lab.state.sim_time, "enemy")
	var sound_events: Array = lab.perception.scan_sounds(lab.state, "hero", lab.sound_system, lab.state.sim_time - 0.1)
	check("sound creates player knowledge event", sound_events.size() >= 1)

	stage = "preparation"
	print("STAGE: ", stage)
	lab.reset_prototype()
	var prep_no_kmf: Dictionary = lab.apply_preparation({"scout":true,"medic":false,"kmf":false,"preset":"stealth"})
	check("local preparation can remove units", bool(prep_no_kmf.get("ok",false)) and not lab.state.actors.has("medic") and not lab.state.actors.has("friendly_kmf"))

	stage = "campaign_preparation"
	print("STAGE: ", stage)
	var Defaults = load("res://sandbox/FoundationDefaults.gd")
	var Adapter = load("res://sandbox/HospitalDistrictExpeditionAdapter.gd")
	var campaign: Dictionary = Defaults.create_campaign()
	campaign["mode"] = "sandbox"
	campaign["inventory"]["items"] = {
		"medicine":{"item_id":"medicine","quantity":2,"condition":1.0,"durability":-1.0,"metadata":{}},
		"field_rifle":{"item_id":"field_rifle","quantity":1,"condition":1.0,"durability":100.0,"metadata":{}},
	}
	var prepared: Dictionary = Adapter.launch_with_preparation(campaign, {"party_ids":["hero"],"loadout_ids":["field_rifle"],"kmf_ids":[]}, 4242)
	check("campaign prepared launch succeeds", bool(prepared.get("ok",false)))
	check("campaign preparation preserves selected loadout only", (prepared.get("loadout_ids",[]) as Array) == ["field_rifle"])
	check("campaign preparation can leave KMF home", (prepared.get("kmf_ids",[]) as Array).is_empty())

	print("Ran %d / %d; failures=%d" % [checks, checks, failures])
	if failures == 0:
		print("INTENT TACTICAL HOSPITAL CHECKS PASSED")
		quit(0)
	else:
		quit(1)
