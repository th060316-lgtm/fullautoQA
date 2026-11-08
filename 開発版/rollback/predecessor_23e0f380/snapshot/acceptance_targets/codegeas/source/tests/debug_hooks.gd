# debug_hooks.gd — QA Debug Hooks and internal testing tools
# WARNING: Internal truth values are for QA/debug use only.
# NOT exposed in normal UI.

extends Node

var _gs: Node
var _eb: Node
var _nm: Node
var _hs: Node
var _mem: Node
var _qm: Node
var _wes: Node
var _geass: Node

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_nm = get_node_or_null("/root/NpcManager")
	_hs = get_node_or_null("/root/HeroineSystem")
	_mem = get_node_or_null("/root/MemorySystem")
	_qm = get_node_or_null("/root/QuestManager")
	_wes = get_node_or_null("/root/WorldEventSystem")
	_geass = get_node_or_null("/root/GeassSystem")

## --- Time control ---
func advance_time(minutes: int) -> void:
	if _gs:
		_gs.advance_time(minutes)
	if _eb:
		_eb.debug_hook_called.emit("advance_time", {"minutes": minutes})
	print("[DEBUG] Time advanced: %d minutes" % minutes)

func advance_day() -> void:
	if _gs:
		_gs.advance_time(1440)
	print("[DEBUG] Advanced 1 day")

## --- Seed control ---
func set_seed(seed: int) -> void:
	var rng = get_node_or_null("/root/RngService")
	if rng:
		rng.set_seed(seed)
	var meta = _gs.get_meta_section() if _gs else {}
	meta["seed"] = seed
	_gs.set_meta_section(meta) if _gs else null
	print("[DEBUG] Seed set to %d" % seed)

func get_seed() -> int:
	var rng = get_node_or_null("/root/RngService")
	return rng.get_seed() if rng else 42

## --- Event forcing ---
func force_world_event(event_id: String) -> void:
	if _wes:
		_wes.queue_event({"event_id": event_id, "effects": {}})
		_wes.process_event_queue()
		_eb.world_event_triggered.emit(event_id) if _eb else null
	print("[DEBUG] Forced world event: %s" % event_id)

func force_day(day: int) -> void:
	if _gs:
		var meta = _gs.get_meta_section()
		meta["day"] = day
		_gs.set_meta_section(meta)
		print("[DEBUG] Day forced to %d" % day)

## --- NPC state dump ---
func dump_npc_state(npc_id: String) -> String:
	var npc = _nm.get_npc(npc_id) if _nm else {}
	if npc.is_empty():
		return "NPC not found: %s" % npc_id
	var lines = ["=== NPC State: %s (%s) ===" % [npc.get("name", npc_id), npc_id]]
	lines.append("HP: %d  Alive: %s  Present: %s" % [npc.get("hp", 0), npc.get("alive", true), npc.get("present", true)])
	lines.append("Affection: %d  Trust: %d  Fear: %d  Dependence: %d" % [
		npc.get("affection", 0), npc.get("trust", 0), npc.get("fear", 0), npc.get("dependence", 0)])
	lines.append("Emotions: %s" % str(npc.get("emotions", {})))
	lines.append("Action: %s  Goal: %s" % [npc.get("currentAction", "?"), npc.get("currentGoal", "?")])
	lines.append("Memories: %d entries" % npc.get("memories", []).size())
	lines.append("Relationship graph:")
	var rels = _nm.get_related_npcs(npc_id) if _nm else {}
	for rel_type in ["positive", "negative", "neutral"]:
		for rel in rels.get(rel_type, []):
			lines.append("  [%s] %s: %.0f" % [rel_type, rel["id"], rel["value"]])
	return "\n".join(lines)

func dump_all_npcs() -> String:
	var lines = ["=== ALL NPC STATE ==="]
	for npc_id in (_nm.get_npc_ids() if _nm else []):
		lines.append(dump_npc_state(npc_id))
		lines.append("")
	return "\n".join(lines)

