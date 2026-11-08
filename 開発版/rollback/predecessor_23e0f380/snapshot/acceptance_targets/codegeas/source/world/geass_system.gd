# geass_system.gd — Geass disaster representative events
# Implements: memory modification, emotion amplification, positive resonance,
# emotion transference, geass grant, relationship changes, reverberation,
# social epicenter effects.
# Does NOT hard-code any new abilities or laws. All based on existing Code/Geass setting.

extends Node

## Geass event types
enum GeassType {
	MEMORY_MODIFICATION,   # Character's memory rewritten
	EMOTION_AMPLIFICATION, # Existing emotions intensified
	POSITIVE_RESONANCE,    # Positive emotions spread to nearby NPCs
	EMOTION_TRANSMISSION,  # One character's emotion transfers to another
	GEASS_GRANT,           # Geass ability given to a character
	RELATIONSHIP_CHANGE,   # NPC relationship dramatically altered
	REVERBERATION,         # Effect of nearby geass user affects others
	SOCIAL_EPICENTER,     # NPC near a major geass event changes behavior
}

## Geass source types
const GEASS_SOURCE_CODE_HOLDER = "code_holder"
const GEASS_SOURCE_GUARDIAN = "guardian"
const GEASS_SOURCE_GEASS_USER = "geass_user"

var _gs: Node
var _eb: Node
var _rng: Node
var _nm: Node
var _mem: Node

## Active geass effects (for tracking and cleanup)
var _active_effects: Array = []  # {id, type, target_id, source_id, day, minute, intensity, duration, applied}

var _event_counter: int = 0

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_rng = get_node_or_null("/root/RngService")
	_nm = get_node_or_null("/root/NpcManager")
	_mem = get_node_or_null("/root/MemorySystem")

func initialize() -> void:
	_event_counter = 0

## --- Memory Modification ---
func apply_memory_modification(target_id: String, old_memory_id: String, new_content: String, source_type: String = GEASS_SOURCE_CODE_HOLDER) -> Dictionary:
	_event_counter += 1
	var event_id = "geass_mem_%d" % _event_counter
	
	# Record in memory system (immutable systemFacts NOT modified)
	_mem.modify_npc_memory(target_id, old_memory_id, new_content, true) if _mem else null
	
	var effect = {
		"id": event_id,
		"type": GeassType.MEMORY_MODIFICATION,
		"target_id": target_id,
		"source_type": source_type,
		"memory_id": old_memory_id,
		"day": _gs.get_day() if _gs else 1,
		"minute": _gs.get_minute_of_day() if _gs else 0,
		"intensity": 1.0,
		"applied": true,
	}
	_active_effects.append(effect)
	
	if _eb:
		_eb.geass_triggered.emit(target_id, "memory_modification", source_type)
		_eb.world_event_triggered.emit(event_id)
	
	print("[Geass] Memory modification on %s by %s" % [target_id, source_type])
	return effect

## --- Emotion Amplification ---
func amplify_emotion(target_id: String, emotion_type: String, intensity: float, source_type: String = GEASS_SOURCE_CODE_HOLDER) -> Dictionary:
	_event_counter += 1
	var event_id = "geass_emo_%d" % _event_counter
	var npc = _nm.get_npc(target_id) if _nm else {}
	if npc.is_empty():
		return {}
	
	var emotions = npc.get("emotions", {})
	var current = emotions.get(emotion_type, 0.0)
	var new_val = clampf(current + intensity, 0.0, 1.0)
	emotions[emotion_type] = new_val
	npc["emotions"] = emotions
	npc["currentEmotion"] = emotion_type
	_nm.update_npc(target_id, {"emotions": emotions, "currentEmotion": emotion_type}) if _nm else null
	
	var effect = {
		"id": event_id,
		"type": GeassType.EMOTION_AMPLIFICATION,
		"target_id": target_id,
		"source_type": source_type,
		"emotion_type": emotion_type,
		"old_val": current,
		"new_val": new_val,
		"day": _gs.get_day() if _gs else 1,
		"minute": _gs.get_minute_of_day() if _gs else 0,
		"intensity": intensity,
		"applied": true,
	}
	_active_effects.append(effect)
	
	if _eb:
		_eb.geass_triggered.emit(target_id, "emotion_amplification", source_type)
		_eb.world_event_triggered.emit(event_id)
	
	print("[Geass] Emotion amplification on %s: %s +%.2f -> %.2f" % [target_id, emotion_type, intensity, new_val])
	return effect

