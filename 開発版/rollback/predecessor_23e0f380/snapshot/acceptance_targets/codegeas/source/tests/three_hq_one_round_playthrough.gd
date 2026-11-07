extends SceneTree

var scenario: String = ""
var main: Node
var player: Node
var d1: Node
var map: Node
var info: Node
var summary_system: Node
var gs: Node
var validation_errors: Array[String] = []

const POS := {
	"base": Vector2(80, 80),
	"hospital": Vector2(256, 240),
	"city_center": Vector2(576, 352),
	"industrial_area": Vector2(960, 272),
	"evacuation_center": Vector2(352, 688),
	"maintenance": Vector2(1120, 112),
}

func _init() -> void:
	scenario = OS.get_environment("PLAY_SCENARIO")
	if scenario == "":
		scenario = "prod_ceo"
	call_deferred("_run")

func _frames(count: int = 2) -> void:
	for _i in range(count):
		await process_frame
		await physics_frame

func _event(label: String, detail: Variant = null) -> void:
	var suffix := ""
	if detail != null:
		suffix = " | " + JSON.stringify(detail)
	print("PLAY|%s|%s|%s%s" % [scenario, gs.get_time_string(), label, suffix])

func _boot() -> bool:
	gs = get_root().get_node_or_null("GameState")
	if gs == null:
		push_error("playthrough: GameState autoload missing")
		return false
	var packed = load("res://scenes/Main.tscn")
	if packed == null:
		push_error("playthrough: Main.tscn load failed")
		return false
	main = packed.instantiate()
	get_root().add_child(main)
	await _frames(3)
	player = main.get_node_or_null("Player")
	d1 = main.get_node_or_null("Day1Controller")
	map = main.get_node_or_null("MapManager")
	if d1 == null or player == null or map == null:
		push_error("playthrough: required runtime nodes missing")
		return false
	info = d1.get_node_or_null("Day1InformationSystem")
	summary_system = d1.get_node_or_null("Day1SummarySystem")
	_event("BOOT", {
		"known_cases": d1.get_known_cases(),
		"objective": d1.get_current_objective(),
		"deadline": d1.get_deadline_text(),
	})
	return true

func _set_mode(mode: String) -> void:
	if gs.get_player_mode() != mode:
		gs.set_player_mode(mode)
		await _frames(1)
	_event("MODE", mode)

func _set_location(location_id: String) -> void:
	gs.set_player_location(location_id)
	var pos: Vector2 = POS.get(location_id, Vector2(80, 80))
	player.global_position = pos
	gs.set_player_position(pos)
	if map.has_method("refresh_npc_markers"):
		map.refresh_npc_markers()
	await _frames(2)

func _travel(location_id: String, mode: String) -> void:
	await _set_mode(mode)
	if mode == "kmf":
		d1.perform_kmf_action("high_speed_travel", {"to": location_id})
	else:
		gs.advance_time(12)
	await _set_location(location_id)
	_event("TRAVEL", {"to": location_id, "mode": mode})

func _approach_npc(npc_id: String) -> bool:
	if map.has_method("refresh_npc_markers"):
		map.refresh_npc_markers()
	await _frames(1)
	var pos: Vector2 = map.get_npc_marker_position(npc_id) if map.has_method("get_npc_marker_position") else Vector2(-9999, -9999)
	if pos.x < -9000:
		_event("NPC_NOT_FOUND", npc_id)
		return false
	player.global_position = pos
	gs.set_player_position(pos)
	await _frames(1)
	return true

func _talk(npc_id: String) -> bool:
	var approached: bool = bool(await _approach_npc(npc_id))
	if not approached:
		return false
	var ok: bool = d1.try_interact(npc_id)
	await _frames(2)
	_event("INTERACT", {"npc": npc_id, "ok": ok})
	return ok

func _wait(minutes: int, reason: String) -> void:
	gs.advance_time(minutes)
	await _frames(2)
	_event("WAIT", {"minutes": minutes, "reason": reason})

func _brief(talk_yui: bool = true, take_medicine: bool = true) -> void:
	await _set_location("base")
	await _set_mode("foot")
	if talk_yui:
		await _talk("yui")
	if take_medicine:
		await _talk("aoi")

func _rescue(mode: String) -> void:
	await _travel("city_center", mode)
	await _talk("rei")
	await _travel("evacuation_center", mode)
	await _talk("sakura")
	_event("CASE_RESCUE_STATE", d1.get_case_state("quest_evacuation_rescue"))

func _hospital(mode: String) -> void:
	await _travel("hospital", mode)
	var ok: bool = bool(await _talk("aoi"))
	if not ok:
		_event("HOSPITAL_INTERACTION_FAILED", d1.get_case_state("quest_hospital_medicine"))
	_event("CASE_HOSPITAL_STATE", d1.get_case_state("quest_hospital_medicine"))

func _supply(mode: String, inspect_first: bool = true) -> void:
	await _travel("industrial_area", mode)
	if inspect_first and info and info.has_method("check_contradiction_at_location"):
		info.check_contradiction_at_location("industrial_area")
		await _frames(2)
		_event("DIRECT_OBSERVATION")
	if mode == "kmf":
		d1.perform_kmf_action("combat_superiority", {"enemies": 3})
	else:
		d1.perform_foot_action("stealth_move", {"location": "industrial_area"})
	await _frames(2)
	var completed: bool = bool(d1.try_complete_case("quest_supply_depot", {
		"enemies_cleared": bool(gs.get_section("day1").get("supply_cleared", false))
	}))
	await _frames(2)
	_event("CASE_SUPPLY_STATE", {"completed_call": completed, "state": d1.get_case_state("quest_supply_depot")})

