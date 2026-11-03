extends RefCounted
class_name ExpeditionTacticalEquipment

var cooldowns: Dictionary = {}
var shield_strength: Dictionary = {}
var suppression: Dictionary = {}

func reset() -> void:
	cooldowns.clear()
	shield_strength.clear()
	suppression.clear()

func configure_actor(actor, preset: String = "balanced") -> void:
	if actor == null:
		return
	actor.meta["loadout_preset"] = preset
	if not actor.meta.has("facing"):
		actor.meta["facing"] = 0.0
	if actor.kind == "kmf" or preset == "heavy":
		shield_strength[actor.id] = 150.0 if actor.kind == "kmf" else 80.0
	elif not shield_strength.has(actor.id):
		shield_strength[actor.id] = 0.0
	if not suppression.has(actor.id):
		suppression[actor.id] = 0.0
	if not cooldowns.has(actor.id):
		cooldowns[actor.id] = 0.0

func tick(state, delta: float) -> void:
	for id in cooldowns.keys():
		cooldowns[id] = maxf(0.0, float(cooldowns[id]) - delta)
	for id in suppression.keys():
		var value: float = maxf(0.0, float(suppression[id]) - delta * 0.12)
		suppression[id] = value
		var actor = state.actors.get(str(id))
		if actor != null:
			actor.meta["suppression"] = value
			actor.meta["suppression_mobility"] = lerpf(1.0, 0.55, value)
			actor.meta["suppression_observation"] = lerpf(1.0, 0.50, value)
			actor.meta["suppression_accuracy"] = lerpf(1.0, 0.45, value)

func can_attack(actor_id: String) -> bool:
	return float(cooldowns.get(actor_id, 0.0)) <= 0.0

func trigger_cooldown(actor_id: String, seconds: float) -> void:
	cooldowns[actor_id] = maxf(0.0, seconds)

func apply_suppression(actor_id: String, amount: float) -> float:
	var value := clampf(float(suppression.get(actor_id, 0.0)) + amount, 0.0, 1.0)
	suppression[actor_id] = value
	return value

func _profiles(actor) -> Array:
	var preset: String = str(actor.meta.get("loadout_preset", "balanced"))
	if actor.kind == "kmf":
		if preset == "stealth":
			return [
				{"slot":"primary","name":"低出力ライフル","min":70.0,"preferred":210.0,"max":290.0,"damage":20.0,"cooldown":1.25,"noise":250.0,"suppression":0.12},
				{"slot":"sidearm","name":"KMFサイドアーム","min":25.0,"preferred":105.0,"max":170.0,"damage":15.0,"cooldown":0.75,"noise":180.0,"suppression":0.07},
				{"slot":"melee","name":"近接ブレード","min":0.0,"preferred":28.0,"max":48.0,"damage":36.0,"cooldown":0.85,"noise":70.0,"suppression":0.04},
			]
		return [
			{"slot":"primary","name":"KMFライフル","min":80.0,"preferred":235.0,"max":330.0,"damage":25.0,"cooldown":1.15,"noise":340.0,"suppression":0.16},
			{"slot":"sidearm","name":"KMFサイドアーム","min":20.0,"preferred":110.0,"max":175.0,"damage":17.0,"cooldown":0.70,"noise":210.0,"suppression":0.08},
			{"slot":"melee","name":"近接ブレード","min":0.0,"preferred":30.0,"max":52.0,"damage":38.0,"cooldown":0.82,"noise":80.0,"suppression":0.05},
		]
	if preset == "stealth":
		return [
			{"slot":"primary","name":"低騒音カービン","min":35.0,"preferred":135.0,"max":190.0,"damage":7.0,"cooldown":0.65,"noise":135.0,"suppression":0.07},
			{"slot":"sidearm","name":"サイドアーム","min":0.0,"preferred":55.0,"max":105.0,"damage":6.0,"cooldown":0.48,"noise":110.0,"suppression":0.04},
			{"slot":"melee","name":"近接武器","min":0.0,"preferred":18.0,"max":30.0,"damage":12.0,"cooldown":0.70,"noise":38.0,"suppression":0.02},
		]
	if preset == "heavy":
		return [
			{"slot":"primary","name":"支援ライフル","min":55.0,"preferred":175.0,"max":245.0,"damage":10.0,"cooldown":0.72,"noise":310.0,"suppression":0.20},
			{"slot":"sidearm","name":"サイドアーム","min":0.0,"preferred":60.0,"max":110.0,"damage":6.0,"cooldown":0.48,"noise":130.0,"suppression":0.05},
			{"slot":"melee","name":"近接武器","min":0.0,"preferred":18.0,"max":30.0,"damage":13.0,"cooldown":0.70,"noise":45.0,"suppression":0.02},
		]
	return [
		{"slot":"primary","name":"カービン","min":40.0,"preferred":155.0,"max":225.0,"damage":8.0,"cooldown":0.62,"noise":260.0,"suppression":0.10},
		{"slot":"sidearm","name":"サイドアーム","min":0.0,"preferred":60.0,"max":110.0,"damage":6.0,"cooldown":0.45,"noise":145.0,"suppression":0.05},
		{"slot":"melee","name":"近接武器","min":0.0,"preferred":18.0,"max":30.0,"damage":12.0,"cooldown":0.70,"noise":45.0,"suppression":0.02},
	]

func choose_weapon(actor, distance: float) -> Dictionary:
	if actor == null:
		return {}
	var effects: Dictionary = actor.get_effects()
	if bool(effects.get("weapon_disabled", false)):
		return {}
	var profiles: Array = _profiles(actor)
	var best: Dictionary = {}
	var best_score: float = -99999.0
	for profile in profiles:
		var min_r: float = float(profile["min"])
		var max_r: float = float(profile["max"])
		var pref: float = float(profile["preferred"])
		var score: float = -absf(distance - pref)
		if distance < min_r:
			score -= (min_r - distance) * 4.0
		if distance > max_r:
			score -= (distance - max_r) * 5.0
		if str(profile["slot"]) == "melee" and distance <= max_r:
			score += 28.0
		if score > best_score:
			best_score = score
			best = profile.duplicate(true)
	best["score"] = best_score
	return best

func preferred_range(actor) -> float:
	var profiles := _profiles(actor)
	return 150.0 if profiles.is_empty() else float(profiles[0].get("preferred", 150.0))

func max_range(actor) -> float:
	var profiles := _profiles(actor)
	var result: float = 0.0
	for profile in profiles:
		result = maxf(result, float(profile.get("max", 0.0)))
	return result

func resolve_incoming(actor, source_position: Vector2, raw_damage: float) -> Dictionary:
	if actor == null:
		return {"damage": raw_damage, "blocked": false, "shield": 0.0}
	var strength: float = float(shield_strength.get(actor.id, 0.0))
	if strength <= 0.0:
		return {"damage": raw_damage, "blocked": false, "shield": 0.0}
	var facing: Vector2 = Vector2.RIGHT.rotated(float(actor.meta.get("facing", 0.0))).normalized()
	var incoming: Vector2 = (source_position - actor.position).normalized()
	var within_arc: bool = facing.dot(incoming) >= cos(deg_to_rad(60.0))
	if not within_arc:
		return {"damage": raw_damage, "blocked": false, "shield": strength}
	var mitigation: float = 0.58 if strength > 55.0 else 0.34
	var absorbed: float = raw_damage * mitigation
	strength = maxf(0.0, strength - absorbed * 0.32)
	shield_strength[actor.id] = strength
	return {"damage": maxf(0.0, raw_damage - absorbed), "blocked": true, "absorbed": absorbed, "shield": strength}