## --- Internal truth value access (QA ONLY) ---
func get_true_affection(npc_id: String) -> int:
	var npc = _nm.get_npc(npc_id) if _nm else {}
	return npc.get("affection", 0)

func get_true_all_affections() -> Dictionary:
	var result = {}
	for npc_id in (_nm.get_npc_ids() if _nm else []):
		result[npc_id] = _nm.get_npc(npc_id).get("affection", 0)
	return result

func get_true_world_state() -> Dictionary:
	return _wes.get_world_state() if _wes else {}

func get_true_system_facts() -> Dictionary:
	return _mem.get_system_facts() if _mem else {}

func get_true_reports() -> Array:
	return _mem.get_reports() if _mem else []

## --- Affection boundary tests ---
func test_affection_boundary(npc_id: String, target_affection: int) -> Dictionary:
	var npc = _nm.get_npc(npc_id) if _nm else {}
	var old = npc.get("affection", 0)
	_nm.update_npc(npc_id, {"affection": target_affection}) if _nm else null
	var result = {
		"npc_id": npc_id,
		"old_affection": old,
		"new_affection": target_affection,
		"is_hostile": _nm.is_hostile_to_player(npc_id) if _nm else false,
		"is_friendly": _nm.is_friendly_to_player(npc_id) if _nm else false,
		"next_action": _nm.tick_npc_ai(npc_id) if _nm else "unknown",
	}
	# Restore
	_nm.update_npc(npc_id, {"affection": old}) if _nm else null
	return result

func test_heroine_affection_boundary(target_affection: int) -> Dictionary:
	var old = _hs.get_affection() if _hs else 0
	_hs.set_affection(target_affection) if _hs else null
	var result = {
		"old_affection": old,
		"new_affection": target_affection,
		"band": _hs.get_affection_band_label() if _hs else "unknown",
		"next_action": _hs.ActionType.keys()[_hs.get_next_action()] if _hs else "unknown",
		"dominant_emotion": _hs.get_dominant_emotion() if _hs else "unknown",
	}
	_hs.set_affection(old) if _hs else null
	return result

## --- Memory modification test (systemFacts must remain unchanged) ---
func test_memory_modification(npc_id: String) -> bool:
	var facts_before = _mem.get_system_facts() if _mem else {}
	var fact_ids_before = facts_before.keys()
	
	# Add a system fact
	_mem.add_system_fact("debug_test_fact", "Debug test fact - should not be modified", "debug") if _mem else null
	
	# Try to modify via memory system
	var memories = _mem.get_npc_memories(npc_id) if _mem else []
	if not memories.is_empty():
		var mem_id = memories[0].get("id", "")
		_mem.modify_npc_memory(npc_id, mem_id, "REWRITTEN BY DEBUG TEST", true) if _mem else null
	
	var facts_after = _mem.get_system_facts() if _mem else {}
	
	# Verify systemFacts unchanged
	for fid in fact_ids_before:
		if not facts_after.has(fid) or facts_after[fid] != facts_before[fid]:
			print("[DEBUG] FAIL: systemFact %s was modified!" % fid)
			return false
	
	# Check that test fact still exists
	if not facts_after.has("debug_test_fact"):
		print("[DEBUG] FAIL: new systemFact was not added!")
		return false
	
	print("[DEBUG] PASS: systemFacts integrity maintained after memory modification")
	return true

## --- World progression test (player idle) ---
func test_world_progression_without_player(duration_days: int) -> Dictionary:
	var world_before = _wes.get_world_state() if _wes else {}
	var unrest_before = world_before.get("socialUnrest", 0)
	
	for day in range(1, duration_days + 1):
		if _gs:
			var meta = _gs.get_meta_section()
			meta["day"] = day
			_gs.set_meta_section(meta)
		_wes.on_time_tick(day, 0) if _wes else null
	
	var world_after = _wes.get_world_state() if _wes else {}
	var unrest_after = world_after.get("socialUnrest", 0)
	var events_triggered = world_after.get("eventCount", 0) - world_before.get("eventCount", 0)
	
	return {
		"unrest_before": unrest_before,
		"unrest_after": unrest_after,
		"events_triggered": events_triggered,
		"world_progressed": unrest_after != unrest_before or events_triggered > 0,
	}

