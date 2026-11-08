extends SceneTree
## Current integrated Day1 fail-closed acceptance.
const EXPECTED_CHECKS: int = 13
var _passed: int = 0
var _failed: Array[String] = []

func _check(ok: bool, label: String) -> void:
	if ok:
		_passed += 1
		print("[DAY1 ACCEPT PASS] " + label)
	else:
		_failed.append(label)
		print("[DAY1 ACCEPT FAIL] " + label)

func _init() -> void:
	call_deferred("_run")

func _tick(n: int = 1) -> void:
	for _i in range(n):
		await process_frame
		await physics_frame

func _run() -> void:
	var gs: Node = get_root().get_node_or_null("GameState")
	if gs and gs.has_method("_init_default_state"):
		gs._init_default_state()

	var packed: PackedScene = load("res://scenes/Main.tscn")
	_check(packed != null, "Main scene loads")
	if packed == null:
		_finish()
		return
	var main: Node = packed.instantiate()
	get_root().add_child(main)
	await _tick(5)

	var d1: Node = main.find_child("Day1Controller", true, false)
	var info: Node = main.find_child("Day1InformationSystem", true, false)
	var map: Node = main.find_child("MapManager", true, false)
	var player: Node = main.find_child("Player", true, false)
	var save: Node = main.find_child("SaveManager", true, false)
	var qm: Node = get_root().get_node_or_null("QuestManager")

	_check(d1 != null and d1.is_initialized(), "Day1 controller initialized")
	_check(info != null and info.has_method("get_known_case_overviews"), "Information system uses current case API")
	_check(map != null and map.has_method("get_navigation_position"), "Map navigation API exists")
	_check(player != null and save != null and qm != null, "Player SaveManager QuestManager are present")

	var day1: Dictionary = gs.get_section("day1")
	_check(int(day1.get("schema_version", 0)) == 3, "Day1 schema is current")
	_check(not str(day1.get("current_objective", "")).is_empty(), "Current objective exists")

	var rescue: Dictionary = d1.get_case_overview("quest_evacuation_rescue")
	_check(str(rescue.get("location_id", "")) == "city_center" and rescue.has("remaining_text"), "Rescue overview is canonical")

	var time_before: int = gs.get_minute_of_day()
	map._update_semantic_location(map.get_navigation_position("hospital"))
	map._update_semantic_location(map.get_navigation_position("base"))
	_check(gs.get_minute_of_day() == time_before, "Map boundary movement does not advance time")

	var supply_state: Dictionary = d1.get_case_state("quest_supply_depot")
	_check(supply_state.has("stage") and supply_state.has("deadline_abs_minute"), "Supply case has current stage/deadline schema")

	var duplicate := false
	for row in qm.get_available_quests() + qm.get_active_quests():
		if str(row.get("id", "")) in ["quest_hospital_medicine", "quest_evacuation_rescue", "quest_supply_depot"]:
			duplicate = true
	_check(not duplicate, "Legacy quest lists exclude canonical Day1 cases")

	var before_result: String = d1.get_result_summary()
	_check(before_result != "---" and not before_result.is_empty(), "Result summary never exposes placeholder")
	_check(bool(save.test_round_trip()), "Save/Load logical round-trip passes")

	_finish()

func _finish() -> void:
	var ran: int = _passed + _failed.size()
	print("[DAY1 ACCEPT] ran=%d expected=%d passed=%d failed=%d" % [ran, EXPECTED_CHECKS, _passed, _failed.size()])
	if ran == EXPECTED_CHECKS and _failed.is_empty():
		print("DAY1 ACCEPTANCE CURRENT: PASSED")
		quit(0)
	else:
		print("DAY1 ACCEPTANCE CURRENT: FAILED")
		quit(1)
