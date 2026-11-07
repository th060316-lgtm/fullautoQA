extends RefCounted

const ITEM_DEFINITIONS: Dictionary = {
	"ration": {"id": "ration", "type": "food", "weight": 0.5, "volume": 0.4, "uses": ["consume"], "compatibility": []},
	"medicine": {"id": "medicine", "type": "medical", "weight": 0.3, "volume": 0.2, "uses": ["treat"], "compatibility": ["human"]},
	"rifle_ammo": {"id": "rifle_ammo", "type": "ammunition", "weight": 0.02, "volume": 0.01, "uses": ["load"], "compatibility": ["rifle"]},
	"kmf_servo": {"id": "kmf_servo", "type": "kmf_part", "weight": 8.0, "volume": 6.0, "uses": ["repair", "equip"], "compatibility": ["sutherland_arm", "sutherland_leg"]},
	"field_rifle": {"id": "field_rifle", "type": "weapon", "weight": 4.0, "volume": 3.0, "uses": ["equip"], "compatibility": ["human"], "max_durability": 100.0},
}

static func add_item(campaign: Dictionary, item_id: String, quantity: int = 1, condition: float = 1.0) -> bool:
	if quantity <= 0 or not ITEM_DEFINITIONS.has(item_id):
		return false
	var added_weight := float(ITEM_DEFINITIONS[item_id].get("weight", 0.0)) * quantity
	if total_weight(campaign) + added_weight > float(campaign.get("inventory", {}).get("capacity", 0.0)) + 0.0001:
		return false
	var items: Dictionary = campaign["inventory"]["items"]
	var stack: Dictionary = items.get(item_id, {"item_id": item_id, "quantity": 0, "condition": 1.0, "durability": ITEM_DEFINITIONS[item_id].get("max_durability", -1.0), "metadata": {}})
	stack["quantity"] = int(stack.get("quantity", 0)) + quantity
	stack["condition"] = clampf(condition, 0.0, 1.0)
	items[item_id] = stack
	campaign["inventory"]["items"] = items
	return true

static func remove_item(campaign: Dictionary, item_id: String, quantity: int = 1) -> bool:
	var items: Dictionary = campaign.get("inventory", {}).get("items", {})
	if quantity <= 0 or not items.has(item_id) or int(items[item_id].get("quantity", 0)) < quantity:
		return false
	var stack: Dictionary = items[item_id]
	stack["quantity"] = int(stack["quantity"]) - quantity
	if int(stack["quantity"]) == 0:
		items.erase(item_id)
	else:
		items[item_id] = stack
	campaign["inventory"]["items"] = items
	return true

static func total_weight(campaign: Dictionary) -> float:
	var total := 0.0
	for item_id in campaign.get("inventory", {}).get("items", {}).keys():
		var quantity := int(campaign["inventory"]["items"][item_id].get("quantity", 0))
		total += float(ITEM_DEFINITIONS.get(item_id, {}).get("weight", 0.0)) * quantity
	return total
