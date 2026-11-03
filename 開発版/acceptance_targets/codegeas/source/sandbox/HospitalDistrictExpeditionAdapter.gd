extends RefCounted
## Adapter boundary between Campaign JSON-safe state and the authored expedition fixture.

const ExpeditionSystem = preload("res://sandbox/ExpeditionSystem.gd")
const InventorySystem = preload("res://sandbox/InventorySystem.gd")
const CompanionSystem = preload("res://sandbox/CompanionSystem.gd")
const RegionSystem = preload("res://sandbox/RegionSystem.gd")

const SITE_ID := "hospital_district"
const LOOT_TO_ITEM := {"medical_cache": ["medicine", 2], "spare_parts": ["kmf_servo", 1], "food_crate": ["ration", 4]}

static func launch(campaign: Dictionary, seed_override: int = -1) -> Dictionary:
	var base: Dictionary = campaign.get("base", {})
	var default_party: Array = ["hero"]
	for companion_id in base.get("companion_ids", []):
		default_party.append(str(companion_id))
	var default_loadout: Array = campaign.get("inventory", {}).get("items", {}).keys()
	default_loadout.sort()
	return launch_with_preparation(campaign, {
		"party_ids":default_party,
		"loadout_ids":default_loadout,
		"kmf_ids":base.get("kmf_ids", []).duplicate(true),
	}, seed_override)

static func launch_with_preparation(campaign: Dictionary, preparation: Dictionary, seed_override: int = -1) -> Dictionary:
	if str(campaign.get("mode", "prologue")) != "sandbox":
		return {"ok": false, "reason": "sandbox_not_active"}
	if not campaign.get("regions", {}).has(SITE_ID):
		return {"ok": false, "reason": "region_unavailable"}
	if str(campaign.get("expedition", {}).get("state", "idle")) != "idle":
		return {"ok": false, "reason": "expedition_already_active"}
	var base: Dictionary = campaign.get("base", {})
	var human_status: Dictionary = base.get("human_status", {})
	if bool(human_status.get("hero", {}).get("incapacitated", false)):
		return {"ok": false, "reason": "hero_incapacitated"}
	var requested_party: Array = preparation.get("party_ids", ["hero"])
	var party_ids: Array = []
	for actor_id in requested_party:
		var cid := str(actor_id)
		if cid == "hero":
			if cid not in party_ids: party_ids.append(cid)
			continue
		if cid not in base.get("companion_ids", []):
			continue
		var companion: Dictionary = campaign.get("companions", {}).get(cid, {})
		if not bool(companion.get("alive", true)):
			continue
		if bool(human_status.get(cid, {}).get("incapacitated", false)):
			continue
		if cid not in party_ids:
			party_ids.append(cid)
	if not party_ids.has("hero"):
		party_ids.push_front("hero")
	var inventory_items: Dictionary = campaign.get("inventory", {}).get("items", {})
	var loadout_ids: Array = []
	for item_id in preparation.get("loadout_ids", []):
		var iid := str(item_id)
		if inventory_items.has(iid) and iid not in loadout_ids:
			loadout_ids.append(iid)
	loadout_ids.sort()
	var selected_kmf_ids: Array = []
	for kmf_id in preparation.get("kmf_ids", []):
		var kid := str(kmf_id)
		if kid in base.get("kmf_ids", []) and kid not in selected_kmf_ids:
			selected_kmf_ids.append(kid)
	if not ExpeditionSystem.begin_preparation(campaign, SITE_ID, party_ids, loadout_ids):
		return {"ok": false, "reason": "preparation_failed"}
	campaign["expedition"]["selected_kmf_ids"] = selected_kmf_ids
	campaign["expedition"]["preparation"] = {
		"party_ids":party_ids.duplicate(true),
		"loadout_ids":loadout_ids.duplicate(true),
		"kmf_ids":selected_kmf_ids.duplicate(true),
	}
	var clock: Dictionary = campaign.get("clock", {})
	var seed := seed_override
	if seed < 0:
		seed = int(clock.get("day", 1)) * 100000 + int(clock.get("minute_of_day", 0)) * 31 + 20261022
	var started_at := {"day": int(clock.get("day", 1)), "minute_of_day": int(clock.get("minute_of_day", 0))}
	if not ExpeditionSystem.transition(campaign, "deployed", {"started_at": started_at, "seed": seed, "site_id": SITE_ID}):
		return {"ok": false, "reason": "deployment_failed"}
	if not ExpeditionSystem.transition(campaign, "exploring"):
		return {"ok": false, "reason": "exploration_start_failed"}
	return _build_launch_snapshot(campaign, seed)

