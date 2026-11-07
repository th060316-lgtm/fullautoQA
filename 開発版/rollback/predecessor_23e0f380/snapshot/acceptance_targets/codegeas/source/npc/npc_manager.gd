# npc_manager.gd — NPC state management, relationship graph, AI decisions
# Manages 10-12 NPCs with full state tracking, relationship graph, and action AI.
# Uses only GameState/EventBus/RngService public API.
# Does NOT hardcode affection=-100 as instant death.

extends Node

const DEFS = preload("res://npc/npc_definitions.gd")

## Runtime NPC state storage
var _npcs: Dictionary = {}          # npc_id -> runtime data dict
var _relationships: Dictionary = {} # npc_id -> {other_npc_id -> value}

var _rng: Node
var _gs: Node
var _eb: Node

signal npc_updated(npc_id: String)
signal relationship_changed(npc_a: String, npc_b: String, old_val: float, new_val: float)
signal npc_died(npc_id: String)
signal npc_fled(npc_id: String)

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_rng = get_node_or_null("/root/RngService")

func initialize() -> void:
	# Load NPC templates into runtime state
	for npc_id in DEFS.NPC_TEMPLATES.keys():
		var data = DEFS.create_runtime_copy(npc_id)
		if not data.is_empty():
			_npcs[npc_id] = data
	
	# Initialize relationship graph
	for npc_id in DEFS.INITIAL_RELATIONSHIPS.keys():
		_relationships[npc_id] = DEFS.INITIAL_RELATIONSHIPS[npc_id].duplicate(true)
	
	# Register NPCs with GameState snapshot
	for npc_id in _npcs.keys():
		_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null
	
	print("[NpcManager] Initialized %d NPCs" % _npcs.size())

## --- NPC accessors ---
func get_npc(npc_id: String) -> Dictionary:
	return _npcs.get(npc_id, {}).duplicate(true)

func get_all_npcs() -> Dictionary:
	return _npcs.duplicate(true)

func get_npc_ids() -> Array:
	return _npcs.keys()

func get_npcs_by_location(location_id: String) -> Array:
	var result = []
	for npc_id in _npcs.keys():
		if _npcs[npc_id].get("locationId") == location_id:
			result.append(npc_id)
	return result

func get_npcs_by_affiliation(affiliation: String) -> Array:
	var result = []
	for npc_id in _npcs.keys():
		if _npcs[npc_id].get("affiliation") == affiliation:
			result.append(npc_id)
	return result

## --- Heroine mirror integration ---
func mirror_heroine_state(data: Dictionary) -> void:
	_npcs["yui"] = data.duplicate(true)
	if _gs:
		_gs.set_npc("yui", _npcs["yui"])

func _forward_heroine_updates(updates: Dictionary) -> bool:
	if not updates or not get_node_or_null("/root/HeroineSystem"):
		return false
	var hs = get_node_or_null("/root/HeroineSystem")
	if hs.has_method("apply_external_updates"):
		hs.apply_external_updates(updates)
		return true
	return false

## --- NPC state mutation ---

func update_npc(npc_id: String, updates: Dictionary) -> void:
	if not _npcs.has(npc_id):
		return
	if npc_id == "yui" and _forward_heroine_updates(updates):
		return
	for key in updates:
		var old_val = _npcs[npc_id].get(key)
		_npcs[npc_id][key] = updates[key]
		if key in ["affection", "trust", "fear", "dependence"]:
			_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null
	npc_updated.emit(npc_id)

## Affection change with bounds -100..+100
func modify_affection(npc_id: String, delta: int) -> void:
	if not _npcs.has(npc_id):
		return
	if npc_id == "yui" and get_node_or_null("/root/HeroineSystem"):
		var hs = get_node_or_null("/root/HeroineSystem")
		if hs.has_method("modify_affection"):
			hs.call("modify_affection", delta)
			return
	var old_val = _npcs[npc_id].get("affection", 0)
	var new_val = clampi(old_val + delta, -100, 100)
	_npcs[npc_id]["affection"] = new_val
	_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null
	if _eb:
		_eb.affection_changed.emit(npc_id, old_val, new_val)

