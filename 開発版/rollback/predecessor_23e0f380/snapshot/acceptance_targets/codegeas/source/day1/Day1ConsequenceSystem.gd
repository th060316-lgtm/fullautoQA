# Day1ConsequenceSystem.gd
# MiniMax Phase A: KMF exposure consequences + NPC death/flee ripple effects
# Handles: KMF reports/NPC reactions, NPC death/flee facility impacts
# Contract: EXT-20261019-015_MINIMAX_PHASEA_INFO_CONSEQUENCE_50

extends Node

var _gs: Node
var _eb: Node
var _ms: Node
var _nm: Node
var _info: Node
var _d1: Node

## KMF exposure tracking
var _kmf_exposure: float = 0.0
var _kmf_reports_generated: Array = []

## Processed action tracking (prevent double-processing)
var _processed_day1_actions: Dictionary = {}

## NPC death/flee tracking
var _npc_death_record: Array = []
var _npc_flee_record: Array = []

## Facility impact state
var _facility_states: Dictionary = {
	"hospital": {"capacity": 2, "pressure": 1, "operational": true},
	"evacuation_center": {"capacity": 3, "pressure": 1, "operational": true},
	"maintenance": {"service_level": 2, "operational": true},
}

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_ms = get_node_or_null("/root/MemorySystem")
	_nm = get_node_or_null("/root/NpcManager")
	_d1 = _find_day1_controller()
	_info = _find_sibling_module("Day1InformationSystem")

	_connect_signals()

func _find_day1_controller() -> Node:
	var p = get_parent()
	if p and p.has_method("record_action") and p.has_method("apply_facility_delta"):
		return p
	var root = get_tree().root if get_tree() else null
	return root.find_child("Day1Controller", true, false) if root else null

func _find_sibling_module(module_name: String) -> Node:
	var p = get_parent()
	if p:
		return p.get_node_or_null(module_name)
	return null

func _sync_exposure_from_state() -> void:
	if _gs:
		_kmf_exposure = float(_gs.get_section("day1").get("kmf_exposure", 0.0))

func _connect_signals() -> void:
	if _eb:
		if _eb.has_signal("day1_action_committed") and not _eb.day1_action_committed.is_connected(_on_day1_action_committed):
			_eb.day1_action_committed.connect(_on_day1_action_committed)
		if _eb.has_signal("day1_kmf_exposure_changed") and not _eb.day1_kmf_exposure_changed.is_connected(_on_kmf_exposure_changed):
			_eb.day1_kmf_exposure_changed.connect(_on_kmf_exposure_changed)

	# npc_died / npc_fled are NpcManager-local signals, not EventBus signals.
	if _nm:
		if _nm.has_signal("npc_died") and not _nm.npc_died.is_connected(_on_npc_died):
			_nm.npc_died.connect(_on_npc_died)
		if _nm.has_signal("npc_fled") and not _nm.npc_fled.is_connected(_on_npc_fled):
			_nm.npc_fled.connect(_on_npc_fled)

## Initialize consequence system
func initialize() -> void:
	_kmf_exposure = 0.0
	_kmf_reports_generated.clear()
	_processed_day1_actions.clear()
	_npc_death_record.clear()
	_npc_flee_record.clear()
	_init_facility_states()
	print("[Day1Consequence] Initialized")

func _init_facility_states() -> void:
	var shared: Dictionary = {}
	if _gs:
		shared = _gs.get_section("day1").get("facilities", {})
	if not shared.is_empty():
		_facility_states = shared.duplicate(true)
	else:
		_facility_states = {
			"hospital": {"capacity": 0.7, "operational": true, "reason": "initial"},
			"evacuation_center": {"pressure": 0.3, "operational": true, "reason": "initial"},
			"maintenance": {"service_level": 0.8, "operational": true, "reason": "initial"},
		}
	_sync_exposure_from_state()

## Handle Day1 action committed (KMF usage processing)
func _on_day1_action_committed(action: Dictionary) -> void:
	var action_id = action.get("id", "")
	var action_type = action.get("type", "")
	var action_key = "action_%s_%s" % [action_id, action.get("minute", 0)]
	
	# Skip if already processed
	if _processed_day1_actions.has(action_key):
		return
	_processed_day1_actions[action_key] = true
	
	# Check for KMF mode actions
	var mode = action.get("mode", "")
	var noise = action.get("noise", 0.0)
	var visible = action.get("visible", false)
	var location = action.get("locationId", "")
	
	if mode == "kmf" or action_type == "kmf_use":
		_process_kmf_action(action, noise, visible, location)

