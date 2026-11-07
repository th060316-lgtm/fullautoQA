# Day1SummarySystem.gd
# MiniMax Phase A: Day1 factual summary generation
# Generates summary at Day1 end WITHOUT revealing correct routes or hidden truths
# Contract: EXT-20261019-015_MINIMAX_PHASEA_INFO_CONSEQUENCE_50

extends Node

var _gs: Node
var _eb: Node
var _ms: Node
var _nm: Node
var _cs: Node
var _info: Node

## Summary state
var _summary_generated: bool = false
var _current_summary: Dictionary = {}

## Summary categories
enum SummaryCategory {
	CASES,
	NPCS,
	FACILITIES,
	KMF_STATE,
	DIRECT_OBSERVATIONS,
}

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_ms = get_node_or_null("/root/MemorySystem")
	_nm = get_node_or_null("/root/NpcManager")
	_cs = _find_sibling_module("Day1ConsequenceSystem")
	_info = _find_sibling_module("Day1InformationSystem")

	_connect_signals()

func _find_sibling_module(module_name: String) -> Node:
	var p = get_parent()
	if p:
		return p.get_node_or_null(module_name)
	return null

func _connect_signals() -> void:
	if _eb == null:
		return

	# Connect to time system to detect Day1 end
	if _eb.has_signal("time_advanced"):
		_eb.time_advanced.connect(_on_time_advanced)

func _connect_signals_extended() -> void:
	# Additional signal connections for Day1 end detection
	pass

## Handle time advancement - check for Day1 end
func _on_time_advanced(minutes: int) -> void:
	if _summary_generated:
		return

	var current_day = _gs.get_day() if _gs else 1
	var current_minute = _gs.get_minute_of_day() if _gs else 0

	# Day1 gameplay closes at the shared hard deadline (22:00), or on Day2.
	var day1 = _gs.get_section("day1") if _gs else {}
	var hard_deadline: int = int(day1.get("hard_deadline", 22 * 60))
	if current_day > 1 or (current_day == 1 and current_minute >= hard_deadline):
		generate_day1_summary()

## Generate Day1 summary
func generate_day1_summary() -> Dictionary:
	if _summary_generated:
		return _current_summary

	# A result must be finalized before any Day1 end/summary UI is emitted.
	var d1 = get_tree().root.find_child("Day1Controller", true, false) if get_tree() else null
	if d1 and d1.has_method("finalize_day1_result"):
		d1.finalize_day1_result()

	var day1 = _gs.get_section("day1") if _gs else {}

	_current_summary = {
		"generated": true,
		"day": 1,
		"generated_at_minute": _gs.get_minute_of_day() if _gs else 1440,
		"cases": _summarize_cases(day1),
		"npcs": _summarize_npcs(),
		"facilities": _summarize_facilities(),
		"kmf_state": _summarize_kmf_state(),
		"direct_observations": _summarize_direct_observations(),
		"kmf_exposure": _get_kmf_exposure_summary(),
		"consequences": _summarize_consequences(),
	}

	_summary_generated = true

	# Save to GameState
	if _gs:
		var day1_section = _gs.get_section("day1")
		if not day1_section.is_empty():
			day1_section["summary"] = _current_summary.duplicate(true)
			_gs.set_section("day1", day1_section)

	# Emit summary ready event
	if _eb and _eb.has_signal("day1_summary_ready"):
		_eb.day1_summary_ready.emit(_current_summary.duplicate(true))

	print("[Day1Summary] Summary generated")
	return _current_summary

## Summarize case outcomes
func _summarize_cases(day1: Dictionary) -> Dictionary:
	var result = {
		"completed": [],
		"failed": [],
		"expired": [],
		"active": [],
	}

	# Get case states from day1 section
	var case_states = day1.get("case_states", {})
	var accepted_cases = day1.get("accepted_cases", [])
	var completed_cases = day1.get("completed", [])

	# Process each known case
	for case_id in case_states:
		var state = case_states[case_id]
		var status = state.get("status", "active")
		var case_info = _get_case_display_info(case_id)

		match status:
			"completed":
				result["completed"].append(case_info)
			"failed":
				result["failed"].append(case_info)
			"expired":
				result["expired"].append(case_info)
			"active", "available":
				result["active"].append(case_info)

	# Also check accepted but not yet completed
	for case_id in accepted_cases:
		if case_id not in completed_cases:
			var state = case_states.get(case_id, {})
			if state.get("status", "") in ["", "active"]:
				result["active"].append(_get_case_display_info(case_id))

	return result

