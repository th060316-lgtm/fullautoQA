extends SceneTree
## Internal secondary destructive QA: boundary, repetition, sequencing and state-corruption probes.
const EXPECTED := 10
var passed := 0
var failed := 0
var current_main: Node = null

func _result(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("[DESTRUCTIVE PASS] " + label)
	else:
		failed += 1
		print("[DESTRUCTIVE FAIL] " + label)

func _init() -> void:
	call_deferred("_run")

func _frames(n: int = 2) -> void:
	for _i in range(n):
		await process_frame
		await physics_frame

func _fresh() -> Dictionary:
	if current_main and is_instance_valid(current_main):
		current_main.queue_free()
		await _frames(2)
	var gs := get_root().get_node_or_null("GameState")
	if gs and gs.has_method("_init_default_state"):
		gs._init_default_state()
	var social := get_root().get_node_or_null("SocialManager")
	if social:
		social._initialized = false
	var packed: PackedScene = load("res://scenes/Main.tscn")
	current_main = packed.instantiate()
	get_root().add_child(current_main)
	await _frames(4)
	return {"main": current_main, "gs": gs, "d1": current_main.get_node("Day1Controller")}

func _prepare_hospital(gs: Node) -> void:
	var day1: Dictionary = gs.get_section("day1")
	day1["inventory"]["medicine_box"] = true
	day1["aoi_talked"] = true
	gs.set_section("day1", day1)
	gs.set_player_location("hospital")

func _run() -> void:
	print("=== INTERNAL SECONDARY DESTRUCTIVE QA ===")
	var r := await _fresh()
	var gs: Node = r.gs
	var d1: Node = r.d1
	var map: Node = r.main.get_node("MapManager")

	# 1. Boundary thrashing must not become a hidden time accelerator.
	var t0: int = int(gs.get_minute_of_day())
	for _i in range(20):
		map._update_semantic_location(map.get_navigation_position("hospital"))
		map._update_semantic_location(map.get_navigation_position("base"))
	_result(gs.get_minute_of_day() == t0, "40 semantic transitions consume zero hidden time")

	# 2. Deadline exactly at the minute is still completable.
	r = await _fresh(); gs = r.gs; d1 = r.d1
	_prepare_hospital(gs)
	var deadline := int(d1.get_case_state("quest_hospital_medicine").get("deadline_abs_minute", 0))
	gs.advance_time(deadline - gs.get_minute_of_day())
	var exact_ok := bool(d1.try_complete_case("quest_hospital_medicine", {}))
	_result(exact_ok, "Completion at exact deadline is accepted")

	# 3. One minute beyond deadline must fail and stay failed.
	r = await _fresh(); gs = r.gs; d1 = r.d1
	_prepare_hospital(gs)
	deadline = int(d1.get_case_state("quest_hospital_medicine").get("deadline_abs_minute", 0))
	gs.advance_time(deadline - gs.get_minute_of_day() + 1)
	var late_ok := bool(d1.try_complete_case("quest_hospital_medicine", {}))
	var late_status := str(d1.get_case_state("quest_hospital_medicine").get("status", ""))
	_result(not late_ok and late_status == "expired", "One minute late is rejected deterministically")

	# 4. Completion repetition must not duplicate facility rewards.
	r = await _fresh(); gs = r.gs; d1 = r.d1
	_prepare_hospital(gs)
	var first := bool(d1.try_complete_case("quest_hospital_medicine", {}))
	var cap1 := float(d1.get_facility_state("hospital").get("capacity", 0.0))
	var second := bool(d1.try_complete_case("quest_hospital_medicine", {}))
	var cap2 := float(d1.get_facility_state("hospital").get("capacity", 0.0))
	_result(first and second and is_equal_approx(cap1, cap2), "Repeated completion is idempotent")

	# 5. Rescue cannot be shortcut by setting success flags while still in the city.
	r = await _fresh(); gs = r.gs; d1 = r.d1
	gs.set_player_location("city_center")
	var day1: Dictionary = gs.get_section("day1")
	day1["rei_talked"] = true
	day1["rescued_evacuees"] = true
	gs.set_section("day1", day1)
	d1.advance_stage("quest_evacuation_rescue", "rescued")
	_result(not bool(d1.try_complete_case("quest_evacuation_rescue", {"talked_rei": true, "rescued": true})),
		"Rescue success flags cannot bypass evacuation delivery")

	# 6. Safe location overrides physical proximity to hostile KMF.
	r = await _fresh(); gs = r.gs
	var combat: Node = r.main.get_node("CombatManager")
	var player: Node = r.main.get_node("Player")
	var enemy_kmf: Node2D = null
	for child in combat.get_children():
		if child is Node2D and child.has_meta("type") and str(child.get_meta("type")) == "enemy_kmf":
			enemy_kmf = child
	if enemy_kmf:
		var map_node: Node = r.main.get_node("MapManager")
		var base_pos: Vector2 = map_node.get_navigation_position("base")
		player.global_position = base_pos
		gs.set_player_position(base_pos)
		gs.set_player_location("base")
		var e0: Vector2 = enemy_kmf.global_position
		await _frames(15)
		_result(enemy_kmf.global_position.distance_to(e0) < 1.0 and not combat.is_encounter_active(),
			"Safe-zone semantics suppress opening aggro")
	else:
		_result(false, "Safe-zone semantics suppress opening aggro")

	# 7. Leash prevents a danger enemy from becoming a global pursuer.
	# Phase 0.5 adds hard PlayAreaBounds, so the probe itself must be a legal in-bounds
	# position. Use the opposite horizontal edge instead of the old out-of-bounds +500px.
	if enemy_kmf:
		gs.set_player_location("industrial_area")
		var far_x: float = 16.0 if enemy_kmf.global_position.x > 640.0 else 1264.0
		var far_pos := Vector2(far_x, clampf(enemy_kmf.global_position.y, 16.0, 944.0))
		player.global_position = far_pos
		gs.set_player_position(far_pos)
		var e1 := enemy_kmf.global_position
		await _frames(15)
		_result(enemy_kmf.global_position.distance_to(e1) < 1.0, "Enemy KMF respects home leash")
	else:
		_result(false, "Enemy KMF respects home leash")

	# 8. Board at the boundary works; outside boundary does not teleport the player.
	r = await _fresh(); gs = r.gs
	player = r.main.get_node("Player")
	var kmf: Dictionary = gs.get_section("kmf")
	var pd: Dictionary = kmf.get("position", {})
	var kp := Vector2(float(pd.get("x", 0)), float(pd.get("y", 0)))
	player.global_position = kp + Vector2(player.get_board_range() + 1.0, 0)
	gs.set_player_position(player.global_position)
	var before_pos: Vector2 = player.global_position
	player._try_board_or_disembark()
	var outside_ok: bool = str(gs.get_player_mode()) == "foot" and player.global_position.distance_to(before_pos) < 0.1
	player.global_position = kp + Vector2(player.get_board_range(), 0)
	gs.set_player_position(player.global_position)
	player._try_board_or_disembark()
	_result(outside_ok and gs.get_player_mode() == "kmf", "KMF boarding boundary has no failure teleport")

	# 9. Dismount coordinate survives save/load.
	player.global_position = kp + Vector2(70, 40)
	gs.set_player_position(player.global_position)
	player._try_board_or_disembark()
	var parked_before: Dictionary = gs.get_section("kmf").get("position", {})
	var sm: Node = r.main.get_node("SaveManager")
	var save_ok: bool = bool(sm.save_game("_destructive_kmf"))
	player.global_position += Vector2(160, 0)
	gs.set_player_position(player.global_position)
	var load_ok: bool = bool(sm.load_game("_destructive_kmf"))
	await _frames(2)
	var parked_after: Dictionary = gs.get_section("kmf").get("position", {})
	_result(save_ok and load_ok and parked_before == parked_after, "Parked KMF coordinate survives save/load")

	# 10. Terminal-state objective/result cannot remain stale/unset.
	r = await _fresh(); gs = r.gs; d1 = r.d1
	day1 = gs.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	for cid in states.keys():
		var st: Dictionary = states[cid]
		st["status"] = "expired"
		st["stage"] = "expired"
		states[cid] = st
	day1["case_states"] = states
	gs.set_section("day1", day1)
	d1.recalculate_current_objective()
	var objective_ok: bool = str(d1.get_current_objective()).contains("帰投")
	d1.finalize_day1_result()
	_result(objective_ok and d1.get_end_result() == "全失敗", "All-failure terminal state has explicit objective and result")

	print("[DESTRUCTIVE] passed=%d failed=%d expected=%d" % [passed, failed, EXPECTED])
	if passed == EXPECTED and failed == 0:
		print("INTERNAL DESTRUCTIVE QA PASSED")
		quit(0)
	else:
		print("INTERNAL DESTRUCTIVE QA FAILED")
		quit(1)