func modify_trust(npc_id: String, delta: int) -> void:
	if not _npcs.has(npc_id):
		return
	if npc_id == "yui" and get_node_or_null("/root/HeroineSystem"):
		var hs = get_node_or_null("/root/HeroineSystem")
		if hs.has_method("modify_trust"):
			hs.call("modify_trust", delta)
			return
	var old_val = _npcs[npc_id].get("trust", 0)
	var new_val = clampi(old_val + delta, -100, 100)
	_npcs[npc_id]["trust"] = new_val
	_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null

func modify_fear(npc_id: String, delta: int) -> void:
	if not _npcs.has(npc_id):
		return
	if npc_id == "yui" and get_node_or_null("/root/HeroineSystem"):
		var hs = get_node_or_null("/root/HeroineSystem")
		if hs.has_method("modify_fear"):
			hs.call("modify_fear", delta)
			return
	var old_val = _npcs[npc_id].get("fear", 0)
	var new_val = clampi(old_val + delta, -100, 100)
	_npcs[npc_id]["fear"] = new_val
	_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null

func add_interaction(npc_id: String, amount: int = 1) -> void:
	if not _npcs.has(npc_id):
		return
	if npc_id == "yui" and get_node_or_null("/root/HeroineSystem"):
		get_node_or_null("/root/HeroineSystem").add_interaction(amount, "npc_manager")
		return
	_npcs[npc_id]["interactionTotal"] = _npcs[npc_id].get("interactionTotal", 0) + amount
	_npcs[npc_id]["interactionRecent"] = _npcs[npc_id].get("interactionRecent", 0) + amount
	_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null

## --- Relationship graph ---
func get_relationship(npc_a: String, npc_b: String) -> float:
	return _relationships.get(npc_a, {}).get(npc_b, 0.0)

func set_relationship(npc_a: String, npc_b: String, value: float) -> void:
	if not _relationships.has(npc_a):
		_relationships[npc_a] = {}
	if not _relationships.has(npc_b):
		_relationships[npc_b] = {}
	var old_a = _relationships[npc_a].get(npc_b, 0.0)
	var old_b = _relationships[npc_b].get(npc_a, 0.0)
	_relationships[npc_a][npc_b] = value
	_relationships[npc_b][npc_a] = value
	relationship_changed.emit(npc_a, npc_b, old_a, value)
	if _eb:
		_eb.npc_relationship_changed.emit(npc_a, npc_b, old_a, value)

func modify_relationship(npc_a: String, npc_b: String, delta: float) -> void:
	var current = get_relationship(npc_a, npc_b)
	set_relationship(npc_a, npc_b, clampf(current + delta, -100.0, 100.0))

## NPCs with positive/negative relations to a given NPC
func get_related_npcs(npc_id: String, threshold_positive: float = 20.0, threshold_negative: float = -20.0) -> Dictionary:
	var result = {"positive": [], "negative": [], "neutral": []}
	var rels = _relationships.get(npc_id, {})
	for other_id in rels:
		var v = rels[other_id]
		if v >= threshold_positive:
			result["positive"].append({"id": other_id, "value": v})
		elif v <= threshold_negative:
			result["negative"].append({"id": other_id, "value": v})
		else:
			result["neutral"].append({"id": other_id, "value": v})
	return result

## --- Memory ---
func add_memory(npc_id: String, memory: Dictionary) -> void:
	if not _npcs.has(npc_id):
		return
	var memories = _npcs[npc_id].get("memories", [])
	var memory_entry = memory.duplicate(true)
	memory_entry["timestamp"] = _gs.get_day() if _gs else 1
	memory_entry["minute"] = _gs.get_minute_of_day() if _gs else 0
	memory_entry["id"] = "mem_%s_%d" % [npc_id, memories.size()]
	memories.append(memory_entry)
	_npcs[npc_id]["memories"] = memories
	_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null

func get_memories(npc_id: String) -> Array:
	return _npcs.get(npc_id, {}).get("memories", []).duplicate(true)