## Get case display info (without revealing correct route)
func _get_case_display_info(case_id: String) -> Dictionary:
	var display_names = {
		"quest_hospital_medicine": "病院医薬品輸送",
		"quest_evacuation_rescue": "市立図書館救助",
		"quest_supply_depot": "物資倉庫確認",
		"case_hospital_medicine": "病院医薬品輸送",
		"case_supply_secure": "食料倉庫確保",
		"case_road_blockade": "道路封鎖突破",
	}

	return {
		"id": case_id,
		"name": display_names.get(case_id, case_id),
		"discovered": true,
	}

## Summarize NPC outcomes
func _summarize_npcs() -> Dictionary:
	var result = {
		"rescued": [],
		"lost": [],
		"departed": [],
		"alive": [],
	}

	var day1 = _gs.get_section("day1") if _gs else {}
	var rescued_ids: Array = day1.get("rescued_npcs", [])
	if bool(day1.get("rescued_evacuees", false)) and not "rei" in rescued_ids:
		rescued_ids.append("rei")

	if _nm == null:
		# still record rescued from flags
		for rid in rescued_ids:
			result["rescued"].append({"id": rid, "name": rid, "reason": "case_success"})
		return result

	var npc_ids = _nm.get_npc_ids()

	for npc_id in npc_ids:
		var npc = _nm.get_npc(npc_id)
		var npc_name = npc.get("name", npc_id)
		var alive = npc.get("alive", true)
		var present = npc.get("present", true)
		var current_action = npc.get("currentAction", "idle")

		var npc_summary = {
			"id": npc_id,
			"name": npc_name,
			"location": npc.get("locationId", "unknown"),
			"affiliation": npc.get("affiliation", "unknown"),
		}

		if str(npc_id) in rescued_ids or (npc_id == "rei" and bool(day1.get("rescue_success", false))):
			result["rescued"].append(npc_summary)
		elif not alive:
			result["lost"].append(npc_summary)
		elif not present or current_action == "fled":
			result["departed"].append(npc_summary)
		else:
			result["alive"].append(npc_summary)

	# Consequence records may overlap current NpcManager state; append only
	# entries that are not already represented.
	if _cs and _cs.has_method("get_death_record"):
		var death_record = _cs.get_death_record()
		for entry in death_record:
			var lost_id: String = str(entry.get("npc_id", ""))
			if lost_id != "" and not _npc_list_contains(result["lost"], lost_id):
				var npc = _nm.get_npc(lost_id) if _nm else {}
				result["lost"].append({
					"id": lost_id,
					"name": npc.get("name", lost_id),
					"reason": "death",
				})

	if _cs and _cs.has_method("get_flee_record"):
		var flee_record = _cs.get_flee_record()
		for entry in flee_record:
			var departed_id: String = str(entry.get("npc_id", ""))
			if departed_id != "" and not _npc_list_contains(result["departed"], departed_id):
				var npc = _nm.get_npc(departed_id) if _nm else {}
				result["departed"].append({
					"id": departed_id,
					"name": npc.get("name", departed_id),
					"reason": "fled",
				})

	return result

func _npc_list_contains(items: Array, npc_id: String) -> bool:
	for item in items:
		if str(item.get("id", "")) == npc_id:
			return true
	return false


## Summarize facility changes
func _summarize_facilities() -> Dictionary:
	var result = {}

	# Get from consequence system
	if _cs and _cs.has_method("get_all_facility_states"):
		var facilities = _cs.get_all_facility_states()
		for facility_id in facilities:
			var state = facilities[facility_id]
			result[facility_id] = {
				"operational": state.get("operational", true),
				"capacity": state.get("capacity", 0),
				"pressure": state.get("pressure", 0),
				"service_level": state.get("service_level", 0),
				"reason": state.get("reason", ""),
			}
	# Fallback to GameState
	elif _gs:
		var day1 = _gs.get_section("day1")
		var facilities = day1.get("facilities", {})
		for facility_id in facilities:
			result[facility_id] = facilities[facility_id].duplicate(true)

	return result

