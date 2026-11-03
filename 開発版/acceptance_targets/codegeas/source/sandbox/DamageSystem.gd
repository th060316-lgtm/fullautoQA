extends RefCounted
## Shared part-damage API with separate human and KMF body profiles.

const PROFILES: Dictionary = {
	"human": {
		"head": {"max_hp": 35.0, "vital": true}, "torso": {"max_hp": 100.0, "vital": true},
		"right_arm": {"max_hp": 55.0, "vital": false}, "left_arm": {"max_hp": 55.0, "vital": false},
		"right_leg": {"max_hp": 65.0, "vital": false}, "left_leg": {"max_hp": 65.0, "vital": false},
	},
	"kmf": {
		"cockpit": {"max_hp": 60.0, "vital": true}, "sensor": {"max_hp": 40.0, "vital": false},
		"frame": {"max_hp": 180.0, "vital": true}, "right_arm": {"max_hp": 80.0, "vital": false},
		"left_arm": {"max_hp": 80.0, "vital": false}, "right_leg": {"max_hp": 100.0, "vital": false},
		"left_leg": {"max_hp": 100.0, "vital": false}, "weapon": {"max_hp": 50.0, "vital": false},
		"energy": {"max_hp": 70.0, "vital": false},
	},
}

static func create_body(profile_id: String) -> Dictionary:
	if not PROFILES.has(profile_id):
		return {}
	var parts: Dictionary = {}
	for part_id in PROFILES[profile_id].keys():
		var definition: Dictionary = PROFILES[profile_id][part_id]
		parts[part_id] = {"hp": float(definition["max_hp"]), "max_hp": float(definition["max_hp"]), "disabled": false, "destroyed": false}
	return {"profile_id": profile_id, "parts": parts, "incapacitated": false}

static func apply_damage(body: Dictionary, part_id: String, amount: float) -> Dictionary:
	if amount <= 0.0 or not body.get("parts", {}).has(part_id):
		return {"applied": false, "reason": "invalid_target"}
	var part: Dictionary = body["parts"][part_id]
	var before := float(part.get("hp", 0.0))
	part["hp"] = maxf(0.0, before - amount)
	part["disabled"] = float(part["hp"]) <= 0.0
	part["destroyed"] = float(part["hp"]) <= 0.0
	body["parts"][part_id] = part
	var profile_id := str(body.get("profile_id", ""))
	if bool(PROFILES.get(profile_id, {}).get(part_id, {}).get("vital", false)) and float(part["hp"]) <= 0.0:
		body["incapacitated"] = true
	return {"applied": true, "part_id": part_id, "damage": minf(before, amount), "disabled": bool(part["disabled"]), "incapacitated": bool(body.get("incapacitated", false))}
