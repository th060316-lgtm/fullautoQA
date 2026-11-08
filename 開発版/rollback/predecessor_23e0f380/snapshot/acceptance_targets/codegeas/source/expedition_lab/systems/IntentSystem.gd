extends RefCounted
class_name ExpeditionIntentSystem

const INTENTS := ["MOVE", "SCOUT", "CLEAR", "ASSAULT", "FIRE_POSITION"]

var fixture: Dictionary = {}

func _init(p_fixture: Dictionary = {}) -> void:
	fixture = p_fixture.duplicate(true)

func is_valid_intent(intent: String) -> bool:
	return intent in INTENTS

func preview(state, order_system, area_knowledge, equipment, actor_id: String, intent: String, destination: Vector2, waypoints: Array, facing_point: Vector2 = Vector2.INF) -> Dictionary:
	var actor = state.actors.get(actor_id)
	if actor == null:
		return {"ok":false,"reason":"no_actor"}
	if not is_valid_intent(intent):
		return {"ok":false,"reason":"invalid_intent"}
	var area: Rect2 = Rect2()
	var checkpoints: Array[Vector2] = []
	var target: Vector2 = destination
	var tactical_waypoints: Array = waypoints.duplicate()
	if intent == "SCOUT":
		area = Rect2(destination - Vector2(100, 100), Vector2(200, 200))
	elif intent == "CLEAR":
		area = Rect2(destination - Vector2(86, 70), Vector2(172, 140))
		checkpoints = _clear_checkpoints(area)
		tactical_waypoints.append_array(checkpoints)
		target = area.get_center()
	elif intent == "FIRE_POSITION":
		target = _best_fire_position(state, equipment, actor, destination)
	var move_preview: Dictionary = order_system.preview_move(state, actor_id, target, tactical_waypoints)
	if not bool(move_preview.get("ok", false)):
		return move_preview
	var path: Array = move_preview.get("path", [])
	var risk: float = _path_risk(state, path)
	var cover: float = _path_cover(path)
	var info_gain: float = 0.0
	if intent in ["SCOUT", "CLEAR"]:
		info_gain = 1.0 - area_knowledge.explored_ratio(area)
	var facing: float = float(actor.meta.get("facing", 0.0))
	if facing_point != Vector2.INF and facing_point.distance_to(target) > 1.0:
		facing = (facing_point - target).angle()
	elif intent in ["ASSAULT", "FIRE_POSITION"]:
		var contact: Dictionary = _nearest_confirmed_contact(state, target)
		if not contact.is_empty():
			facing = (contact.get("estimated_position", target) as Vector2 - target).angle()
	var preferred: float = equipment.preferred_range(actor)
	var weapon: Dictionary = equipment.choose_weapon(actor, preferred)
	return {
		"ok":true,
		"intent":intent,
		"actor_id":actor_id,
		"destination":target,
		"requested_destination":destination,
		"path":path,
		"eta":float(move_preview.get("eta",0.0)),
		"risk":risk,
		"cover":cover,
		"info_gain":info_gain,
		"area":area,
		"checkpoints":checkpoints,
		"waypoints":tactical_waypoints,
		"facing":facing,
		"weapon":weapon,
	}

func _clear_checkpoints(area: Rect2) -> Array[Vector2]:
	var inset: Vector2 = Vector2(28, 24)
	return [
		area.position + inset,
		Vector2(area.end.x - inset.x, area.position.y + inset.y),
		Vector2(area.end.x - inset.x, area.end.y - inset.y),
		Vector2(area.position.x + inset.x, area.end.y - inset.y),
		area.get_center(),
	]

func _best_fire_position(state, equipment, actor, requested: Vector2) -> Vector2:
	var contact := _nearest_confirmed_contact(state, requested)
	if contact.is_empty():
		return requested
	var enemy_pos: Vector2 = contact.get("estimated_position", requested)
	var preferred: float = equipment.preferred_range(actor)
	var candidates: Array[Vector2] = [requested]
	for rect in fixture.get("cover", []):
		candidates.append((rect as Rect2).get_center())
	var best: Vector2 = requested
	var best_score: float = -INF
	for candidate in candidates:
		if _point_blocked(candidate):
			continue
		var range_error: float = absf(candidate.distance_to(enemy_pos) - preferred)
		var cover_bonus: float = 80.0 if _point_in_cover(candidate) else 0.0
		var travel_penalty: float = actor.position.distance_to(candidate) * 0.08
		var score: float = cover_bonus - range_error - travel_penalty
		if score > best_score:
			best_score = score
			best = candidate
	return best

func _nearest_confirmed_contact(state, point: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_distance: float = INF
	for contact in state.knowledge.visible_contacts():
		if str(contact.get("status", "")) != "confirmed":
			continue
		var pos: Vector2 = contact.get("estimated_position", Vector2.ZERO)
		var d: float = point.distance_to(pos)
		if d < best_distance:
			best_distance = d
			best = contact
	return best

func _path_risk(state, path: Array) -> float:
	if path.is_empty():
		return 0.0
	var total: float = 0.0
	for point in path:
		var p: Vector2 = point
		var local: float = 0.0
		for contact in state.knowledge.visible_contacts():
			var status := str(contact.get("status", ""))
			if status == "unknown":
				continue
			var pos: Vector2 = contact.get("estimated_position", Vector2.ZERO)
			var d: float = p.distance_to(pos)
			var weight: float = 1.0 if status == "confirmed" else (0.65 if status == "estimated" else 0.35)
			if d < 260.0:
				local = maxf(local, (1.0 - d / 260.0) * weight)
		total += local
	return clampf(total / float(path.size()), 0.0, 1.0)

func _path_cover(path: Array) -> float:
	if path.is_empty():
		return 0.0
	var covered: int = 0
	for point in path:
		if _point_in_cover(point):
			covered += 1
	return float(covered) / float(path.size())

func _point_in_cover(point: Vector2) -> bool:
	for rect in fixture.get("cover", []):
		if (rect as Rect2).grow(18.0).has_point(point):
			return true
	return false


func _point_blocked(point: Vector2) -> bool:
	for rect in fixture.get("blocked", []):
		if (rect as Rect2).has_point(point):
			return true
	return false