## Summarize KMF state
func _summarize_kmf_state() -> Dictionary:
	var result = {
		"owned": true,
		"durability": 100.0,
		"exposure": 0.0,
		"major_events": [],
	}

	if _gs:
		var kmf = _gs.get_section("kmf")
		if not kmf.is_empty():
			result["owned"] = kmf.get("owned", true)
			result["durability"] = kmf.get("durability", 100.0)

	# Get from consequence system
	if _cs and _cs.has_method("get_kmf_exposure"):
		result["exposure"] = _cs.get_kmf_exposure()

	# Add KMF-related actions from Day1
	if _gs:
		var day1 = _gs.get_section("day1")
		var actions = day1.get("actions", [])
		for action in actions:
			if action.get("mode") == "kmf" or action.get("type") == "kmf_use":
				result["major_events"].append({
					"type": "kmf_used",
					"minute": action.get("minute", 0),
					"location": action.get("locationId", "unknown"),
				})

	return result

## Summarize direct observations
func _summarize_direct_observations() -> Array:
	var result = []

	# Get from information system
	if _info and _info.has_method("get_records_by_source_type"):
		var direct_obs = _info.get_records_by_source_type(0)
		for rec in direct_obs:
			result.append({
				"content": rec.get("content", ""),
				"location": rec.get("sourceLocation", ""),
				"day": rec.get("day", 1),
				"minute": rec.get("minute", 0),
			})

	# Get from memory system
	if _ms and _ms.has_method("get_system_facts"):
		var facts = _ms.get_system_facts()
		for fact_id in facts:
			var fact = facts[fact_id]
			result.append({
				"fact_id": fact_id,
				"description": fact.get("description", ""),
				"location": fact.get("sourceLocation", ""),
				"verified": fact.get("verified", false),
			})

	return result

## Get KMF exposure summary
func _get_kmf_exposure_summary() -> Dictionary:
	var exposure = 0.0
	var major_loss = false
	var loss_description = ""

	if _cs and _cs.has_method("get_kmf_exposure"):
		exposure = _cs.get_kmf_exposure()

	if _gs:
		var kmf = _gs.get_section("kmf")
		if not kmf.is_empty() and kmf.get("durability", 100.0) < 50.0:
			major_loss = true
			loss_description = "KMFの耐久力が低下している"

	return {
		"level": exposure,
		"major_loss": major_loss,
		"loss_description": loss_description,
	}

## Summarize consequences
func _summarize_consequences() -> Dictionary:
	var result = {
		"npc_deaths": 0,
		"npc_departures": 0,
		"facility_impacts": [],
		"kmf_reports_generated": 0,
	}

	if _cs:
		if _cs.has_method("get_death_record"):
			result["npc_deaths"] = _cs.get_death_record().size()
		if _cs.has_method("get_flee_record"):
			result["npc_departures"] = _cs.get_flee_record().size()
		if _cs.has_method("get_kmf_reports"):
			result["kmf_reports_generated"] = _cs.get_kmf_reports().size()
		if _cs.has_method("get_all_facility_states"):
			var facilities = _cs.get_all_facility_states()
			for fid in facilities:
				var state = facilities[fid]
				if state.get("reason", "") != "":
					result["facility_impacts"].append({
						"facility": fid,
						"impact": state["reason"],
					})

	return result

## Get current summary (for UI display)
func get_summary() -> Dictionary:
	if not _summary_generated:
		return {}
	return _current_summary.duplicate(true)

