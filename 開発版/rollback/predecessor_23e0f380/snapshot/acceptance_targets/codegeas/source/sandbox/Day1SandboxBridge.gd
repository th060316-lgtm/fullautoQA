extends RefCounted
## Adapter only: preserves Day1 and converts its terminal result into campaign inputs.

const Defaults = preload("res://sandbox/FoundationDefaults.gd")

static func can_transition(day1: Dictionary) -> bool:
	var result := str(day1.get("end_result", ""))
	if result not in ["全成功", "部分成功", "全失敗"]:
		return false
	var states: Dictionary = day1.get("case_states", {})
	if states.is_empty():
		return false
	for state in states.values():
		if str(state.get("status", "")) not in ["completed", "failed", "expired"]:
			return false
	var summary: Dictionary = day1.get("summary", {})
	if summary.has("result") and str(summary.get("result", "")) != result:
		return false
	return true

static func build_campaign(day1: Dictionary, snapshot: Dictionary) -> Dictionary:
	var campaign := Defaults.create_campaign()
	campaign["mode"] = "sandbox"
	campaign["clock"] = {"day": maxi(2, int(snapshot.get("meta", {}).get("day", 1))), "minute_of_day": 8 * 60}
	campaign["source"] = {
		"day1_completed": true,
		"day1_result": day1.get("end_result", ""),
		"day1_summary": day1.get("summary", {}).duplicate(true),
		"world_changes": day1.get("world_changes", {}).duplicate(true),
		"bridge_version": 1,
	}
	var player: Dictionary = snapshot.get("player", {})
	campaign["base"]["resources"]["food"] = maxf(0.0, float(player.get("food", 0.0)))
	var kmf: Dictionary = snapshot.get("kmf", {})
	if bool(kmf.get("owned", false)):
		campaign["base"]["kmf_ids"] = ["day1_owned_kmf"]
	var heroine: Dictionary = snapshot.get("heroine", {})
	if bool(heroine.get("alive", false)) and bool(heroine.get("present", false)):
		campaign["companions"][str(heroine.get("id", "day1_companion"))] = {
			"id": str(heroine.get("id", "day1_companion")), "display_name": str(heroine.get("name", "")),
			"role": "survivor", "alive": true, "injuries": [], "traits": [],
			"skills": {"combat": 0, "medical": 0, "maintenance": 0, "kmf_aptitude": 0},
			"relationships": {"player": {"affection": int(heroine.get("affection", 0)), "trust": int(heroine.get("trust", 0)), "fear": int(heroine.get("fear", 0))}},
			"known_information": [],
		}
		campaign["base"]["companion_ids"].append(str(heroine.get("id", "day1_companion")))
	return campaign
