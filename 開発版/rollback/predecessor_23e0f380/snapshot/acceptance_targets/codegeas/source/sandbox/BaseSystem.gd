extends RefCounted

static func adjust_resource(campaign: Dictionary, resource_id: String, delta: float) -> bool:
	var resources: Dictionary = campaign.get("base", {}).get("resources", {})
	if not resources.has(resource_id):
		return false
	var next_value := float(resources[resource_id]) + delta
	if next_value < 0.0:
		return false
	resources[resource_id] = next_value
	campaign["base"]["resources"] = resources
	return true

static func store_equipment(campaign: Dictionary, item_id: String) -> bool:
	if item_id.is_empty():
		return false
	if item_id not in campaign["base"]["equipment_ids"]:
		campaign["base"]["equipment_ids"].append(item_id)
	return true

static func register_kmf(campaign: Dictionary, kmf_id: String) -> bool:
	if kmf_id.is_empty() or kmf_id in campaign["base"]["kmf_ids"]:
		return false
	campaign["base"]["kmf_ids"].append(kmf_id)
	return true