## --- Ending test ---
func test_ending_reached() -> bool:
	var es = get_node_or_null("/root/EndingSystem")
	if not es:
		return false
	var result = es.evaluate_ending()
	return result.get("ending", -1) >= 0

## --- Full state dump ---
func dump_full_state() -> String:
	var lines = ["=== FULL DEBUG STATE DUMP ==="]
	lines.append("Day: %d  Minute: %d" % [(_gs.get_day() if _gs else 0), (_gs.get_minute_of_day() if _gs else 0)])
	lines.append("Seed: %d" % get_seed())
	lines.append("\n--- NPC States ---")
	lines.append(dump_all_npcs())
	lines.append("\n--- Heroine ---")
	var hstate = _hs.get_state_for_ui() if _hs else {}
	lines.append(JSON.stringify(hstate, "  "))
	lines.append("\n--- World State ---")
	lines.append(JSON.stringify(_wes.get_world_state() if _wes else {}, "  "))
	lines.append("\n--- System Facts ---")
	lines.append(JSON.stringify(_mem.get_system_facts() if _mem else {}, "  "))
	lines.append("\n--- Quests ---")
	var quest_summary = _qm.get_quest_summary() if _qm else {}
	lines.append(JSON.stringify(quest_summary, "  "))
	return "\n".join(lines)

## --- Save/Load test ---
func test_save_load_cycle() -> bool:
	var snapshot_before = _gs.get_snapshot() if _gs else {}
	var social_snap = get_node_or_null("/root/SocialManager").serialize() if get_node_or_null("/root/SocialManager") else {}
	
	# Apply snapshot back
	_gs.apply_snapshot(snapshot_before) if _gs else null
	get_node_or_null("/root/SocialManager").deserialize(social_snap) if get_node_or_null("/root/SocialManager") else null
	
	var snapshot_after = _gs.get_snapshot() if _gs else {}
	
	# Compare key fields
	for key in ["meta", "heroine", "world"]:
		if snapshot_before.get(key, {}) != snapshot_after.get(key, {}):
			print("[DEBUG] Save/Load mismatch in section: %s" % key)
			return false
	
	print("[DEBUG] PASS: Save/Load cycle preserves logical state")
	return true

## --- QA test suite runner ---
func run_qa_tests() -> String:
	var results = []
	results.append("=== QA TEST RESULTS ===")
	
	# Test 1: Affection boundary
	var affection_tests = [-100, -99, -1, 0, 1, 99, 100]
	for val in affection_tests:
		var r = test_heroine_affection_boundary(val)
		results.append("Affection=%d: band=%s action=%s" % [val, r.get("band", "?"), r.get("next_action", "?")])
	
	# Test 2: Memory immutability
	var mem_ok = test_memory_modification("tanaka")
	results.append("Memory immutability: %s" % ("PASS" if mem_ok else "FAIL"))
	
	# Test 3: World progression without player
	var world_test = test_world_progression_without_player(2)
	results.append("World progression idle: progressed=%s events=%d" % [world_test["world_progressed"], world_test["events_triggered"]])
	
	# Test 4: Save/Load
	var save_ok = test_save_load_cycle()
	results.append("Save/Load cycle: %s" % ("PASS" if save_ok else "FAIL"))
	
	# Test 5: Ending system
	var end_test = test_ending_reached()
	results.append("Ending evaluation: %s" % ("evaluated" if end_test else "not yet evaluated"))
	
	return "\n".join(results)