## Process KMF action and generate consequences
func _process_kmf_action(action: Dictionary, noise: float, visible: bool, location: String) -> void:
	var current_day = _gs.get_day() if _gs else 1
	var current_minute = _gs.get_minute_of_day() if _gs else 480
	
	# 1. Generate KMF usage report
	_generate_kmf_report(action, noise, visible, location, current_day, current_minute)
	
	# 2. Exposure is canonical in Day1Controller/GameState.
	# This consequence system must not independently add or write exposure,
	# otherwise one KMF action is counted twice and UI/summary values diverge.
	
	# 3. Generate NPC reactions to KMF
	_generate_kmf_npc_reactions(action, noise, visible, location, current_day, current_minute)
	
	print("[Day1Consequence] KMF action processed: noise=%.1f, canonical exposure=%.1f, loc=%s" % [noise, _kmf_exposure, location])

## Generate report about KMF usage
func _generate_kmf_report(action: Dictionary, noise: float, visible: bool, location: String, day: int, minute: int) -> void:
	var report_content = ""
	var report_tags = ["kmf", "action"]
	var related_npcs = []

	if visible and noise > 10.0:
		report_content = "街中で大型KMFが目撃された。住民たちが警戒を強めている。"
		report_tags.append("high_visibility")
		related_npcs = _get_npcs_in_range(location)
	elif visible:
		report_content = "KMFが道路上を移動しているのを見た。"
		report_tags.append("medium_visibility")
		related_npcs = _get_npcs_in_range(location)
	else:
		report_content = "どこかで大きな機械音が響いた。"
		report_tags.append("distant_sound")
		related_npcs = _get_npcs_in_range(location, 2)

	var generated = {}
	if _info and _info.has_method("add_information_record"):
		generated = _info.add_information_record(
			report_content, "witness", 3, day, minute, location,
			related_npcs, [], report_tags
		)
	elif _ms and _ms.has_method("add_report"):
		generated = _ms.add_report(
			1, report_content, "witness", related_npcs, 1, 0.4,
			report_tags, location, 3, []
		)
	if not generated.is_empty():
		_kmf_reports_generated.append(generated)

## Get NPCs in or near location
func _get_npcs_in_range(location_id: String, range_boost: int = 0) -> Array:
	var result = []
	if _nm == null:
		return result
	
	var npc_ids = _nm.get_npc_ids()
	for npc_id in npc_ids:
		var npc = _nm.get_npc(npc_id)
		var npc_loc = npc.get("locationId", "")
		# NPCs in same location or adjacent
		if npc_loc == location_id or _is_adjacent_location(npc_loc, location_id):
			result.append(npc_id)
	
	return result

## Check if two locations are adjacent
func _is_adjacent_location(loc1: String, loc2: String) -> bool:
	var adjacent_map = {
		"base": ["city_center", "hospital"],
		"city_center": ["base", "industrial_area", "hospital", "evacuation_center"],
		"industrial_area": ["city_center", "maintenance"],
		"hospital": ["base", "city_center"],
		"evacuation_center": ["city_center"],
		"maintenance": ["industrial_area"],
	}
	var adj1 = adjacent_map.get(loc1, [])
	var adj2 = adjacent_map.get(loc2, [])
	return loc2 in adj1 or loc1 in adj2

## Generate NPC reactions to KMF usage
func _generate_kmf_npc_reactions(action: Dictionary, noise: float, visible: bool, location: String, day: int, minute: int) -> void:
	if _nm == null:
		return
	
	var affected_npcs = _get_npcs_in_range(location)
	
	for npc_id in affected_npcs:
		var npc = _nm.get_npc(npc_id)
		var fear_delta = 0
		var trust_delta = 0
		var reaction_text = ""
		
		# Determine reaction based on noise and visibility
		if noise > 15.0 or visible:
			fear_delta = 15 + int(noise * 0.5)
			trust_delta = -5  # KMF noise reduces trust slightly
			reaction_text = "%sはKMFの音を聞いて恐怖を感じている。" % npc.get("name", npc_id)
		elif noise > 5.0:
			fear_delta = 5 + int(noise * 0.3)
			reaction_text = "%sは遠くの物音に警戒している。" % npc.get("name", npc_id)
		else:
			fear_delta = 2
			reaction_text = "%sは何かの音に耳を澄ましている。" % npc.get("name", npc_id)
		
		# Apply emotion changes
		_nm.modify_fear(npc_id, fear_delta)
		_nm.modify_trust(npc_id, trust_delta)
		
		# Update current action to reflect alert state
		if fear_delta > 10:
			_nm.set_action(npc_id, "alert", "")
		
		# Generate report about NPC reaction
		if _ms and _ms.has_method("add_report"):
			_ms.add_report(1, reaction_text, npc_id, [npc_id], 1, 0.3, ["npc_reaction", "kmf_fear"], location, 1, [])
		
		print("[Day1Consequence] NPC %s reaction: fear+%d trust+%d" % [npc_id, fear_delta, trust_delta])

