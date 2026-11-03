extends RefCounted

const TRANSITIONS: Dictionary = {
	"idle": ["preparing"],
	"preparing": ["deployed", "idle"],
	"deployed": ["exploring", "extracting", "failed"],
	"exploring": ["extracting", "failed"],
	"extracting": ["returned", "failed"],
	"returned": ["idle"],
	"failed": ["idle"],
}

static func begin_preparation(campaign: Dictionary, region_id: String, party_ids: Array, loadout_ids: Array) -> bool:
	if not campaign.get("regions", {}).has(region_id) or bool(campaign["regions"][region_id].get("blockaded", false)):
		return false
	if not transition(campaign, "preparing"):
		return false
	var expedition: Dictionary = campaign["expedition"]
	expedition["region_id"] = region_id
	expedition["party_ids"] = party_ids.duplicate(true)
	expedition["loadout_ids"] = loadout_ids.duplicate(true)
	expedition["outcome"] = {}
	campaign["expedition"] = expedition
	return true

static func transition(campaign: Dictionary, next_state: String, payload: Dictionary = {}) -> bool:
	var expedition: Dictionary = campaign.get("expedition", {})
	var current := str(expedition.get("state", "idle"))
	if next_state not in TRANSITIONS.get(current, []):
		return false
	expedition["state"] = next_state
	for key in payload.keys():
		expedition[key] = payload[key]
	if next_state == "idle":
		expedition = {"state": "idle", "region_id": "", "party_ids": [], "loadout_ids": [], "started_at": {}, "outcome": {}}
	campaign["expedition"] = expedition
	return true
