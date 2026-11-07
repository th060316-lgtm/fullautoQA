extends SceneTree
## Day1 completion acceptance: verifies the structural fixes identified by the real play video.
var failed: int = 0

func _check(ok: bool, label: String) -> void:
	if ok:
		print("[DAY1 COMPLETE PASS] " + label)
	else:
		print("[DAY1 COMPLETE FAIL] " + label)
		failed += 1

func _init() -> void:
	call_deferred("_run")

func _tick(count: int = 1) -> void:
	for _i in range(count):
		await process_frame
		await physics_frame

func _run() -> void:
	var gs: Node = get_root().get_node_or_null("GameState")
	if gs and gs.has_method("_init_default_state"):
		gs._init_default_state()
	var packed: PackedScene = load("res://scenes/Main.tscn")
	_check(packed != null, "Main scene loads")
	if packed == null:
		quit(1)
		return
	var main: Node = packed.instantiate()
	get_root().add_child(main)
	await _tick(5)

	var d1: Node = main.get_node_or_null("Day1Controller")
	var map: Node = main.get_node_or_null("MapManager")
	var player: Node = main.get_node_or_null("Player")
	var combat: Node = main.get_node_or_null("CombatManager")
	var save_manager: Node = main.get_node_or_null("SaveManager")
	_check(d1 != null and d1.is_initialized(), "Day1 canonical controller initialized")

	var day1: Dictionary = gs.get_section("day1")
	_check(int(day1.get("schema_version", 0)) == 3 and day1.has("end_result"), "Day1 schema upgraded to v3")
	var rescue_deadline := int(d1.get_case_state("quest_evacuation_rescue").get("deadline_abs_minute", 0))
	var hospital_deadline := int(d1.get_case_state("quest_hospital_medicine").get("deadline_abs_minute", 0))
	var supply_deadline := int(d1.get_case_state("quest_supply_depot").get("deadline_abs_minute", 0))
	_check(rescue_deadline == 10 * 60 + 30 and hospital_deadline == 11 * 60 + 30 and supply_deadline == 13 * 60,
		"Case deadlines span the morning instead of ending by 09:40")

	var time_before: int = int(gs.get_minute_of_day())
	map._update_semantic_location(map.get_navigation_position("hospital"))
	map._update_semantic_location(map.get_navigation_position("base"))
	map._update_semantic_location(map.get_navigation_position("city_center"))
	_check(gs.get_minute_of_day() == time_before, "Semantic boundary crossings do not consume time")

	var eta_day1: Dictionary = gs.get_section("day1")
	eta_day1["inventory"]["medicine_box"] = true
	gs.set_section("day1", eta_day1)
	gs.set_player_location("hospital")
	var hospital_overview: Dictionary = d1.get_case_overview("quest_hospital_medicine")
	_check(int(hospital_overview.get("foot_eta_minutes", -1)) == 0 and int(hospital_overview.get("kmf_eta_minutes", -1)) == 0,
		"Same-location travel estimate is zero")

	var quest_manager: Node = get_root().get_node_or_null("QuestManager")
	var available: Array = quest_manager.get_available_quests() if quest_manager else []
	var duplicate_hospital := false
	for q in available:
		if str(q.get("id", "")) == "quest_hospital_medicine":
			duplicate_hospital = true
	_check(not duplicate_hospital, "Legacy QuestManager does not duplicate Day1 case availability")

	# Rescue is explicitly multi-stage: city rescue cannot finish the delivery.
	gs.set_player_location("city_center")
	day1 = gs.get_section("day1")
	day1["rei_talked"] = true
	day1["rescued_evacuees"] = true
	gs.set_section("day1", day1)
	d1.advance_stage("quest_evacuation_rescue", "rescued")
	var premature_rescue := bool(d1.try_complete_case("quest_evacuation_rescue", {"talked_rei": true, "rescued": true}))
	_check(not premature_rescue and str(d1.get_case_state("quest_evacuation_rescue").get("status", "")) != "completed",
		"Rescue cannot complete in city_center")

	gs.set_player_location("evacuation_center")
	d1.advance_stage("quest_evacuation_rescue", "arrived_evac")
	var delivered_rescue := bool(d1.try_complete_case("quest_evacuation_rescue", {"talked_rei": true, "rescued": true}))
	_check(delivered_rescue and str(d1.get_case_state("quest_evacuation_rescue").get("stage", "")) == "completed",
		"Rescue completes only after evacuation-center delivery")

	# Safe opening: even if physically near the enemy KMF, semantic safe zone suppresses engagement.
	var enemy_kmf: Node2D = null
	for child in combat.get_children():
		if child is Node2D and child.has_meta("type") and str(child.get_meta("type")) == "enemy_kmf":
			enemy_kmf = child
			break
	_check(enemy_kmf != null, "Enemy KMF exists")
	if enemy_kmf:
		var base_pos: Vector2 = map.get_navigation_position("base")
		player.global_position = base_pos
		gs.set_player_position(base_pos)
		gs.set_player_location("base")
		var safe_enemy_pos: Vector2 = enemy_kmf.global_position
		await _tick(12)
		_check(enemy_kmf.global_position.distance_to(safe_enemy_pos) < 1.0 and not combat.is_encounter_active(),
			"Safe-zone reading/conversation cannot trigger enemy KMF")

		player.global_position = enemy_kmf.global_position + Vector2(60, 0)
		gs.set_player_position(player.global_position)
		gs.set_player_location("industrial_area")
		var danger_enemy_pos: Vector2 = enemy_kmf.global_position
		await _tick(12)
		_check(enemy_kmf.global_position.distance_to(danger_enemy_pos) > 1.0 and combat.is_encounter_active(),
			"Danger-zone proximity activates a bounded enemy encounter")

	# KMF lifecycle: board, move, dismount, leave, return and board again.
	gs.set_player_location("base")
	var kmf: Dictionary = gs.get_section("kmf")
	var posd: Dictionary = kmf.get("position", {})
	var kpos := Vector2(float(posd.get("x", 0)), float(posd.get("y", 0)))
	player.global_position = kpos
	gs.set_player_position(kpos)
	player._try_board_or_disembark()
	await _tick(2)
	var boarded_once: bool = str(gs.get_player_mode()) == "kmf"
	player.global_position = kpos + Vector2(90, 25)
	gs.set_player_position(player.global_position)
	player._try_board_or_disembark()
	await _tick(2)
	var parked_dict: Dictionary = gs.get_section("kmf").get("position", {})
	var parked := Vector2(float(parked_dict.get("x", 0)), float(parked_dict.get("y", 0)))
	var dismounted: bool = str(gs.get_player_mode()) == "foot" and parked.distance_to(kpos + Vector2(90, 25)) < 1.0
	player.global_position = parked + Vector2(100, 0)
	gs.set_player_position(player.global_position)
	player.global_position = parked
	gs.set_player_position(parked)
	player._try_board_or_disembark()
	await _tick(2)
	_check(boarded_once and dismounted and gs.get_player_mode() == "kmf", "Owned KMF survives dismount, walk-away and reboard")

	_check(save_manager != null and bool(save_manager.test_round_trip()), "Save/Load logical round-trip remains consistent")

	# Terminal cases must never leave the old stale objective or an unset result.
	day1 = gs.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	for cid in states.keys():
		var st: Dictionary = states[cid]
		if cid == "quest_hospital_medicine":
			st["status"] = "completed"
			st["stage"] = "completed"
		else:
			st["status"] = "expired"
			st["stage"] = "expired"
		states[cid] = st
	day1["case_states"] = states
	gs.set_section("day1", day1)
	d1.recalculate_current_objective()
	_check(d1.get_current_objective().contains("帰投") and not d1.get_current_objective().contains("病院と市街救助"),
		"Terminal cases replace the stale opening objective")
	d1.finalize_day1_result()
	_check(not d1.get_end_result().is_empty() and d1.get_current_objective().contains("Day1終了"),
		"Day1 final result is explicit")

	print("DAY1 COMPLETION ACCEPTANCE: " + ("PASSED" if failed == 0 else "FAILED"))
	quit(0 if failed == 0 else 1)
