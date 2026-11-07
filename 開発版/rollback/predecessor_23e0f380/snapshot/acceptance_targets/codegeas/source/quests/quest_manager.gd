extends "res://quests/QuestManagerLegacy.gd"
## Day1 uses Day1Controller as the canonical source.
## The legacy quest system remains available for later-day/general quests.

const DAY1_CASE_IDS: Array = [
	"quest_hospital_medicine",
	"quest_evacuation_rescue",
	"quest_supply_depot",
]

func _day1_controller() -> Node:
	var root := get_tree().root if get_tree() else null
	return root.find_child("Day1Controller", true, false) if root else null

func _day1_canonical_active() -> bool:
	var d1 := _day1_controller()
	# Day1 case IDs remain canonical after Day1 ends so legacy schedules can never
	# resurrect an already resolved story case on later days or old saves.
	return _gs != null and d1 != null and d1.has_method("is_initialized") and d1.is_initialized()

func _without_day1(rows: Array) -> Array:
	if not _day1_canonical_active():
		return rows
	var out: Array = []
	for row in rows:
		if str(row.get("id", "")) not in DAY1_CASE_IDS:
			out.append(row)
	return out

func get_available_quests() -> Array:
	return _without_day1(super.get_available_quests())

func get_active_quests() -> Array:
	return _without_day1(super.get_active_quests())

func get_completed_quests() -> Array:
	return _without_day1(super.get_completed_quests())

func get_quest(quest_id: String) -> Dictionary:
	if quest_id in DAY1_CASE_IDS and _day1_canonical_active():
		var d1 := _day1_controller()
		var state: Dictionary = d1.get_case_state(quest_id)
		if state.is_empty():
			return {}
		var legacy: Dictionary = super.get_quest(quest_id)
		var status_map: Dictionary = {
			"available": QuestStatus.AVAILABLE,
			"active": QuestStatus.ACTIVE,
			"completed": QuestStatus.COMPLETED,
			"failed": QuestStatus.FAILED,
			"expired": QuestStatus.FAILED,
		}
		legacy["id"] = quest_id
		legacy["status"] = status_map.get(str(state.get("status", "available")), QuestStatus.AVAILABLE)
		legacy["canonical_day1"] = true
		legacy["stage"] = str(state.get("stage", ""))
		legacy["deadline_abs_minute"] = int(state.get("deadline_abs_minute", -1))
		return legacy
	return super.get_quest(quest_id)

func accept_quest(quest_id: String) -> bool:
	if quest_id in DAY1_CASE_IDS and _day1_canonical_active():
		var d1 := _day1_controller()
		var state: Dictionary = d1.get_case_state(quest_id)
		if str(state.get("status", "")) == "active":
			return true
		return bool(d1.accept_case(quest_id))
	return super.accept_quest(quest_id)