## --- Positive Resonance ---
func apply_positive_resonance(center_npc_id: String, radius: int = 2) -> Dictionary:
	_event_counter += 1
	var event_id = "geass_res_%d" % _event_counter
	
	# Affect nearby NPCs (same location or nearby in relationship graph)
	var center_npc = _nm.get_npc(center_npc_id) if _nm else {}
	if center_npc.is_empty():
		return {}
	
	var joy_val = center_npc.get("emotions", {}).get("joy", 0.0)
	var affected = []
	
	# Find nearby NPCs in relationship graph
	var related = _nm.get_related_npcs(center_npc_id) if _nm else {}
	for rel in related.get("positive", []) + related.get("neutral", []):
		var nid = rel.get("id")
		var npc = _nm.get_npc(nid) if _nm else {}
		if not npc.is_empty():
			var emotions = npc.get("emotions", {})
			var new_joy = clampf(emotions.get("joy", 0.0) + joy_val * 0.5, 0.0, 1.0)
			emotions["joy"] = new_joy
			_nm.update_npc(nid, {"emotions": emotions}) if _nm else null
			affected.append(nid)
	
	var effect = {
		"id": event_id,
		"type": GeassType.POSITIVE_RESONANCE,
		"center_npc_id": center_npc_id,
		"affected_npcs": affected,
		"day": _gs.get_day() if _gs else 1,
		"minute": _gs.get_minute_of_day() if _gs else 0,
		"intensity": joy_val,
		"applied": true,
	}
	_active_effects.append(effect)
	
	if _eb:
		_eb.world_event_triggered.emit(event_id)
	
	print("[Geass] Positive resonance centered on %s, affected %d NPCs" % [center_npc_id, affected.size()])
	return effect

## --- Emotion Transference ---
func transfer_emotion(from_npc_id: String, to_npc_id: String, emotion_type: String, transfer_rate: float = 0.5) -> Dictionary:
	_event_counter += 1
	var event_id = "geass_trans_%d" % _event_counter
	
	var from_npc = _nm.get_npc(from_npc_id) if _nm else {}
	var to_npc = _nm.get_npc(to_npc_id) if _nm else {}
	if from_npc.is_empty() or to_npc.is_empty():
		return {}
	
	var from_emotions = from_npc.get("emotions", {})
	var to_emotions = to_npc.get("emotions", {})
	var from_val = from_emotions.get(emotion_type, 0.0)
	var transferred = from_val * transfer_rate
	
	var new_to_val = clampf(to_emotions.get(emotion_type, 0.0) + transferred, 0.0, 1.0)
	to_emotions[emotion_type] = new_to_val
	_nm.update_npc(to_npc_id, {"emotions": to_emotions}) if _nm else null
	
	var effect = {
		"id": event_id,
		"type": GeassType.EMOTION_TRANSMISSION,
		"from_npc_id": from_npc_id,
		"to_npc_id": to_npc_id,
		"emotion_type": emotion_type,
		"transferred": transferred,
		"day": _gs.get_day() if _gs else 1,
		"minute": _gs.get_minute_of_day() if _gs else 0,
		"applied": true,
	}
	_active_effects.append(effect)
	
	if _eb:
		_eb.world_event_triggered.emit(event_id)
	
	return effect

## --- Relationship Change ---
func modify_relationship_geass(npc_a: String, npc_b: String, delta: float, reason: String = "geass") -> void:
	_nm.modify_relationship(npc_a, npc_b, delta) if _nm else null
	print("[Geass] Relationship %s<->%s changed by %+.1f (%s)" % [npc_a, npc_b, delta, reason])

## --- Geass Grant ---
func grant_geass(npc_id: String, geass_type: String, source_type: String = GEASS_SOURCE_CODE_HOLDER) -> Dictionary:
	_event_counter += 1
	var event_id = "geass_grant_%d" % _event_counter
	var npc = _nm.get_npc(npc_id) if _nm else {}
	if npc.is_empty():
		return {}
	
	npc["hasGeass"] = true
	npc["geassType"] = geass_type
	_nm.update_npc(npc_id, {"hasGeass": true, "geassType": geass_type}) if _nm else null
	
	var effect = {
		"id": event_id,
		"type": GeassType.GEASS_GRANT,
		"target_id": npc_id,
		"geass_type": geass_type,
		"source_type": source_type,
		"day": _gs.get_day() if _gs else 1,
		"minute": _gs.get_minute_of_day() if _gs else 0,
		"applied": true,
	}
	_active_effects.append(effect)
	
	if _eb:
		_eb.geass_triggered.emit(npc_id, geass_type, source_type)
		_eb.world_event_triggered.emit(event_id)
	
	print("[Geass] Geass %s granted to %s by %s" % [geass_type, npc_id, source_type])
	return effect