static func apply_outcome(campaign: Dictionary, outcome: Dictionary) -> Dictionary:
	var expedition: Dictionary = campaign.get("expedition", {})
	if str(expedition.get("region_id", "")) != SITE_ID or str(expedition.get("state", "")) not in ["deployed", "exploring", "extracting"]:
		return {"ok": false, "reason": "no_matching_expedition"}
	var success := bool(outcome.get("retreat_success", false))
	if str(expedition.get("state", "")) in ["deployed", "exploring"] and success:
		if not ExpeditionSystem.transition(campaign, "extracting"):
			return {"ok": false, "reason": "extracting_transition_failed"}
	var applied_items: Array[String] = []
	var abandoned_items: Array[String] = []
	var recovered_intel: Array = outcome.get("intel", []) if success else []
	var recovered_rescues: Array = outcome.get("rescued_civilians", []) if success else []
	for loot_id in outcome.get("loot", []):
		var mapping: Array = LOOT_TO_ITEM.get(str(loot_id), [])
		if mapping.is_empty(): continue
		# Collected field loot only reaches the campaign inventory after physical extraction.
		if not success:
			abandoned_items.append(str(loot_id))
			continue
		if InventorySystem.add_item(campaign, str(mapping[0]), int(mapping[1])):
			applied_items.append(str(mapping[0]))
		else:
			abandoned_items.append(str(loot_id))
	var region: Dictionary = campaign["regions"][SITE_ID]
	var rumors: Array = region.get("rumors", [])
	for intel_id in recovered_intel:
		var fact := "verified:" + str(intel_id)
		if fact not in rumors: rumors.append(fact)
	region["rumors"] = rumors
	region["exploration"] = clampf(float(region.get("exploration", 0.0)) + (0.18 if success else 0.05), 0.0, 1.0)
	var consequence: Dictionary = outcome.get("world_consequence", {})
	region["danger"] = clampi(int(region.get("danger", 0)) + int(consequence.get("alert_delta_candidate", 0)), 0, 100)
	region["population"] = int(region.get("population", 0)) + recovered_rescues.size()
	campaign["regions"][SITE_ID] = region
	for rescued_id in recovered_rescues:
		if not campaign.get("companions", {}).has(str(rescued_id)):
			CompanionSystem.register(campaign, {"id": str(rescued_id), "display_name": "病院地区の救助者", "role": "survivor", "traits": ["rescued_at_hospital"]})
	_persist_actor_and_kmf_status(campaign, outcome)
	var elapsed_minutes := maxi(1, int(ceil(float(outcome.get("elapsed_time", 0.0)) / 60.0)))
	_advance_clock(campaign, elapsed_minutes)
	if campaign.get("factions", {}).has("britannia"):
		campaign["factions"]["britannia"]["alert"] = clampi(int(campaign["factions"]["britannia"].get("alert", 0)) + int(consequence.get("alert_delta_candidate", 0)), 0, 100)
	var persisted_outcome := outcome.duplicate(true)
	persisted_outcome["applied_items"] = applied_items
	persisted_outcome["abandoned_items"] = abandoned_items
	persisted_outcome["unrecovered_intel"] = [] if success else (outcome.get("intel", []) as Array).duplicate(true)
	persisted_outcome["unrecovered_rescues"] = [] if success else (outcome.get("rescued_civilians", []) as Array).duplicate(true)
	persisted_outcome["elapsed_minutes"] = elapsed_minutes
	persisted_outcome["adapter_version"] = 2
	var final_state := "returned" if success else "failed"
	if not ExpeditionSystem.transition(campaign, final_state, {"outcome": persisted_outcome}):
		return {"ok": false, "reason": "return_transition_failed"}
	return {"ok": true, "state": final_state, "outcome": persisted_outcome, "campaign": campaign.duplicate(true)}

static func get_active_launch_snapshot(campaign: Dictionary) -> Dictionary:
	var expedition: Dictionary = campaign.get("expedition", {})
	if str(expedition.get("region_id", "")) != SITE_ID or str(expedition.get("state", "")) not in ["deployed", "exploring", "extracting"]:
		return {"ok": false, "reason": "no_matching_expedition"}
	return _build_launch_snapshot(campaign, int(expedition.get("seed", -1)))