## Handle KMF exposure changes
func _on_kmf_exposure_changed(old_value: float, new_value: float, reason: String) -> void:
	# Mirror the canonical value for summaries/serialization; never recalculate it here.
	_kmf_exposure = clampf(new_value, 0.0, 100.0)
	print("[Day1Consequence] KMF exposure: %.1f -> %.1f (reason: %s)" % [old_value, _kmf_exposure, reason])
	
	# Additional consequence at high exposure levels
	if new_value > 30.0 and old_value <= 30.0:
		_trigger_high_exposure_consequence()

func _trigger_high_exposure_consequence() -> void:
	# At high KMF exposure, generate an attributed remote report.
	if _info and _info.has_method("add_information_record"):
		_info.add_information_record(
			"最近、KMFの活動が活発化している。住民たちの不安が高まっている。",
			"remote_observer", 3,
			_gs.get_day() if _gs else 1,
			_gs.get_minute_of_day() if _gs else 0,
			"unknown", [], [], ["kmf_exposure", "social_unrest"]
		)
	elif _ms and _ms.has_method("add_report"):
		_ms.add_report(
			1,
			"最近、KMFの活動が活発化している。住民たちの不安が高まっている。",
			"remote_observer", [], 1, 0.5,
			["kmf_exposure", "social_unrest"], "unknown", 3, []
		)

## Handle NPC death
func _on_npc_died(npc_id: String) -> void:
	# Skip protagonist death (handled by game over system)
	if npc_id == "player":
		return  # Protagonist GameOver is handled elsewhere; all NPCs including yui propagate consequences.
	
	_npc_death_record.append({
		"npc_id": npc_id,
		"day": _gs.get_day() if _gs else 1,
		"minute": _gs.get_minute_of_day() if _gs else 480,
	})
	
	print("[Day1Consequence] NPC died: %s" % npc_id)
	
	# Propagate death consequences
	_propagate_npc_death_consequences(npc_id)

## Propagate death consequences to facilities and NPCs
func _propagate_npc_death_consequences(npc_id: String) -> void:
	var propagated_count = 0
	
	# 1. Facility impact
	var facility_change = _apply_death_to_facility(npc_id)
	if facility_change:
		propagated_count += 1
		_emit_facility_changed(facility_change["facility_id"], facility_change)
	
	# 2. Related NPC reactions
	var npc_reactions = _apply_death_to_related_npcs(npc_id)
	if npc_reactions > 0:
		propagated_count += 1
	
	# 3. Report generation
	_generate_death_report(npc_id)
	propagated_count += 1
	
	print("[Day1Consequence] Death propagated: %d systems affected for %s" % [propagated_count, npc_id])

## Apply death impact to relevant facility
func _apply_death_to_facility(npc_id: String) -> Dictionary:
	var npc = _nm.get_npc(npc_id) if _nm else {}
	var affiliation = npc.get("affiliation", "")
	var facility_id = ""
	
	# Map NPC affiliation to facility
	match affiliation:
		"hospital":
			facility_id = "hospital"
			var hosp = _facility_states.get("hospital", {})
			hosp["capacity"] = max(0.0, float(hosp.get("capacity", 0.7)) - (0.2 if float(hosp.get("capacity", 0.7)) <= 1.0 else 1.0))
			hosp["reason"] = "%sが死亡した" % npc.get("name", npc_id)
			_facility_states["hospital"] = hosp
			_update_game_state_facility("hospital", hosp)
			return {"facility_id": "hospital", "change": "capacity -1", "reason": hosp["reason"]}
		
		"evacuation_center":
			facility_id = "evacuation_center"
			var evac = _facility_states.get("evacuation_center", {})
			evac["pressure"] = float(evac.get("pressure", 0.3)) + (0.15 if float(evac.get("pressure", 0.3)) <= 1.0 else 1.0)
			evac["reason"] = "%sが死亡した" % npc.get("name", npc_id)
			_facility_states["evacuation_center"] = evac
			_update_game_state_facility("evacuation_center", evac)
			return {"facility_id": "evacuation_center", "change": "pressure +1", "reason": evac["reason"]}
		
		"militia":
			# Militia affects maintenance indirectly
			facility_id = "maintenance"
			var maint = _facility_states.get("maintenance", {})
			maint["service_level"] = max(0.0, float(maint.get("service_level", 0.8)) - (0.2 if float(maint.get("service_level", 0.8)) <= 1.0 else 1.0))
			maint["reason"] = "%sが死亡した" % npc.get("name", npc_id)
			_facility_states["maintenance"] = maint
			_update_game_state_facility("maintenance", maint)
			return {"facility_id": "maintenance", "change": "service_level -1", "reason": maint["reason"]}
	
	return {}