## --- Reverbation (secondary effects) ---
func apply_reverberation(center_npc_id: String, emotion_types: Array, intensity: float) -> void:
	# NPCs related to NPCs affected by geass get secondary effects
	var related = _nm.get_related_npcs(center_npc_id) if _nm else {}
	for rel in related.get("neutral", []) + related.get("positive", []):
		var nid = rel.get("id")
		var npc = _nm.get_npc(nid) if _nm else {}
		if not npc.is_empty():
			var emotions = npc.get("emotions", {})
			for et in emotion_types:
				var cur = emotions.get(et, 0.0)
				emotions[et] = clampf(cur + intensity * 0.3, 0.0, 1.0)
			_nm.update_npc(nid, {"emotions": emotions}) if _nm else null

## --- Social Epicenter ---
func apply_social_epicenter(npc_id: String, behavior_change: String) -> Dictionary:
	_event_counter += 1
	var event_id = "geass_epic_%d" % _event_counter
	var npc = _nm.get_npc(npc_id) if _nm else {}
	if npc.is_empty():
		return {}
	
	npc["currentAction"] = behavior_change
	_nm.update_npc(npc_id, {"currentAction": behavior_change}) if _nm else null
	
	var effect = {
		"id": event_id,
		"type": GeassType.SOCIAL_EPICENTER,
		"target_id": npc_id,
		"behavior_change": behavior_change,
		"day": _gs.get_day() if _gs else 1,
		"minute": _gs.get_minute_of_day() if _gs else 0,
		"applied": true,
	}
	_active_effects.append(effect)
	
	if _eb:
		_eb.world_event_triggered.emit(event_id)
	
	return effect

## --- World abstract state update helpers ---
func update_world_from_geass(geass_type: String, intensity: float) -> void:
	var world = _gs.get_world() if _gs else {}
	match geass_type:
		"memory_modification":
			world["geassSpread"] = world.get("geassSpread", 0) + int(intensity * 5)
		"emotion_amplification":
			world["socialUnrest"] = world.get("socialUnrest", 0) + int(intensity * 3)
		"geass_grant":
			world["geassSpread"] = world.get("geassSpread", 0) + 10
	_gs.set_world(world) if _gs else null

## --- Time tick ---
func on_time_tick(day: int, minute: int) -> void:
	# Probability of random geass event increases with world geassSpread
	var world = _gs.get_world() if _gs else {}
	var geass_spread = world.get("geassSpread", 0)
	var probability = minf(0.1, geass_spread * 0.002)
	
	if _rng and _rng.probability(probability):
		_trigger_random_geass_event()

func _trigger_random_geass_event() -> void:
	var npc_ids = _nm.get_npc_ids() if _nm else []
	if npc_ids.is_empty():
		return
	
	var target = _rng.choice(npc_ids) if _rng else npc_ids[0]
	var event_types = [
		GeassType.EMOTION_AMPLIFICATION,
		GeassType.RELATIONSHIP_CHANGE,
		GeassType.SOCIAL_EPICENTER,
	]
	var etype = event_types[_rng.randi_range_seeded(0, event_types.size() - 1)] if _rng else event_types[0]
	
	match etype:
		GeassType.EMOTION_AMPLIFICATION:
			var emotion_types = ["joy", "anger", "sadness", "fear", "anxiety"]
			var et = emotion_types[_rng.randi_range_seeded(0, emotion_types.size() - 1)] if _rng else "fear"
			amplify_emotion(target, et, _rng.randf_range_seeded(0.2, 0.5) if _rng else 0.3)
		GeassType.RELATIONSHIP_CHANGE:
			var npc_ids2 = npc_ids.filter(func(id): return id != target)
			if not npc_ids2.is_empty():
				var target2 = _rng.choice(npc_ids2) if _rng else npc_ids2[0]
				var delta = _rng.randf_range_seeded(-20.0, 20.0) if _rng else 0.0
				modify_relationship_geass(target, target2, delta, "random_geass")
		GeassType.SOCIAL_EPICENTER:
			var behaviors = ["panic", "rally", "flee", "guard", "argue"]
			var behavior = _rng.choice(behaviors) if _rng else "panic"
			apply_social_epicenter(target, str(behavior))

## --- Active effects access ---
func get_active_effects() -> Array:
	return _active_effects.duplicate(true)

func get_effects_for_npc(npc_id: String) -> Array:
	return _active_effects.filter(func(e): return e.get("target_id") == npc_id or e.get("center_npc_id") == npc_id).duplicate(true)

## --- Save/Load ---
func serialize() -> Dictionary:
	return {
		"active_effects": _active_effects.duplicate(true),
		"event_counter": _event_counter,
	}

func deserialize(data: Dictionary) -> void:
	if data.has("active_effects"):
		_active_effects = data["active_effects"].duplicate(true)
	if data.has("event_counter"):
		_event_counter = data["event_counter"]