## Export summary for display (without forbidden information)
func export_for_display() -> Dictionary:
	if not _summary_generated:
		return {"error": "Summary not yet generated"}

	var display = {
		"header": "Day 1 結果サマリー",
		"day": _current_summary.get("day", 1),
		"sections": [],
	}

	# Cases section
	var cases = _current_summary.get("cases", {})
	var case_lines = []
	if not cases.get("completed", []).is_empty():
		case_lines.append("完了した案件:")
		for c in cases["completed"]:
			case_lines.append("  - %s" % c.get("name", c.get("id", "")))
	if not cases.get("failed", []).is_empty():
		case_lines.append("失敗した案件:")
		for c in cases["failed"]:
			case_lines.append("  - %s" % c.get("name", c.get("id", "")))
	if not cases.get("expired", []).is_empty():
		case_lines.append("期限切れの案件:")
		for c in cases["expired"]:
			case_lines.append("  - %s" % c.get("name", c.get("id", "")))
	if not cases.get("active", []).is_empty():
		case_lines.append("進行中の案件:")
		for c in cases["active"]:
			case_lines.append("  - %s" % c.get("name", c.get("id", "")))
	if not case_lines.is_empty():
		display["sections"].append({"title": "案件", "lines": case_lines})

	# NPCs section
	var npcs = _current_summary.get("npcs", {})
	var npc_lines = []
	if not npcs.get("alive", []).is_empty():
		npc_lines.append("生存中: %d名" % npcs["alive"].size())
	if not npcs.get("lost", []).is_empty():
		npc_lines.append("死亡: %d名" % npcs["lost"].size())
		for n in npcs["lost"]:
			npc_lines.append("  - %s" % n.get("name", n.get("id", "")))
	if not npcs.get("departed", []).is_empty():
		npc_lines.append("離脱: %d名" % npcs["departed"].size())
		for n in npcs["departed"]:
			npc_lines.append("  - %s" % n.get("name", n.get("id", "")))
	if not npc_lines.is_empty():
		display["sections"].append({"title": "NPC状態", "lines": npc_lines})

	# Facilities section
	var facilities = _current_summary.get("facilities", {})
	var fac_lines = []
	for fid in facilities:
		var state = facilities[fid]
		var name = _get_facility_display_name(fid)
		var status = "運営中" if state.get("operational", true) else "停止"
		var details = []
		if state.has("capacity"):
			details.append(" Capacity:%d" % state["capacity"])
		if state.has("service_level"):
			details.append(" Level:%d" % state["service_level"])
		fac_lines.append("%s: %s%s" % [name, status, "".join(details)])
		if state.get("reason", "") != "":
			fac_lines.append("  (%s)" % state["reason"])
	if not fac_lines.is_empty():
		display["sections"].append({"title": "施設状態", "lines": fac_lines})

	# KMF section
	var kmf = _current_summary.get("kmf_state", {})
	var kmf_lines = []
	if kmf.get("owned", true):
		kmf_lines.append("所有: あり")
		kmf_lines.append("耐久力: %.0f%%" % kmf.get("durability", 100.0))
	else:
		kmf_lines.append("所有: 喪失")

	var exposure = kmf.get("exposure", 0.0)
	if exposure > 0:
		kmf_lines.append("露出度: %.1f" % exposure)

	var major_events = kmf.get("major_events", [])
	if not major_events.is_empty():
		kmf_lines.append("使用回数: %d回" % major_events.size())

	display["sections"].append({"title": "KMF状態", "lines": kmf_lines})

	# Direct observations section
	var observations = _current_summary.get("direct_observations", [])
	if not observations.is_empty():
		var obs_lines = []
		for obs in observations.slice(0, 5):  # Limit to 5 most recent
			var loc = obs.get("location", "不明")
			var content = obs.get("content", obs.get("description", ""))
			if content != "":
				obs_lines.append("[%s] %s" % [loc, content.substr(0, min(50, content.length()))])
		if not obs_lines.is_empty():
			display["sections"].append({"title": "直接確認した事実", "lines": obs_lines})

	return display

## Get facility display name
func _get_facility_display_name(facility_id: String) -> String:
	var names = {
		"hospital": "病院",
		"evacuation_center": "避難所",
		"maintenance": "整備施設",
	}
	return names.get(facility_id, facility_id)

## Force generate summary (for testing)
func force_generate_summary() -> Dictionary:
	_summary_generated = false
	return generate_day1_summary()

## Check if summary was generated
func is_summary_generated() -> bool:
	return _summary_generated

## Save/Load support
func serialize() -> Dictionary:
	return {
		"summary_generated": _summary_generated,
		"current_summary": _current_summary.duplicate(true) if _summary_generated else {},
	}

func deserialize(data: Dictionary) -> void:
	if data.has("summary_generated"):
		_summary_generated = data["summary_generated"]
	if data.has("current_summary"):
		_current_summary = data["current_summary"].duplicate(true)
