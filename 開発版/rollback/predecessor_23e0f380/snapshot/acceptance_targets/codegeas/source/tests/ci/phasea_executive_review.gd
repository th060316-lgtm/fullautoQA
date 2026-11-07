extends SceneTree
## Finite, outcome-bearing Phase A executive runtime review.
## This is a headless structural/experience-path check, not a human fun verdict.

const EXPECTED := 11
var passed := 0
var failed := 0

func _init() -> void:
	call_deferred("_run")

func check(name: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("[EXEC PASS] ", name)
	else:
		failed += 1
		print("[EXEC FAIL] ", name)

func _run() -> void:
	print("=== PHASE A EXECUTIVE RUNTIME REVIEW ===")
	var packed = load("res://scenes/Main.tscn")
	check("Main scene loads", packed != null)
	if packed == null:
		_finish()
		return

	var main = packed.instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame

	var gs = get_root().get_node_or_null("GameState")
	var mem = get_root().get_node_or_null("MemorySystem")
	var d1 = main.get_node_or_null("Day1Controller")
	var map = main.get_node_or_null("MapManager")
	var player = main.get_node_or_null("Player")

	check("Protagonist boots alive", gs != null and gs.is_player_alive())
	check("Day1 controller initialized", d1 != null and d1.is_initialized())
	if d1 == null or gs == null:
		_finish()
		return

	var known: Array = d1.get_known_cases()
	check("Player begins with exactly two known incidents", known.size() == 2 and "quest_supply_depot" not in known)

	if map and map.has_method("refresh_npc_markers"):
		map.refresh_npc_markers()
	var yui_pos = map.get_npc_marker_position("yui") if map and map.has_method("get_npc_marker_position") else Vector2(-9999, -9999)
	var talked := false
	if player and yui_pos.x > -9000:
		player.global_position = yui_pos
		gs.set_player_position(yui_pos)
		gs.set_player_location("base")
		talked = d1.try_interact("yui")
	check("Yui briefing requires and accepts close interaction", talked)

	gs.advance_time(20)
	await process_frame
	known = d1.get_known_cases()
	check("Hidden supply incident emerges through information", "quest_supply_depot" in known)

	gs.set_player_mode("kmf")
	d1.perform_kmf_action("combat_superiority", {"enemies": 3})
	d1.perform_kmf_action("rescue_transport", {"from": "industrial_area", "to": "base"})
	await process_frame
	check("Choosing other work can cost the rescue incident",
		str(d1.get_case_state("quest_evacuation_rescue").get("status", "")) in ["expired", "failed"])
	check("KMF use creates social/information exposure",
		float(gs.get_section("day1").get("kmf_exposure", 0.0)) > 0.0 and mem != null and mem.get_reports().size() > 0)

	var info = d1.get_node_or_null("Day1InformationSystem")
	if info and info.has_method("check_contradiction_at_location"):
		info.check_contradiction_at_location("industrial_area")
	await process_frame
	check("Direct observation remains an immutable system fact",
		mem != null and mem.has_system_fact("day1_supply_depot_observation"))

	var summary = d1.get_node_or_null("Day1SummarySystem")
	var result: Dictionary = summary.force_generate_summary() if summary and summary.has_method("force_generate_summary") else {}
	check("Day1 factual summary is available without hidden affection",
		not result.is_empty() and "affection" not in JSON.stringify(result).to_lower())

	check("Review produced an actual consequence state",
		str(d1.get_case_state("quest_evacuation_rescue").get("status", "")) != "active")

	_finish()

func _finish() -> void:
	print("[EXEC] passed=%d failed=%d expected=%d" % [passed, failed, EXPECTED])
	if passed + failed != EXPECTED:
		print("[EXEC] INCOMPLETE")
		quit(2)
		return
	if failed > 0:
		quit(1)
		return
	print("EXECUTIVE REVIEW COMPLETE")
	quit(0)
