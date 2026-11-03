extends RefCounted

static func register(campaign: Dictionary, companion: Dictionary) -> bool:
	var companion_id := str(companion.get("id", ""))
	if companion_id.is_empty() or campaign.get("companions", {}).has(companion_id):
		return false
	var data := {
		"id": companion_id,
		"display_name": str(companion.get("display_name", companion_id)),
		"role": str(companion.get("role", "survivor")),
		"alive": bool(companion.get("alive", true)),
		"injuries": companion.get("injuries", []).duplicate(true),
		"traits": companion.get("traits", []).duplicate(true),
		"skills": companion.get("skills", {"combat": 0, "medical": 0, "maintenance": 0, "kmf_aptitude": 0}).duplicate(true),
		"relationships": companion.get("relationships", {}).duplicate(true),
		"known_information": companion.get("known_information", []).duplicate(true),
	}
	campaign["companions"][companion_id] = data
	if companion_id not in campaign["base"]["companion_ids"]:
		campaign["base"]["companion_ids"].append(companion_id)
	return true

static func add_injury(campaign: Dictionary, companion_id: String, injury: Dictionary) -> bool:
	if not campaign.get("companions", {}).has(companion_id) or str(injury.get("id", "")).is_empty():
		return false
	var companion: Dictionary = campaign["companions"][companion_id]
	companion["injuries"].append(injury.duplicate(true))
	campaign["companions"][companion_id] = companion
	if companion_id not in campaign["base"]["injured_ids"]:
		campaign["base"]["injured_ids"].append(companion_id)
	return true
