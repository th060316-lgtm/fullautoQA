extends RefCounted
## Cause-driven candidate evaluation. Stable ID ordering makes seeded choice reproducible.

const IncidentSystem = preload("res://sandbox/IncidentSystem.gd")

static func eligible_candidates(candidates: Array, campaign: Dictionary, world: Dictionary) -> Array:
	var eligible: Array = []
	for candidate in candidates:
		if _conditions_met(candidate.get("conditions", {}), candidate, campaign, world):
			eligible.append(candidate.duplicate(true))
	eligible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return eligible

static func select_candidate(candidates: Array, campaign: Dictionary, world: Dictionary, seed_value: int) -> Dictionary:
	var eligible := eligible_candidates(candidates, campaign, world)
	if eligible.is_empty():
		return {}
	var total := 0.0
	for candidate in eligible:
		total += maxf(0.0, float(candidate.get("weight", 1.0)))
	if total <= 0.0:
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var roll := rng.randf_range(0.0, total)
	var cursor := 0.0
	for candidate in eligible:
		cursor += maxf(0.0, float(candidate.get("weight", 1.0)))
		if roll <= cursor:
			return candidate
	return eligible.back()

static func evaluate_and_fire(candidates: Array, campaign: Dictionary, world: Dictionary, seed_value: int, now_total_minutes: int) -> Dictionary:
	var selected := select_candidate(candidates, campaign, world, seed_value)
	if selected.is_empty() or str(selected.get("initial_status", "hidden")) != "hidden":
		return {}
	if not IncidentSystem.register(campaign, selected, now_total_minutes):
		return {}
	var incident_id := str(selected.get("id", ""))
	if not IncidentSystem.transition(campaign, incident_id, "discovered"):
		campaign["incidents"].erase(incident_id)
		return {}
	if not IncidentSystem.transition(campaign, incident_id, "available"):
		campaign["incidents"].erase(incident_id)
		return {}
	var director: Dictionary = campaign.get("director", {})
	director["last_incident_id"] = incident_id
	director["last_evaluation"] = {"seed": seed_value, "eligible_ids": eligible_candidates(candidates, campaign, world).map(func(item: Dictionary): return str(item.get("id", "")))}
	var history: Array = director.get("history", [])
	history.append({"incident_id": incident_id, "fired_at": now_total_minutes, "seed": seed_value})
	director["history"] = history
	campaign["director"] = director
	return campaign["incidents"][incident_id]

static func _conditions_met(conditions: Dictionary, candidate: Dictionary, campaign: Dictionary, world: Dictionary) -> bool:
	var supported: Array[String] = ["required_world_flag", "region_danger_min", "base_resource_below", "required_tag"]
	for key in conditions.keys():
		if str(key) not in supported:
			return false
	if conditions.has("required_world_flag") and not bool(world.get(str(conditions["required_world_flag"]), false)):
		return false
	if conditions.has("region_danger_min"):
		var region_id := str(candidate.get("region_id", ""))
		var danger := int(campaign.get("regions", {}).get(region_id, {}).get("danger", -1))
		if danger < int(conditions["region_danger_min"]):
			return false
	if conditions.has("base_resource_below"):
		for resource_id in conditions["base_resource_below"].keys():
			var current := float(campaign.get("base", {}).get("resources", {}).get(resource_id, INF))
			if current >= float(conditions["base_resource_below"][resource_id]):
				return false
	if conditions.has("required_tag"):
		if str(conditions["required_tag"]) not in candidate.get("tags", []):
			return false
	return true
