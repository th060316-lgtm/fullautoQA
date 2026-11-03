# Phase A integrated acceptance
extends SceneTree

const EXPECTED_CHECKS := 22
var failures: Array[String] = []
var ran := 0

func _init() -> void:
	call_deferred("_run")

func check(name: String, condition: bool) -> void:
	ran += 1
	if condition:
		print("[PASS] ", name)
	else:
		failures.append(name)
		print("[FAIL] ", name)

func _run() -> void:
	print("=== PHASE A INTEGRATED ACCEPTANCE ===")
	var gs = get_root().get_node_or_null("GameState")
	var eb = get_root().get_node_or_null("EventBus")
	var nm = get_root().get_node_or_null("NpcManager")
	var ms = get_root().get_node_or_null("MemorySystem")
	var packed = load("res://scenes/Main.tscn")
	check("Main scene loads", packed != null)
	if packed == null:
		_finish()
		return

	var main = packed.instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame

	var d1 = main.get_node_or_null("Day1Controller")
	check("Day1Controller node exists", d1 != null)
	if d1 == null:
		_finish()
		return
	check("Day1 initialized", d1.has_method("is_initialized") and d1.is_initialized())

	var known = d1.get_known_cases() if d1.has_method("get_known_cases") else []
	check("Initial known cases = 2", known.size() == 2)
	check("Supply hidden initially", "quest_supply_depot" not in known)

	var info = d1.get_node_or_null("Day1InformationSystem")
	var cons = d1.get_node_or_null("Day1ConsequenceSystem")
	var summary = d1.get_node_or_null("Day1SummarySystem")
	check("Information module attached", info != null)
	check("Consequence module attached", cons != null)
	check("Summary module attached", summary != null)

	# Physical proximity: semantic co-location alone is not enough.
	var map = main.get_node_or_null("MapManager")
	var player = main.get_node_or_null("Player")
	if map and map.has_method("refresh_npc_markers"):
		map.refresh_npc_markers()
	gs.set_player_location("base")
	if player:
		player.global_position = Vector2(8, 8)
		gs.set_player_position(player.global_position)
	check("Distant same-region NPC cannot be interacted", d1.try_interact("yui") == false)
	var yui_pos = map.get_npc_marker_position("yui") if map and map.has_method("get_npc_marker_position") else Vector2(-9999, -9999)
	if player and yui_pos.x > -9000:
		player.global_position = yui_pos
		gs.set_player_position(yui_pos)
	check("Nearby NPC can be interacted", d1.try_interact("yui"))

	# Information reaches the player after time has actually passed; hidden case
	# must not be part of initial awareness.
	gs.advance_time(20)
	await process_frame
	known = d1.get_known_cases()
	check("Supply case discoverable from information", "quest_supply_depot" in known)

	# Opportunity cost: use the rescue window on unrelated KMF work.
	gs.set_player_mode("kmf")
	var other_work_1 = d1.perform_kmf_action("combat_superiority", {"enemies": 3})
	var other_work_2 = d1.perform_kmf_action("rescue_transport", {"from": "industrial_area", "to": "base"})
	check("Competing KMF actions consume time", bool(other_work_1.get("ok", false)) and bool(other_work_2.get("ok", false)))
	# Deadline length is canonical Day1 data. Advance remaining opportunity cost rather
	# than assuming the retired 09:05 deadline.
	var rescue_deadline: int = int(d1.get_case_state("quest_evacuation_rescue").get("deadline_abs_minute", gs.get_minute_of_day()))
	if gs.get_minute_of_day() <= rescue_deadline:
		gs.advance_time(rescue_deadline - gs.get_minute_of_day() + 1)
		await process_frame
	check("Choosing other work can expire rescue", str(d1.get_case_state("quest_evacuation_rescue").get("status", "")) in ["expired", "failed"])

	# Hospital must not complete from base.
	var hosp_before = d1.get_case_state("quest_hospital_medicine")
	var bad_complete = d1.try_complete_case("quest_hospital_medicine", {})
	check("Hospital cannot complete from base", not bad_complete and d1.get_case_state("quest_hospital_medicine").get("status") != "completed")

	# KMF action should create consequence exactly once.
	gs.set_player_mode("kmf")
	var a = d1.record_action("kmf_test", {"mode": "kmf", "noise": 10.0, "visible": true})
	await process_frame
	var exposure1 = float(gs.get_section("day1").get("kmf_exposure", 0.0))
	if eb.has_signal("day1_action_committed"):
		eb.day1_action_committed.emit(a)
	await process_frame
	var exposure2 = float(gs.get_section("day1").get("kmf_exposure", 0.0))
	check("KMF consequence applied", exposure1 > 0.0)
	check("KMF duplicate action ignored", is_equal_approx(exposure1, exposure2))

	# Non-protagonist death must not kill player and should propagate.
	var before_player_alive = gs.is_player_alive()
	nm.kill_npc("aoi")
	await process_frame
	check("NPC death does not GameOver", before_player_alive and gs.is_player_alive())
	var hospital = d1.get_facility_state("hospital")
	check("NPC death affects facility", str(hospital.get("reason", "")) != "")

	# Direct observation/system fact invariants.
	if info and info.has_method("check_contradiction_at_location"):
		info.check_contradiction_at_location("industrial_area")
	await process_frame
	check("Direct observation system fact recorded", ms.has_system_fact("day1_supply_depot_observation"))

	# Summary contains no affection field.
	var s = summary.force_generate_summary() if summary and summary.has_method("force_generate_summary") else {}
	check("Summary generated", not s.is_empty())
	check("Summary hides affection", "affection" not in JSON.stringify(s).to_lower())

	# Save/load exact round-trip.
	var sm = main.get_node_or_null("SaveManager")
	check("SaveManager round-trip", sm != null and sm.test_round_trip())

	_finish()

func _finish() -> void:
	print("Ran %d / %d; failures=%d" % [ran, EXPECTED_CHECKS, failures.size()])
	if ran != EXPECTED_CHECKS:
		print("INCOMPLETE")
		quit(2)
		return
	if not failures.is_empty():
		for f in failures:
			print("  FAIL: ", f)
		quit(1)
		return
	print("ALL CHECKS PASSED")
	quit(0)