## Update GameState facility state
func _update_game_state_facility(facility_id: String, state: Dictionary) -> void:
	_facility_states[facility_id] = state.duplicate(true)
	if _d1 and _d1.has_method("apply_facility_delta"):
		_d1.apply_facility_delta(facility_id, state, str(state.get("reason", "consequence")))
	elif _gs:
		var day1 = _gs.get_section("day1")
		if not day1.is_empty():
			if not day1.has("facilities"):
				day1["facilities"] = {}
			day1["facilities"][facility_id] = state.duplicate(true)
			_gs.set_section("day1", day1)

## Apply death impact to related NPCs
func _apply_death_to_related_npcs(npc_id: String) -> int:
	if _nm == null:
		return 0
	
	var affected_count = 0
	var npc_ids = _nm.get_npc_ids()
	
	# Get NPCs who had relationship with deceased
	var related = _nm.get_related_npcs(npc_id, 0.0, -100.0)
	
	# Negative relationship NPCs may react with relief or fear
	for rel_data in related["negative"]:
		var other_id = rel_data["id"]
		_nm.modify_affection(other_id, 5)  # Slight positive (death of enemy)
		_nm.modify_fear(other_id, 10)  # But also fear
		affected_count += 1
	
	# Positive relationship NPCs react with sadness/fear
	for rel_data in related["positive"]:
		var other_id = rel_data["id"]
		_nm.modify_fear(other_id, 15)
		_nm.modify_trust(other_id, -5)  # Death reduces trust in safety
		affected_count += 1
	
	# Neutral NPCs just get slight fear
	for rel_data in related["neutral"]:
		var other_id = rel_data["id"]
		_nm.modify_fear(other_id, 5)
		affected_count += 1
	
	return affected_count

## Generate report about NPC death
func _generate_death_report(npc_id: String) -> void:
	var npc = _nm.get_npc(npc_id) if _nm else {}
	var npc_name = npc.get("name", npc_id)
	var affiliation = npc.get("affiliation", "不明")
	var location = str(npc.get("locationId", "unknown"))
	var report_text = "%sが死亡した。%sの業務に影響が出る可能性がある。" % [npc_name, affiliation]
	if _info and _info.has_method("add_information_record"):
		_info.add_information_record(
			report_text, "remote_report", 3,
			_gs.get_day() if _gs else 1,
			_gs.get_minute_of_day() if _gs else 0,
			location, [npc_id], [], ["npc_death", affiliation]
		)
	elif _ms and _ms.has_method("add_report"):
		_ms.add_report(1, report_text, "remote_report", [npc_id], 1, 0.2,
			["npc_death", affiliation], location, 3, [])

## Handle NPC flee
func _on_npc_fled(npc_id: String) -> void:
	_npc_flee_record.append({
		"npc_id": npc_id,
		"day": _gs.get_day() if _gs else 1,
		"minute": _gs.get_minute_of_day() if _gs else 480,
	})
	
	print("[Day1Consequence] NPC fled: %s" % npc_id)
	
	_propagate_npc_flee_consequences(npc_id)

## Propagate flee consequences
func _propagate_npc_flee_consequences(npc_id: String) -> void:
	var propagated_count = 0
	
	# 1. Facility impact (pressure increase)
	var facility_change = _apply_flee_to_facility(npc_id)
	if facility_change:
		propagated_count += 1
	
	# 2. Related NPC reactions
	var npc_reactions = _apply_flee_to_related_npcs(npc_id)
	if npc_reactions > 0:
		propagated_count += 1
	
	# 3. Report (information source change)
	_generate_flee_report(npc_id)
	propagated_count += 1
	
	print("[Day1Consequence] Flee propagated: %d systems affected for %s" % [propagated_count, npc_id])