static func _build_launch_snapshot(campaign: Dictionary, seed: int) -> Dictionary:
	var expedition: Dictionary = campaign.get("expedition", {})
	var party_ids: Array = expedition.get("party_ids", []).duplicate(true)
	var companions: Dictionary = {}
	for actor_id in party_ids:
		var cid := str(actor_id)
		if campaign.get("companions", {}).has(cid):
			companions[cid] = campaign["companions"][cid].duplicate(true)
	var base: Dictionary = campaign.get("base", {})
	return {"ok": true, "site_id": SITE_ID, "region_id": SITE_ID, "seed": seed, "party_ids": party_ids, "companions": companions, "loadout_ids": expedition.get("loadout_ids", []).duplicate(true), "kmf_ids": expedition.get("selected_kmf_ids", base.get("kmf_ids", [])).duplicate(true), "human_status": base.get("human_status", {}).duplicate(true), "kmf_status": base.get("kmf_status", {}).duplicate(true), "campaign_clock": expedition.get("started_at", {}).duplicate(true), "preparation":expedition.get("preparation",{}).duplicate(true)}

static func _persist_actor_and_kmf_status(campaign: Dictionary, outcome: Dictionary) -> void:
	var base: Dictionary = campaign.get("base", {})
	var human_status: Dictionary = base.get("human_status", {})
	var injured_ids: Array = base.get("injured_ids", [])
	var injured: Array = outcome.get("injured", [])
	var incapacitated: Array = outcome.get("incapacitated", [])
	var human_parts: Dictionary = outcome.get("human_parts", {})
	for actor_id in human_parts.keys():
		var cid := str(actor_id)
		var parts: Dictionary = human_parts[actor_id].duplicate(true)
		var is_injured := cid in injured or cid in incapacitated
		var is_incapacitated := cid in incapacitated
		human_status[cid] = {"parts": parts, "injured": is_injured, "incapacitated": is_incapacitated, "last_site": SITE_ID}
		if is_injured and cid not in injured_ids: injured_ids.append(cid)
		if is_injured and campaign.get("companions", {}).has(cid):
			var started: Dictionary = campaign.get("expedition", {}).get("started_at", {})
			var injury_id := "%s:%d:%d" % [SITE_ID, int(started.get("day", 0)), int(started.get("minute_of_day", 0))]
			var already_recorded := false
			for existing in campaign["companions"][cid].get("injuries", []):
				if str(existing.get("id", "")) == injury_id: already_recorded = true
			if not already_recorded:
				var damaged_parts: Array[String] = []
				for part_id in parts.keys():
					var part: Dictionary = parts[part_id]
					if float(part.get("hp", 0.0)) < float(part.get("max_hp", 0.0)): damaged_parts.append(str(part_id))
				CompanionSystem.add_injury(campaign, cid, {"id": injury_id, "source": SITE_ID, "parts": damaged_parts, "incapacitated": is_incapacitated})
	base["human_status"] = human_status
	base["injured_ids"] = injured_ids

	var kmf_status: Dictionary = base.get("kmf_status", {})
	var kmf_id := str(outcome.get("kmf_campaign_id", ""))
	if kmf_id.is_empty() and not (base.get("kmf_ids", []) as Array).is_empty():
		kmf_id = str((base.get("kmf_ids", []) as Array)[0])
	if not kmf_id.is_empty():
		kmf_status[kmf_id] = {"parts": outcome.get("kmf_parts", {}).duplicate(true), "returned": bool(outcome.get("kmf_returned", false)), "abandoned": bool(outcome.get("kmf_abandoned", false)), "last_site": SITE_ID}
		if bool(outcome.get("kmf_abandoned", false)):
			var kmf_ids: Array = base.get("kmf_ids", [])
			kmf_ids.erase(kmf_id)
			base["kmf_ids"] = kmf_ids
	base["kmf_status"] = kmf_status
	campaign["base"] = base

static func _advance_clock(campaign: Dictionary, minutes: int) -> void:
	var clock: Dictionary = campaign.get("clock", {"day": 1, "minute_of_day": 480})
	var total := (int(clock.get("day", 1)) - 1) * 1440 + int(clock.get("minute_of_day", 480)) + minutes
	clock["day"] = int(total / 1440) + 1
	clock["minute_of_day"] = total % 1440
	campaign["clock"] = clock
