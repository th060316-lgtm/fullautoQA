extends RefCounted
class_name ExpeditionSoundEventSystem

var events: Array[Dictionary] = []
var next_id := 1
var retention_seconds := 8.0

func reset() -> void:
	events.clear()
	next_id = 1

func emit_sound(position: Vector2, radius: float, intensity: float, kind: String, source_id: String, sim_time: float, team: String = "") -> Dictionary:
	var event := {
		"id": next_id,
		"position": position,
		"radius": maxf(0.0, radius),
		"intensity": clampf(intensity, 0.0, 2.0),
		"kind": kind,
		"source_id": source_id,
		"time": sim_time,
		"team": team,
	}
	next_id += 1
	events.append(event)
	prune(sim_time)
	return event.duplicate(true)

func prune(sim_time: float) -> void:
	var kept: Array[Dictionary] = []
	for event in events:
		if sim_time - float(event.get("time", 0.0)) <= retention_seconds:
			kept.append(event)
	events = kept

func audible_events(observer_position: Vector2, hearing_multiplier: float, since_time: float, sim_time: float) -> Array:
	prune(sim_time)
	var out: Array = []
	for event in events:
		if float(event.get("time", 0.0)) <= since_time:
			continue
		var radius := float(event.get("radius", 0.0)) * maxf(0.1, hearing_multiplier)
		if observer_position.distance_to(event.get("position", Vector2.ZERO)) <= radius:
			out.append(event.duplicate(true))
	return out
