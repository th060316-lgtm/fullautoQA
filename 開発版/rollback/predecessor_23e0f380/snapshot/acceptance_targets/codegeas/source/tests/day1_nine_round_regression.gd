extends SceneTree
## Nine isolated Day 1 regression playthroughs for the integrated Grok/MiniMax candidate.

const EXPECTED_ROUNDS := 9
var passed_rounds := 0
var failed_rounds := 0
var current_main: Node = null

func _init() -> void:
	call_deferred("_run")

func _round_result(index: int, name: String, ok: bool, detail: String = "") -> void:
	if ok:
		passed_rounds += 1
		print("[ROUND %d PASS] %s%s" % [index, name, (" — " + detail) if detail != "" else ""])
	else:
		failed_rounds += 1
		print("[ROUND %d FAIL] %s%s" % [index, name, (" — " + detail) if detail != "" else ""])

func _fresh_round() -> Dictionary:
	if current_main and is_instance_valid(current_main):
		current_main.queue_free()
		await process_frame
		await process_frame
	var gs = get_root().get_node_or_null("GameState")
	if gs and gs.has_method("_init_default_state"):
		gs._init_default_state()
	var social = get_root().get_node_or_null("SocialManager")
	if social:
		social._initialized = false
	var packed = load("res://scenes/Main.tscn")
	if packed == null:
		return {}
	current_main = packed.instantiate()
	get_root().add_child(current_main)
	await process_frame
	await process_frame
	var d1 = current_main.get_node_or_null("Day1Controller")
	return {"main": current_main, "gs": gs, "d1": d1}

func _prepare_hospital(gs: Node, d1: Node) -> void:
	var day1: Dictionary = gs.get_section("day1")
	day1["inventory"]["medicine_box"] = true
	day1["aoi_talked"] = true
	gs.set_section("day1", day1)
	gs.set_player_location("hospital")

