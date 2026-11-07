extends RefCounted

const KnowledgeState = preload("res://expedition_lab/state/KnowledgeState.gd")

func sensor_range(actor) -> float:
	var base := 170.0 if actor.kind == "human" else 300.0
	var effects: Dictionary = actor.get_effects()
	return base * float(actor.meta.get("sensor", 1.0)) * float(effects.get("detection_multiplier", 1.0)) * float(actor.meta.get("suppression_observation", 1.0))

func scan(state, observer_id: String) -> Array:
	var observer = state.actors.get(observer_id)
	var events: Array = []
	if observer == null or not observer.is_active() or observer.incapacitated:
		return events
	if observer.kind=="human" and not str(observer.meta.get("inside_kmf","")).is_empty():
		return events
	if observer.kind=="kmf" and observer.team=="player" and not bool(observer.meta.get("boarded",false)):
		return events
	var radius := sensor_range(observer)
	for enemy_id in state.enemy_truth.keys():
		var enemy = state.actors.get(enemy_id)
		if enemy == null or enemy.destroyed:
			continue
		var distance: float = observer.position.distance_to(enemy.position)
		if distance <= radius * 0.45:
			events.append(state.knowledge.observe(enemy_id, KnowledgeState.CONFIRMED, "visual:"+observer_id, 1.0, state.sim_time, enemy.position, 0.0))
		elif distance <= radius:
			var estimate: Vector2 = observer.position.lerp(enemy.position, 0.82).round()
			events.append(state.knowledge.observe(enemy_id, KnowledgeState.ESTIMATED, "sensor:"+observer_id, 0.68, state.sim_time, estimate, 54.0))
	return events

func scan_sounds(state, observer_id: String, sound_system, since_time: float) -> Array:
	var observer = state.actors.get(observer_id)
	var events: Array = []
	if observer == null or not observer.is_active() or observer.incapacitated or sound_system == null:
		return events
	var hearing := 1.0 if observer.kind == "human" else 1.35
	for sound in sound_system.audible_events(observer.position, hearing, since_time, state.sim_time):
		if str(sound.get("team", "")) == "player":
			continue
		var source_id := str(sound.get("source_id", ""))
		if source_id.is_empty() or not state.actors.has(source_id):
			continue
		if state.knowledge.has_exact_truth(source_id):
			continue
		var true_pos: Vector2 = sound.get("position", observer.position)
		var uncertainty := clampf(150.0 - float(sound.get("intensity", 1.0)) * 38.0, 65.0, 150.0)
		var angle := deg_to_rad(float(abs((source_id + ":" + observer_id).hash()) % 360))
		var estimate := true_pos + Vector2.RIGHT.rotated(angle) * uncertainty * 0.45
		events.append(state.knowledge.observe(source_id, KnowledgeState.SIGNAL, "sound:"+observer_id, 0.36, state.sim_time, estimate, uncertainty))
	return events

func ordered_observe(state, observer_id: String, contact_id: String) -> Dictionary:
	var observer = state.actors.get(observer_id)
	var enemy = state.actors.get(contact_id)
	if observer == null or enemy == null:
		return {"ok":false,"reason":"missing_actor"}
	if observer.incapacitated or observer.destroyed:
		return {"ok":false,"reason":"observer_incapacitated"}
	if not state.knowledge.contacts.has(contact_id):
		return {"ok":false,"reason":"unknown_contact"}
	var radius := sensor_range(observer)
	var distance: float = observer.position.distance_to(enemy.position)
	if distance > radius:
		return {"ok":false,"reason":"out_of_observation_range"}
	var level := KnowledgeState.CONFIRMED if distance <= radius * 0.45 else KnowledgeState.ESTIMATED
	var estimate: Vector2 = enemy.position if level == KnowledgeState.CONFIRMED else observer.position.lerp(enemy.position, 0.82).round()
	var uncertainty := 0.0 if level == KnowledgeState.CONFIRMED else 54.0
	var confidence := 1.0 if level == KnowledgeState.CONFIRMED else 0.72
	var event: Dictionary = state.knowledge.observe(contact_id, level, "ordered_observation:"+observer_id, confidence, state.sim_time, estimate, uncertainty)
	return {"ok":true,"level":level,"event":event}

func report_signal(state, contact_id: String, position: Vector2) -> Dictionary:
	return state.knowledge.observe(contact_id, KnowledgeState.SIGNAL, "resident_report", 0.4, state.sim_time, position, 140.0)
