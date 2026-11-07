extends RefCounted

static func adjust_reputation(campaign: Dictionary, faction_id: String, delta: int) -> bool:
	if not campaign.get("factions", {}).has(faction_id):
		return false
	var faction: Dictionary = campaign["factions"][faction_id]
	faction["reputation"] = clampi(int(faction.get("reputation", 0)) + delta, -100, 100)
	campaign["factions"][faction_id] = faction
	return true

static func set_region_control(campaign: Dictionary, region_id: String, faction_id: String) -> bool:
	if not campaign.get("regions", {}).has(region_id) or not campaign.get("factions", {}).has(faction_id):
		return false
	for id in campaign["factions"].keys():
		var faction: Dictionary = campaign["factions"][id]
		faction["controlled_regions"].erase(region_id)
		campaign["factions"][id] = faction
	campaign["factions"][faction_id]["controlled_regions"].append(region_id)
	campaign["regions"][region_id]["controller"] = faction_id
	return true
