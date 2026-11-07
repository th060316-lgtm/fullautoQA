extends Node
## Current Day1 acceptance scene. Fail-closed and bound to the integrated Day1 API.

const EXPECTED_CHECKS: int = 13
var _passed: int = 0
var _failures: Array[String] = []
var _main: Node
var _day1: Node
var _map: Node
var _player: Node
var _save: Node
var _qm: Node

func _ready() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	if ok:
		_passed += 1
		print("[CI DAY1 PASS] " + label)
	else:
		_failures.append(label)
		print("[CI DAY1 FAIL] " + label)

func _tick(n: int = 1) -> void:
	for _i in range(n):
		await get_tree().process_frame
		await get_tree().physics_frame

func _run() -> void:
	print("=== CURRENT DAY1 CI ACCEPTANCE START ===")
	var packed: PackedScene = load("res://scenes/Main.tscn")
	_check(packed != null, "Main scene is loadable")
	if packed == null:
		_finish()
		return

	_main = packed.instantiate()
	add_child(_main)
	await _tick(5)
	_day1 = _main.find_child("Day1Controller", true, false)
	_map = _main.find_child("MapManager", true, false)
	_player = _main.find_child("Player", true, false)
	_save = _main.find_child("SaveManager", true, false)
	_qm = get_tree().root.get_node_or_null("QuestManager")

	_check(_day1 != null and _day1.has_method("is_initialized") and _day1.is_initialized(), "Day1Controller initialized")
	_check(_map != null and _map.has_method("get_navigation_position"), "MapManager navigation API exists")
	_check(_player != null and _save != null, "Player and SaveManager exist")
	_check(_qm != null, "QuestManager autoload exists")
	_check(InputMap.has_action("interact") and InputMap.has_action("board_kmf"), "Player input actions exist")

	var hospital: Dictionary = _day1.get_case_overview("quest_hospital_medicine") if _day1 else {}
	_check(not hospital.is_empty() and hospital.has("deadline_text") and hospital.has("travel_estimate"), "Canonical hospital overview is usable")

	var rescue: Dictionary = _day1.get_case_overview("quest_evacuation_rescue") if _day1 else {}
	_check(str(rescue.get("location_id", "")) == "city_center", "Rescue starts at city center")

	var t0: int = GameState.get_minute_of_day()
	if _map:
		_map._update_semantic_location(_map.get_navigation_position("hospital"))
		_map._update_semantic_location(_map.get_navigation_position("base"))
	_check(GameState.get_minute_of_day() == t0, "Semantic location changes do not consume hidden time")

	var yui_pos: Vector2 = _map.get_npc_marker_position("yui") if _map and _map.has_method("get_npc_marker_position") else Vector2(-9999, -9999)
	if _player and yui_pos.x > -9000:
		_player.global_position = yui_pos
		GameState.set_player_position(yui_pos)
		GameState.set_player_location("base")
	var talked: bool = bool(_day1.try_interact("yui")) if _day1 else false
	_check(talked and bool(GameState.get_section("day1").get("yui_talked", false)), "Physical Yui interaction updates canonical Day1 state")

	var duplicate := false
	if _qm:
		for row in _qm.get_available_quests() + _qm.get_active_quests():
			if str(row.get("id", "")) in ["quest_hospital_medicine", "quest_evacuation_rescue", "quest_supply_depot"]:
				duplicate = true
	_check(not duplicate, "Legacy QuestManager does not duplicate Day1 cases")
	_check(_day1 != null and not str(_day1.get_current_objective()).is_empty(), "Current objective is never blank")
	_check(_save != null and bool(_save.test_round_trip()), "Save/Load round-trip succeeds")

	_finish()

func _finish() -> void:
	var ran: int = _passed + _failures.size()
	print("[CI DAY1] ran=%d expected=%d passed=%d failed=%d" % [ran, EXPECTED_CHECKS, _passed, _failures.size()])
	if ran == EXPECTED_CHECKS and _failures.is_empty():
		print("CURRENT DAY1 CI ACCEPTANCE: PASSED")
		get_tree().quit(0)
	else:
		print("CURRENT DAY1 CI ACCEPTANCE: FAILED")
		get_tree().quit(1)