func _run_prod_ceo() -> void:
	await _brief(true, true)
	await _rescue("kmf")
	await _hospital("kmf")
	await _supply("kmf", true)

func _run_prod_board() -> void:
	await _brief(true, true)
	await _supply("foot", true)
	await _rescue("foot")
	await _hospital("foot")

func _run_prod_general() -> void:
	await _brief(true, false)
	await _hospital("kmf")
	await _travel("base", "kmf")
	await _set_mode("foot")
	await _talk("aoi")
	await _hospital("kmf")
	await _rescue("kmf")
	await _supply("kmf", true)

func _run_sales_ceo() -> void:
	await _brief(true, true)
	await _rescue("kmf")
	await _supply("foot", true)
	await _hospital("kmf")

func _run_sales_board() -> void:
	await _brief(true, true)
	await _rescue("foot")
	await _hospital("foot")
	await _supply("foot", true)

func _run_sales_general() -> void:
	await _brief(true, false)
	await _wait(20, "read reports / hesitate")
	await _supply("kmf", true)
	await _hospital("kmf")
	await _travel("base", "kmf")
	await _set_mode("foot")
	await _talk("aoi")

func _run_mgmt_ceo() -> void:
	await _brief(true, true)
	await _wait(10, "observe world before committing")
	await _travel("industrial_area", "foot")
	if info and info.has_method("check_contradiction_at_location"):
		info.check_contradiction_at_location("industrial_area")
		await _frames(2)
	d1.perform_foot_action("observe", {"target": "supply_depot"})
	await _frames(2)
	await _rescue("foot")
	await _hospital("foot")
	await _supply("foot", false)

func _run_mgmt_board() -> void:
	await _brief(true, true)
	await _hospital("foot")
	await _wait(10, "watch facility / reports")
	await _supply("foot", true)
	await _rescue("foot")

func _run_mgmt_general() -> void:
	await _brief(true, true)
	await _rescue("foot")
	await _hospital("foot")
	await _wait(20, "uncertain about new supply report")

func _finish_round() -> void:
	var now: int = int(gs.get_minute_of_day())
	if gs.get_day() == 1 and now < 22 * 60:
		gs.advance_time(22 * 60 - now)
		await _frames(3)
	var summary: Dictionary = gs.get_section("day1").get("summary", {})
	if summary.is_empty() and summary_system and summary_system.has_method("force_generate_summary"):
		summary = summary_system.force_generate_summary()
		await _frames(1)
	var day1: Dictionary = gs.get_section("day1")
	var heroine: Dictionary = gs.get_section("heroine")
	var player_state: Dictionary = gs.get_section("player")
	var kmf: Dictionary = gs.get_section("kmf")
	var reports: Array = gs.get_reports()
	var facts: Dictionary = gs.get_system_facts()
	_event("FINAL_CASES", day1.get("case_states", {}))
	_event("FINAL_FACILITIES", day1.get("facilities", {}))
	_event("FINAL_RELATION", {
		"interactionTotal": heroine.get("interactionTotal", 0),
		"trust": heroine.get("trust", 0),
		"fear": heroine.get("fear", 0),
		"affection_hidden": heroine.get("affection", 0),
	})
	_event("FINAL_RESOURCES", {
		"hp": player_state.get("hp", 0),
		"fatigue": player_state.get("fatigue", 0),
		"food": player_state.get("food", 0),
		"kmf_energy": kmf.get("energy", 0),
		"kmf_ammo": kmf.get("ammo", 0),
		"kmf_exposure": day1.get("kmf_exposure", 0),
	})
	_event("FINAL_INFO", {
		"reports": reports.size(),
		"systemFacts": facts.size(),
		"actions": day1.get("actions", []).size(),
		"summary_generated": not summary.is_empty(),
	})
	print("SUMMARY_JSON|%s|%s" % [scenario, JSON.stringify(summary)])
	# Verify end-of-Day1 state rather than only script completion.
	var outcomes: Dictionary = summary.get("cases", {})
	var case_total := 0
	for status_key in ["completed", "failed", "expired", "active"]:
		case_total += (outcomes.get(status_key, []) as Array).size()
	if summary.is_empty() or case_total != 3:
		validation_errors.append("Day1 summary missing or unexpected case count: %d" % case_total)
	if gs.get_day() == 1 and gs.get_minute_of_day() < 22 * 60:
		validation_errors.append("Day1 ended before required deadline")
	if validation_errors.is_empty():
		print("SCENARIO_VALIDATED %s" % scenario)
	else:
		for problem in validation_errors:
			print("SCENARIO_VALIDATION_FAILED %s: %s" % [scenario, problem])
	print("PLAYTHROUGH COMPLETE %s" % scenario)

func _run() -> void:
	print("=== THREE HQ ONE-ROUND PLAYTHROUGH: %s ===" % scenario)
	if not await _boot():
		quit(2)
		return
	match scenario:
		"prod_ceo":
			await _run_prod_ceo()
		"prod_board":
			await _run_prod_board()
		"prod_general":
			await _run_prod_general()
		"sales_ceo":
			await _run_sales_ceo()
		"sales_board":
			await _run_sales_board()
		"sales_general":
			await _run_sales_general()
		"mgmt_ceo":
			await _run_mgmt_ceo()
		"mgmt_board":
			await _run_mgmt_board()
		"mgmt_general":
			await _run_mgmt_general()
		_:
			push_error("Unknown PLAY_SCENARIO: " + scenario)
			quit(3)
			return
	await _finish_round()
	quit(0 if validation_errors.is_empty() else 1)
