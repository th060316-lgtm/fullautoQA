extends RefCounted
## JSON-safe defaults for the post-Day1 sandbox foundation.
## Content stays intentionally small; systems consume this data without DayN controllers.

const CAMPAIGN_SCHEMA_VERSION: int = 1

static func create_campaign() -> Dictionary:
	return {
		"schema_version": CAMPAIGN_SCHEMA_VERSION,
		"mode": "prologue",
		"status": "active",
		"clock": {"day": 1, "minute_of_day": 8 * 60},
		"source": {"day1_completed": false, "day1_result": "", "bridge_version": 1},
		"regions": create_regions(),
		"incidents": {},
		"expedition": {"state": "idle", "region_id": "", "party_ids": [], "loadout_ids": [], "started_at": {}, "outcome": {}},
		"inventory": {"capacity": 30.0, "items": {}},
		"companions": {},
		"base": {"resources": {"food": 3.0, "medicine": 1.0, "maintenance": 1.0}, "injured_ids": [], "equipment_ids": [], "kmf_ids": [], "companion_ids": [], "human_status": {}, "kmf_status": {}},
		"factions": create_factions(),
		"director": {"history": [], "last_incident_id": "", "last_evaluation": {}},
	}

static func create_regions() -> Dictionary:
	return {
		"base": create_region("base", "避難拠点", "survivors", 10, ["shelter"]),
		"city_center": create_region("city_center", "市街中心部", "contested", 55, ["urban", "loot"]),
		"hospital_district": create_region("hospital_district", "病院地区", "contested", 62, ["urban", "medical", "intel", "rescue"]),
		"industrial_area": create_region("industrial_area", "工業地域", "britannia", 70, ["industrial", "kmf_parts"]),
	}

static func create_region(region_id: String, display_name: String, controller: String, danger: int, site_tags: Array) -> Dictionary:
	return {
		"id": region_id, "display_name": display_name, "controller": controller,
		"danger": danger, "exploration": 0.0, "supplies": 50.0, "population": 0,
		"enemy_strength": 0, "rumors": [], "blockaded": false, "time_of_day": "day",
		"available_sites": site_tags.duplicate(true),
	}

static func create_factions() -> Dictionary:
	return {
		"survivors": {"id": "survivors", "reputation": 0, "alert": 0, "price_modifier": 1.0, "controlled_regions": ["base"]},
		"britannia": {"id": "britannia", "reputation": -10, "alert": 20, "price_modifier": 1.1, "controlled_regions": ["industrial_area"]},
		"resistance": {"id": "resistance", "reputation": 0, "alert": 10, "price_modifier": 1.0, "controlled_regions": []},
	}

static func create_incident_templates() -> Array:
	return [
		{"id": "medical_shortage", "tags": ["survival", "medical"], "region_id": "base", "weight": 4.0, "conditions": {"base_resource_below": {"medicine": 2.0}}, "deadline_minutes": 480, "objectives": [{"id": "deliver_medicine", "target": 2}], "success_consequences": [{"type": "base_resource", "id": "medicine", "delta": 2.0}], "failure_consequences": [{"type": "danger", "region_id": "base", "delta": 5}]},
		{"id": "industrial_salvage", "tags": ["loot", "kmf"], "region_id": "industrial_area", "weight": 2.0, "conditions": {"region_danger_min": 40}, "deadline_minutes": 720, "objectives": [{"id": "recover_kmf_part", "target": 1}], "success_consequences": [{"type": "loot", "item_id": "kmf_servo", "quantity": 1}], "failure_consequences": []},
		{"id": "false_curfew_rumor", "tags": ["information", "rumor"], "region_id": "city_center", "weight": 1.0, "conditions": {"required_world_flag": "curfew_rumor_known"}, "deadline_minutes": 240, "objectives": [{"id": "verify_rumor", "target": 1}], "success_consequences": [{"type": "information_verified", "id": "curfew"}], "failure_consequences": []},
	]