## Apply flee impact to facilities
func _apply_flee_to_facility(npc_id: String) -> Dictionary:
	var npc = _nm.get_npc(npc_id) if _nm else {}
	var affiliation = npc.get("affiliation", "")
	
	match affiliation:
		"evacuation_center":
			var evac = _facility_states.get("evacuation_center", {})
			evac["pressure"] = float(evac.get("pressure", 0.3)) + (0.15 if float(evac.get("pressure", 0.3)) <= 1.0 else 1.0)
			evac["reason"] = "%sが退去した" % npc.get("name", npc_id)
			_facility_states["evacuation_center"] = evac
			_update_game_state_facility("evacuation_center", evac)
			return {"facility_id": "evacuation_center", "change": "pressure +1", "reason": evac["reason"]}
		
		"hospital":
			var hosp = _facility_states.get("hospital", {})
			hosp["capacity"] = max(0.0, float(hosp.get("capacity", 0.7)) - (0.2 if float(hosp.get("capacity", 0.7)) <= 1.0 else 1.0))
			hosp["reason"] = "%sが退去した" % npc.get("name", npc_id)
			_facility_states["hospital"] = hosp
			_update_game_state_facility("hospital", hosp)
			return {"facility_id": "hospital", "change": "capacity -1", "reason": hosp["reason"]}
	
	return {}

## Apply flee impact to related NPCs
func _apply_flee_to_related_npcs(npc_id: String) -> int:
	if _nm == null:
		return 0
	
	var affected_count = 0
	var related = _nm.get_related_npcs(npc_id, 0.0, -100.0)
	
	# Positive relationships: fear/insecurity
	for rel_data in related["positive"]:
		_nm.modify_fear(rel_data["id"], 10)
		_nm.modify_trust(rel_data["id"], -5)
		affected_count += 1
	
	# Negative relationships: slight relief
	for rel_data in related["negative"]:
		_nm.modify_affection(rel_data["id"], 3)
		affected_count += 1
	
	return affected_count

## Generate report about NPC flee
func _generate_flee_report(npc_id: String) -> void:
	var npc = _nm.get_npc(npc_id) if _nm else {}
	var npc_name = npc.get("name", npc_id)
	var location = str(npc.get("locationId", "unknown"))
	var report_text = "%sが姿を消した。行き先は確認できていない。" % npc_name
	if _info and _info.has_method("add_information_record"):
		_info.add_information_record(
			report_text, "remote_report", 3,
			_gs.get_day() if _gs else 1,
			_gs.get_minute_of_day() if _gs else 0,
			location, [npc_id], [], ["npc_flee", "uncertain"]
		)
	elif _ms and _ms.has_method("add_report"):
		_ms.add_report(1, report_text, "remote_report", [npc_id], 1, 0.3,
			["npc_flee", "uncertain"], location, 3, [])

## Emit facility changed event
func _emit_facility_changed(facility_id: String, snapshot: Dictionary) -> void:
	if _d1 and _d1.has_method("apply_facility_delta"):
		return
	if _eb and _eb.has_signal("day1_facility_changed"):
		_eb.day1_facility_changed.emit(facility_id, snapshot.duplicate(true), snapshot.get("reason", ""))

## Get current facility states
func get_facility_state(facility_id: String) -> Dictionary:
	return _facility_states.get(facility_id, {})

## Get all facility states
func get_all_facility_states() -> Dictionary:
	return _facility_states.duplicate(true)

## Get KMF exposure level
func get_kmf_exposure() -> float:
	return _kmf_exposure

## Get KMF reports generated
func get_kmf_reports() -> Array:
	return _kmf_reports_generated.duplicate(true)

## Get NPC death record
func get_death_record() -> Array:
	return _npc_death_record.duplicate(true)

## Get NPC flee record
func get_flee_record() -> Array:
	return _npc_flee_record.duplicate(true)

## Save/Load support
func serialize() -> Dictionary:
	return {
		"kmf_exposure": _kmf_exposure,
		"kmf_reports_generated": _kmf_reports_generated.duplicate(true),
		"processed_day1_actions": _processed_day1_actions.duplicate(),
		"npc_death_record": _npc_death_record.duplicate(true),
		"npc_flee_record": _npc_flee_record.duplicate(true),
		"facility_states": _facility_states.duplicate(true),
	}

func deserialize(data: Dictionary) -> void:
	# Runtime saves may contain a historical mirror, but GameState is authoritative.
	if data.has("kmf_exposure"):
		_kmf_exposure = float(data["kmf_exposure"])
	if data.has("kmf_reports_generated"):
		_kmf_reports_generated = data["kmf_reports_generated"].duplicate(true)
	if data.has("processed_day1_actions"):
		_processed_day1_actions = data["processed_day1_actions"].duplicate()
	if data.has("npc_death_record"):
		_npc_death_record = data["npc_death_record"].duplicate(true)
	if data.has("npc_flee_record"):
		_npc_flee_record = data["npc_flee_record"].duplicate(true)
	if data.has("facility_states"):
		_facility_states = data["facility_states"].duplicate(true)
	_sync_exposure_from_state()
