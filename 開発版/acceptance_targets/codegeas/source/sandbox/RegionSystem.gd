extends RefCounted

static func get_region(campaign: Dictionary, region_id: String) -> Dictionary:
	return campaign.get("regions", {}).get(region_id, {}).duplicate(true)

static func update_region(campaign: Dictionary, region_id: String, patch: Dictionary) -> bool:
	if not campaign.get("regions", {}).has(region_id):
		return false
	var region: Dictionary = campaign["regions"][region_id]
	for key in patch.keys():
		region[key] = patch[key]
	region["danger"] = clampi(int(region.get("danger", 0)), 0, 100)
	region["exploration"] = clampf(float(region.get("exploration", 0.0)), 0.0, 1.0)
	region["supplies"] = maxf(0.0, float(region.get("supplies", 0.0)))
	campaign["regions"][region_id] = region
	return true

static func available_destinations(campaign: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for region_id in campaign.get("regions", {}).keys():
		var region: Dictionary = campaign["regions"][region_id]
		if not bool(region.get("blockaded", false)) and not region.get("available_sites", []).is_empty():
			result.append(str(region_id))
	result.sort()
	return result