func set_memories(npc_id: String, memories: Array) -> void:
	if not _npcs.has(npc_id):
		return
	_npcs[npc_id]["memories"] = memories.duplicate(true)
	if _gs:
		_gs.set_npc(npc_id, _npcs[npc_id])

## --- NPC actions and goals ---
func set_action(npc_id: String, action: String, location_id: String = "") -> void:
	if not _npcs.has(npc_id):
		return
	_npcs[npc_id]["currentAction"] = action
	if location_id != "":
		_npcs[npc_id]["locationId"] = location_id
	_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null

func set_goal(npc_id: String, goal: String) -> void:
	if not _npcs.has(npc_id):
		return
	_npcs[npc_id]["currentGoal"] = goal

## --- NPC death and removal ---
func kill_npc(npc_id: String) -> void:
	if not _npcs.has(npc_id):
		return
	_npcs[npc_id]["alive"] = false
	_npcs[npc_id]["hp"] = 0
	_npcs[npc_id]["currentAction"] = "dead"
	_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null
	npc_died.emit(npc_id)

func npc_flee(npc_id: String) -> void:
	if not _npcs.has(npc_id):
		return
	_npcs[npc_id]["present"] = false
	_npcs[npc_id]["currentAction"] = "fled"
	_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null
	npc_fled.emit(npc_id)

func revive_npc(npc_id: String) -> void:
	if not _npcs.has(npc_id):
		return
	_npcs[npc_id]["alive"] = true
	_npcs[npc_id]["hp"] = _npcs[npc_id].get("maxHp", 80)
	_npcs[npc_id]["present"] = true
	_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null

## --- NPC AI: determine next action based on state ---
func tick_npc_ai(npc_id: String) -> String:
	if not _npcs.has(npc_id):
		return "idle"
	var npc = _npcs[npc_id]
	if not npc.get("alive", true):
		return "dead"
	if npc.get("hp", 100) < 20:
		return "flee"
	var world = _gs.get_world() if _gs else {}
	var unrest = world.get("socialUnrest", 0)
	var fear = npc.get("fear", 0)
	var affection = npc.get("affection", 0)
	var goal = npc.get("currentGoal", "")
	
	# High fear + high unrest = flee
	if fear > 50 and unrest > 60:
		return "flee"
	# High negative affection + high unrest = hostile
	if affection < -50 and unrest > 50:
		return "hostile"
	# Normal behavior based on goal
	match goal:
		"protect_family":
			return "guard"
		"save_patients":
			return "work"
		"protect_children":
			return "guard"
		"find_supplies":
			return "scavenge"
		"survive_alone":
			return "hide"
		"find_parents":
			return "search"
		"understand_geass":
			return "observe"
		_:
			return "idle"

## --- Heroine-specialized access ---
func is_heroine(npc_id: String) -> bool:
	return npc_id == DEFS.get_heroine_id()

func get_heroine() -> Dictionary:
	return _npcs.get(DEFS.get_heroine_id(), {})

## --- NPC condition helpers ---
func is_hostile_to_player(npc_id: String) -> bool:
	var affection = _npcs.get(npc_id, {}).get("affection", 0)
	var fear = _npcs.get(npc_id, {}).get("fear", 0)
	# Hostile if very negative affection OR (negative + low fear + high unrest)
	var world = _gs.get_world() if _gs else {}
	var unrest = world.get("socialUnrest", 0)
	return affection < -50 or (affection < -20 and fear < 20 and unrest > 50)

func is_friendly_to_player(npc_id: String) -> bool:
	var affection = _npcs.get(npc_id, {}).get("affection", 0)
	return affection > 20

## --- Save/Load ---
func serialize() -> Dictionary:
	return {
		"npcs": _npcs.duplicate(true),
		"relationships": _relationships.duplicate(true),
	}

func deserialize(data: Dictionary) -> void:
	if data.has("npcs"):
		_npcs = data["npcs"].duplicate(true)
		for npc_id in _npcs:
			_gs.set_npc(npc_id, _npcs[npc_id]) if _gs else null
	if data.has("relationships"):
		_relationships = data["relationships"].duplicate(true)
