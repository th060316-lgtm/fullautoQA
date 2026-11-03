extends SceneTree

const EXPECTED_CHECKS := 10
const Fixture = preload("res://expedition_lab/ExpeditionFixture.gd")
const KnowledgeState = preload("res://expedition_lab/state/KnowledgeState.gd")

var passed := 0
var failed: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("[TAKEOVER PASS] " + label)
	else:
		failed.append(label)
		print("[TAKEOVER FAIL] " + label)

func _path_clear(path: Array) -> bool:
	for point in path:
		for rect in Fixture.BLOCKED_RECTS:
			if rect.has_point(point):
				return false
	return true

func _run() -> void:
	var packed: PackedScene = load("res://expedition_lab/ExpeditionPrototypeLab.tscn")
	if packed == null:
		check("Prototype loads for takeover checks", false)
		_finish()
		return
	var lab = packed.instantiate()
	get_root().add_child(lab)
	await process_frame
	await process_frame

	var route: Dictionary = lab.issue_move("hero", Vector2(650,120))
	var path: Array = route.get("path",[])
	check("Navigation produces a real detour around rubble", bool(route.get("ok",false)) and path.size()>1 and _path_clear(path))

	lab.reset_prototype()
	var patrol = lab.state.actors["patrol_a"]
	lab.state.actors["scout"].position = patrol.position + Vector2(-180,0)
	for event in lab.perception.scan(lab.state,"scout"):
		lab._handle_knowledge_event(event)
	var estimated: Dictionary = lab.state.knowledge.get_contact("patrol_a")
	check("Estimated contact does not reveal exact truth", str(estimated.get("status",""))==KnowledgeState.ESTIMATED and (estimated.get("estimated_position",Vector2.ZERO) as Vector2).distance_to(patrol.position)>1.0)

	lab.reset_prototype()
	lab.observe_contact("patrol_a",KnowledgeState.CONFIRMED,"test")
	check("Distant confirmed target still cannot be fired on", str(lab.attack("hero","patrol_a","left_leg").get("reason",""))=="out_of_range")

	lab.reset_prototype()
	patrol=lab.state.actors["patrol_a"]
	lab.state.actors["hero"].position=patrol.position+Vector2(-100,0)
	lab.observe_contact("patrol_a",KnowledgeState.CONFIRMED,"test")
	lab.set_time_scale(1.0)
	var before_leg: float = patrol.get_part_hp("left_leg")
	lab.context_target={"kind":"enemy","id":"patrol_a","position":patrol.position}
	var choose_part: Dictionary=lab.execute_context_command("target_part")
	var targeted: Dictionary=lab.execute_context_command("target_part:left_leg")
	check("Human part-target command requires and applies an explicit valid part", str(choose_part.get("reason",""))=="part_selection_required" and bool(targeted.get("ok",false)) and patrol.get_part_hp("left_leg")<before_leg)

	lab.reset_prototype()
	patrol=lab.state.actors["patrol_a"]
	patrol.position=lab.state.actors["hero"].position+Vector2(100,0)
	lab.state.enemy_truth["patrol_a"]["position"]=patrol.position
	lab.state.enemy_truth["patrol_a"]["alerted"]=true
	lab.state.enemy_truth["patrol_a"]["engage_after"]=-1.0
	lab.set_time_scale(1.0)
	var damage_before:=float(lab.state.metrics.get("damage_received",0.0))
	lab.step_simulation(0.1)
	check("Alerted enemy can counterattack on the shared map", float(lab.state.metrics.get("damage_received",0.0))>damage_before)

	lab.reset_prototype()
	lab.apply_incoming_damage("scout","torso",150.0)
	lab.set_time_scale(1.0)
	lab.state.actors["hero"].position=lab.state.actors["scout"].position
	var carried: Dictionary=lab.carry("hero","scout")
	var carry_move: Dictionary=lab.issue_move("hero",Fixture.EXTRACTION_PRIMARY)
	for _i in range(30):
		lab.order_system.tick_movement(lab.state,"hero",0.1)
	check("Carried casualty physically follows the carrier", bool(carried.get("ok",false)) and bool(carry_move.get("ok",false)) and lab.state.actors["scout"].position.distance_to(lab.state.actors["hero"].position)<1.0)
	lab.start_retreat()
	lab.set_time_scale(1.0)
	var carried_extract: Dictionary=lab.evaluate_extraction(false)
	check("Carried casualty counts as returned at extraction", (carried_extract.get("returned",[]) as Array).has("scout"))

	lab.reset_prototype()
	lab.state.actors["medic"].position=lab.state.rescue_targets["civilian_01"]["position"]
	var escorted: Dictionary=lab.rescue("medic","civilian_01")
	lab.set_time_scale(1.0)
	var pre_summary: Dictionary=lab.get_outcome_summary()
	lab.issue_move("medic",Fixture.EXTRACTION_PRIMARY)
	for _i in range(160):
		lab.order_system.tick_movement(lab.state,"medic",0.1)
	lab.state.actors["hero"].position=Fixture.EXTRACTION_PRIMARY
	lab.state.actors["scout"].position=Fixture.EXTRACTION_PRIMARY
	lab.start_retreat()
	lab.set_time_scale(1.0)
	lab.evaluate_extraction(false)
	var post_summary: Dictionary=lab.get_outcome_summary()
	check("Civilian rescue requires physical extraction", bool(escorted.get("ok",false)) and not bool(pre_summary.get("world_consequence",{}).get("civilian_rescued",false)) and bool(post_summary.get("world_consequence",{}).get("civilian_rescued",false)))

	lab.reset_prototype()
	var hostile=lab.state.actors["hostile_kmf"]
	lab.core.apply_damage("hostile_kmf","weapon",50.0,{"source_id":"test","mode_id":"takeover"})
	lab.core.apply_damage("hostile_kmf","left_leg",100.0,{"source_id":"test","mode_id":"takeover"})
	lab.core.apply_damage("hostile_kmf","right_leg",100.0,{"source_id":"test","mode_id":"takeover"})
	var effects: Dictionary=hostile.get_effects()
	check("KMF can be disabled without killing its pilot", bool(effects.get("weapon_disabled",false)) and bool(effects.get("immobilized",false)) and hostile.get_part_hp("cockpit")>0.0 and not hostile.destroyed and not hostile.incapacitated)

	check("Authored KMF prototype art is loadable", ResourceLoader.exists("res://expedition_lab/assets/kmf/friendly_kmf.svg") and ResourceLoader.exists("res://expedition_lab/assets/kmf/hostile_kmf.svg"))

	_finish()

func _finish() -> void:
	var ran:=passed+failed.size()
	print("Ran %d / %d; failures=%d" % [ran,EXPECTED_CHECKS,failed.size()])
	if ran==EXPECTED_CHECKS and failed.is_empty():
		print("TAKEOVER CHECKS PASSED")
		quit(0)
	else:
		print("TAKEOVER CHECKS FAILED")
		quit(1)