func _run() -> void:
	print("=== DAY 1 NINE-ROUND INTEGRATED REGRESSION ===")

	# 1: Hospital completion persists in the canonical facility state.
	var r = await _fresh_round()
	var gs: Node = r.get("gs")
	var d1: Node = r.get("d1")
	_prepare_hospital(gs, d1)
	var hospital_ok: bool = bool(d1.try_complete_case("quest_hospital_medicine", {}))
	var hospital: Dictionary = d1.get_facility_state("hospital")
	_round_result(1, "Hospital canonical success",
		hospital_ok and str(d1.get_case_state("quest_hospital_medicine").get("status", "")) == "completed"
		and float(hospital.get("capacity", 0.0)) > 0.7
		and str(hospital.get("reason", "")) == "medicine_delivered")

	# 2: Rescue updates NPC/result truth and the factual summary.
	r = await _fresh_round()
	gs = r.get("gs")
	d1 = r.get("d1")
	gs.set_player_location("evacuation_center")
	var day1: Dictionary = gs.get_section("day1")
	day1["rei_talked"] = true
	day1["rescued_evacuees"] = true
	gs.set_section("day1", day1)
	var rescue_ok: bool = bool(d1.try_complete_case("quest_evacuation_rescue", {"talked_rei": true, "rescued": true}))
	var summary_node = d1.get_node_or_null("Day1SummarySystem")
	var rescue_summary: Dictionary = summary_node.force_generate_summary()
	var rescued_ids: Array = []
	for npc in rescue_summary.get("npcs", {}).get("rescued", []):
		rescued_ids.append(str(npc.get("id", "")))
	_round_result(2, "Rescue truth reaches NPC summary",
		rescue_ok and "rei" in gs.get_section("day1").get("rescued_npcs", []) and "rei" in rescued_ids)

	# 3: Foot-only warehouse route completes without KMF resource loss.
	r = await _fresh_round()
	gs = r.get("gs")
	d1 = r.get("d1")
	d1.discover_case("quest_supply_depot", {"sourceType": "testimony"})
	gs.set_player_location("industrial_area")
	gs.set_player_mode("foot")
	var kmf_before: Dictionary = gs.get_section("kmf")
	d1.perform_foot_action("observe", {"target": "supply_depot"})
	d1.perform_foot_action("stealth_move", {"location": "industrial_area"})
	d1.perform_foot_action("stealth_move", {"location": "industrial_area"})
	var depot_ok: bool = bool(d1.try_complete_case("quest_supply_depot", {}))
	var kmf_after: Dictionary = gs.get_section("kmf")
	_round_result(3, "Foot warehouse solution",
		depot_ok and str(d1.get_case_state("quest_supply_depot").get("result_reason", "")).begins_with("foot_")
		and kmf_before == kmf_after)

	# 4: KMF route charges energy, ammunition, durability and maintenance exactly once.
	r = await _fresh_round()
	gs = r.get("gs")
	d1 = r.get("d1")
	d1.discover_case("quest_supply_depot", {"sourceType": "testimony"})
	gs.set_player_location("industrial_area")
	gs.set_player_mode("kmf")
	kmf_before = gs.get_section("kmf")
	var kmf_result: Dictionary = d1.perform_kmf_action("combat_superiority", {"enemies": 3})
	kmf_after = gs.get_section("kmf")
	var kmf_depot_ok: bool = bool(d1.try_complete_case("quest_supply_depot", {}))
	_round_result(4, "KMF cost accounting",
		bool(kmf_result.get("ok", false)) and kmf_depot_ok
		and is_equal_approx(float(kmf_before.get("energy", 0.0)) - float(kmf_after.get("energy", 0.0)), 18.0)
		and int(kmf_before.get("ammo", 0)) - int(kmf_after.get("ammo", 0)) == 6
		and is_equal_approx(float(kmf_before.get("durability", 0.0)) - float(kmf_after.get("durability", 0.0)), 5.0)
		and float(kmf_after.get("maintenanceLoad", 0.0)) > float(kmf_before.get("maintenanceLoad", 0.0)))

	# 5: Deadline failure applies its world impact only once.
	r = await _fresh_round()
	gs = r.get("gs")
	d1 = r.get("d1")
	var hospital_deadline: int = int(d1.get_case_state("quest_hospital_medicine").get("deadline_abs_minute", gs.get_minute_of_day()))
	gs.advance_time(max(0, hospital_deadline - gs.get_minute_of_day() + 1))
	await process_frame
	var failed_hospital: Dictionary = d1.get_facility_state("hospital")
	var cap_once := float(failed_hospital.get("capacity", 0.0))
	d1.on_time_advanced(30)
	var cap_twice := float(d1.get_facility_state("hospital").get("capacity", 0.0))
	_round_result(5, "One-shot deadline consequence",
		str(d1.get_case_state("quest_hospital_medicine").get("status", "")) == "expired"
		and cap_once < 0.7 and is_equal_approx(cap_once, cap_twice))

	# 6: Re-querying a completed case succeeds without duplicating rewards.
	r = await _fresh_round()
	gs = r.get("gs")
	d1 = r.get("d1")
	_prepare_hospital(gs, d1)
	var first_complete: bool = bool(d1.try_complete_case("quest_hospital_medicine", {}))
	var first_capacity := float(d1.get_facility_state("hospital").get("capacity", 0.0))
	var second_complete: bool = bool(d1.try_complete_case("quest_hospital_medicine", {}))
	var second_capacity := float(d1.get_facility_state("hospital").get("capacity", 0.0))
	_round_result(6, "Completed case remains successful",
		first_complete and second_complete and is_equal_approx(first_capacity, second_capacity))

	# 7: Two Yui conversations and a KMF action reach relationship variables.
	r = await _fresh_round()
	gs = r.get("gs")
	d1 = r.get("d1")
	var map = r.get("main").get_node_or_null("MapManager")
	var player = r.get("main").get_node_or_null("Player")
	if map:
		map.refresh_npc_markers()
	var yui_pos: Vector2 = map.get_npc_marker_position("yui") if map else Vector2(-9999, -9999)
	if player and yui_pos.x > -9000:
		player.global_position = yui_pos
		gs.set_player_position(yui_pos)
		gs.set_player_location("base")
	var yui_first: bool = bool(d1.try_interact("yui"))
	var heroine_before_follow: Dictionary = gs.get_section("heroine")
	var yui_second: bool = bool(d1.try_interact("yui"))
	var heroine_after_follow: Dictionary = gs.get_section("heroine")
	gs.set_player_mode("kmf")
	var fear_before := int(heroine_after_follow.get("fear", 0))
	d1.perform_kmf_action("rubble_breakthrough", {})
	var heroine_after_kmf: Dictionary = gs.get_section("heroine")
	_round_result(7, "Yui conversation/action connection",
		yui_first and yui_second
		and int(heroine_after_follow.get("interactionTotal", 0)) > int(heroine_before_follow.get("interactionTotal", 0))
		and int(heroine_after_follow.get("trust", 0)) > int(heroine_before_follow.get("trust", 0))
		and int(heroine_after_kmf.get("fear", 0)) > fear_before)

	# 8: Digest is concise while raw KMF reports remain available and serializable.
	r = await _fresh_round()
	gs = r.get("gs")
	d1 = r.get("d1")
	gs.set_player_mode("kmf")
	d1.perform_kmf_action("high_speed_travel", {"to": "hospital"})
	d1.perform_kmf_action("high_speed_travel", {"to": "city_center"})
	d1.perform_kmf_action("high_speed_travel", {"to": "industrial_area"})
	var info = d1.get_node_or_null("Day1InformationSystem")
	var digest: Dictionary = info.get_latest_kmf_digest()
	var raw_reports: Array = info.get_all_kmf_buffered_reports()
	var info_saved: Dictionary = info.serialize()
	_round_result(8, "KMF digest with raw retention",
		int(digest.get("total_reports", 0)) == 3 and raw_reports.size() == 3
		and info_saved.get("kmf_reports_history", []).size() == 3)

	# 9: Save/load preserves canonical results and final feedback agrees with them.
	r = await _fresh_round()
	gs = r.get("gs")
	d1 = r.get("d1")
	_prepare_hospital(gs, d1)
	var final_complete: bool = bool(d1.try_complete_case("quest_hospital_medicine", {}))
	var save_manager = r.get("main").get_node_or_null("SaveManager")
	var round_trip_ok: bool = bool(save_manager.test_round_trip()) if save_manager else false
	summary_node = d1.get_node_or_null("Day1SummarySystem")
	var final_summary: Dictionary = summary_node.force_generate_summary()
	await process_frame
	info = d1.get_node_or_null("Day1InformationSystem")
	var feedback: Dictionary = info.get_day1_feedback()
	var feedback_hospital := false
	for case_data in feedback.get("completed_cases", []):
		if str(case_data.get("id", "")) == "quest_hospital_medicine":
			feedback_hospital = true
	var summary_hospital := false
	for case_data in final_summary.get("cases", {}).get("completed", []):
		if str(case_data.get("id", "")) == "quest_hospital_medicine":
			summary_hospital = true
	_round_result(9, "Save/load and final truth agreement",
		final_complete and round_trip_ok and feedback_hospital and summary_hospital
		and str(d1.get_facility_state("hospital").get("reason", "")) == "medicine_delivered")

	print("[NINE-ROUND] passed=%d failed=%d expected=%d" % [passed_rounds, failed_rounds, EXPECTED_ROUNDS])
	if passed_rounds + failed_rounds != EXPECTED_ROUNDS:
		print("[NINE-ROUND] INCOMPLETE")
		quit(2)
	elif failed_rounds > 0:
		quit(1)
	else:
		print("NINE-ROUND REGRESSION COMPLETE")
		quit(0)

