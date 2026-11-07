extends SceneTree
## Regression lock for findings from the external adversarial Day1 audit.
var failed: int = 0

func _check(ok: bool, label: String) -> void:
	if ok:
		print("[MISTRAL REG PASS] " + label)
	else:
		print("[MISTRAL REG FAIL] " + label)
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
	_check(packed != null, "Main scene and integration entry are present")
	if packed == null:
		quit(1)
		return

	var main: Node = packed.instantiate()
	get_root().add_child(main)
	await _tick(5)

	var d1: Node = main.find_child("Day1Controller", true, false)
	var info: Node = main.find_child("Day1InformationSystem", true, false)
	var summary: Node = main.find_child("Day1SummarySystem", true, false)
	var consequence: Node = main.find_child("Day1ConsequenceSystem", true, false)
	var qm: Node = get_root().get_node_or_null("QuestManager")
	_check(d1 != null and d1.is_initialized(), "Canonical Day1 controller initialized")
	_check(info != null and summary != null and consequence != null, "Day1 integration modules are present")

	# M01: resolved Day1 IDs must never reappear through the legacy Day3 schedule.
	if qm and qm.has_method("on_time_tick"):
		qm.on_time_tick(3, 0)
	var later_available: Array = qm.get_available_quests() if qm else []
	var later_active: Array = qm.get_active_quests() if qm else []
	var duplicate_day1 := false
	for row in later_available + later_active:
		if str(row.get("id", "")) in ["quest_hospital_medicine", "quest_evacuation_rescue", "quest_supply_depot"]:
			duplicate_day1 = true
	_check(not duplicate_day1, "Day1 case IDs do not respawn as legacy Day3 quests")

	# M02: one stealth action cannot instantly clear the supply depot.
	d1.discover_case("quest_supply_depot", {"source": "regression"})
	gs.set_player_location("industrial_area")
	gs.set_player_mode("foot")
	var stealth: Dictionary = d1.perform_foot_action("stealth_move", {"location": "industrial_area"})
	var dstate: Dictionary = gs.get_section("day1")
	var one_press_cleared: bool = bool(dstate.get("supply_cleared", false))
	var one_press_complete: bool = bool(d1.try_complete_case("quest_supply_depot", {
		"enemies_cleared": bool(stealth.get("cleared", false))
	}))
	_check(not one_press_cleared and not one_press_complete, "One foot stealth action cannot auto-complete supply depot")

	# M03: exposure has one canonical writer and consequence mirror matches it.
	var kmf: Dictionary = gs.get_section("kmf")
	kmf["owned"] = true
	kmf["durability"] = maxf(50.0, float(kmf.get("durability", 100.0)))
	kmf["energy"] = maxf(50.0, float(kmf.get("energy", 100.0)))
	gs.set_section("kmf", kmf)
	gs.set_player_mode("kmf")
	var exp_before: float = float(gs.get_section("day1").get("kmf_exposure", 0.0))
	var kmf_action: Dictionary = d1.perform_kmf_action("high_speed_travel", {"to": "city_center"})
	var exp_after: float = float(gs.get_section("day1").get("kmf_exposure", 0.0))
	var expected_delta: float = float(kmf_action.get("noise", 0.0)) * 0.8
	_check(bool(kmf_action.get("ok", false)) and is_equal_approx(exp_after - exp_before, expected_delta),
		"KMF exposure increments exactly once")
	_check(is_equal_approx(float(consequence.get_kmf_exposure()), exp_after),
		"Consequence summary mirrors canonical KMF exposure")

	# M05/M06: known cases remain visible without runtime-only discovery flags,
	# and overview schema/destination are canonical for the UI.
	var rows: Array = info.get_known_case_overviews() if info else []
	var supply_visible := false
	for row in rows:
		if str(row.get("id", "")) == "quest_supply_depot":
			supply_visible = true
	_check(supply_visible, "Known supply case is visible from canonical state")

	var hospital: Dictionary = d1.get_case_overview("quest_hospital_medicine")
	_check(hospital.has("remaining_text") and hospital.has("deadline_text") and hospital.has("travel_estimate"),
		"Case overview exposes the UI schema from one canonical source")

	var rescue_before: Dictionary = d1.get_case_overview("quest_evacuation_rescue")
	_check(str(rescue_before.get("location_id", "")) == "city_center",
		"Rescue destination starts at city_center")
	d1.advance_stage("quest_evacuation_rescue", "rescued")
	var rescue_after: Dictionary = d1.get_case_overview("quest_evacuation_rescue")
	_check(str(rescue_after.get("location_id", "")) == "evacuation_center",
		"Rescue destination switches to evacuation center after rescue")

	# Minor: Aoi conversation state persists in the canonical Day1 state.
	var player: Node = main.find_child("Player", true, false)
	var map: Node = main.find_child("MapManager", true, false)
	gs.set_player_mode("foot")
	var aoi_pos: Vector2 = map.get_npc_marker_position("aoi") if map and map.has_method("get_npc_marker_position") else Vector2.ZERO
	if player:
		player.global_position = aoi_pos
		gs.set_player_position(aoi_pos)
	gs.set_player_location("base")
	var aoi_talk_ok: bool = bool(d1.try_interact("aoi"))
	_check(aoi_talk_ok and bool(gs.get_section("day1").get("aoi_talked", false)),
		"Aoi conversation flag persists in canonical Day1 state")

	# F-03: a legacy save without _day1Runtime must still migrate to the
	# current Day1 schema/deadlines/stages during load.
	var save_manager: Node = main.find_child("SaveManager", true, false)
	var legacy_snapshot: Dictionary = gs.get_snapshot()
	var legacy_day1: Dictionary = legacy_snapshot.get("day1", {}).duplicate(true)
	legacy_day1["schema_version"] = 2
	legacy_day1.erase("end_result")
	var legacy_states: Dictionary = legacy_day1.get("case_states", {})
	for cid in legacy_states.keys():
		var st: Dictionary = legacy_states[cid]
		st.erase("stage")
		if cid == "quest_evacuation_rescue":
			st["deadline_abs_minute"] = 9 * 60 + 5
		elif cid == "quest_hospital_medicine":
			st["deadline_abs_minute"] = 9 * 60 + 20
		elif cid == "quest_supply_depot":
			st["deadline_abs_minute"] = 9 * 60 + 40
		legacy_states[cid] = st
	legacy_day1["case_states"] = legacy_states
	legacy_snapshot["day1"] = legacy_day1
	var legacy_file := FileAccess.open("user://saves/_legacy_day1_no_runtime.json", FileAccess.WRITE)
	var legacy_written: bool = legacy_file != null
	if legacy_file:
		legacy_file.store_string(JSON.stringify(legacy_snapshot, "\t"))
		legacy_file.close()
	var legacy_loaded: bool = legacy_written and save_manager != null and bool(save_manager.load_game("_legacy_day1_no_runtime"))
	var migrated_day1: Dictionary = gs.get_section("day1")
	var migrated_rescue: Dictionary = d1.get_case_state("quest_evacuation_rescue")
	_check(legacy_loaded
		and int(migrated_day1.get("schema_version", 0)) == 3
		and int(migrated_rescue.get("deadline_abs_minute", 0)) == 10 * 60 + 30
		and migrated_rescue.has("stage"),
		"Legacy save without Day1 runtime migrates to current schema")

	# Minor: terminal statuses cannot be forged through generic advance_stage.
	_check(not bool(d1.advance_stage("quest_supply_depot", "completed")),
		"Generic stage API cannot forge terminal completion")

	# M04 + result display: any Day1 summary/end feedback must finalize result first.
	var generated: Dictionary = summary.generate_day1_summary() if summary else {}
	_check(not generated.is_empty(), "Day1 summary generated")
	_check(not d1.get_end_result().is_empty() and d1.get_result_summary() != "---",
		"Day1 end result is finalized before summary/UI")

	print("MISTRAL FINDINGS REGRESSION: " + ("PASSED" if failed == 0 else "FAILED"))
	quit(0 if failed == 0 else 1)
