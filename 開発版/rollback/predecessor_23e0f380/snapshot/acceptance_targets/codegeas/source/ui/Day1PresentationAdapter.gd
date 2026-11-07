extends Node
## Player-facing adapter. The Day1 controller and canonical GameState remain authoritative.
## New Grok state APIs can provide get_ui_snapshot(); the fallback only reads existing state.

const CASE_VIEW: Dictionary = {
	"quest_hospital_medicine": {"name": "病院医薬品輸送", "destination": "hospital"},
	"quest_evacuation_rescue": {"name": "避難民救助", "destination": "city_center"},
	"quest_supply_depot": {"name": "食料倉庫確保", "destination": "industrial_area"},
}

func get_snapshot(day1_controller: Node, map_manager: Node) -> Dictionary:
	if day1_controller and day1_controller.has_method("get_ui_snapshot"):
		var official: Variant = day1_controller.call("get_ui_snapshot")
		if official is Dictionary and not official.is_empty():
			return _normalize(official, map_manager)
	return _legacy_snapshot(day1_controller, map_manager)

func get_case_rows(day1_controller: Node) -> Array:
	if day1_controller and day1_controller.has_method("get_ui_case_rows"):
		var official: Variant = day1_controller.call("get_ui_case_rows")
		if official is Array:
			return official
	var day1: Dictionary = GameState.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	var rows: Array = []
	for case_id in day1.get("known_cases", []):
		var state: Dictionary = states.get(case_id, {})
		var view: Dictionary = CASE_VIEW.get(case_id, {"name": "未確認案件", "destination": "base"})
		rows.append({
			"name": view["name"],
			"status": _status_label(str(state.get("status", "available"))),
			"deadline": int(state.get("deadline_abs_minute", -1)),
		})
	return rows

func _legacy_snapshot(day1_controller: Node, map_manager: Node) -> Dictionary:
	var day1: Dictionary = GameState.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	var objective := str(day1.get("current_objective", "次の行動を選ぶ"))
	var destination := "base"
	if not bool(day1.get("yui_talked", false)):
		objective = "ユイと話す"
	elif not bool(day1.get("aoi_talked", false)):
		objective = "アオイから医薬品を受け取る"
	elif str(states.get("quest_evacuation_rescue", {}).get("status", "")) == "active":
		destination = "evacuation_center" if bool(day1.get("escorting_rei", false)) else "city_center"
		objective = "避難所へ救助者を送る" if destination == "evacuation_center" else "市街中心部で救助する"
	elif str(states.get("quest_hospital_medicine", {}).get("status", "")) == "active":
		destination = "hospital"
		objective = "病院へ医薬品を届ける"
	elif bool(states.get("quest_supply_depot", {}).get("known", false)) and str(states.get("quest_supply_depot", {}).get("status", "")) in ["active", "available"]:
		destination = "industrial_area"
		objective = "工業地区の食料倉庫を調べる"
	var deadline := -1
	for case_id in day1.get("known_cases", []):
		var state: Dictionary = states.get(case_id, {})
		if str(state.get("status", "")) in ["active", "available"]:
			var value := int(state.get("deadline_abs_minute", -1))
			if value >= 0 and (deadline < 0 or value < deadline):
				deadline = value
	return _normalize({"objective": objective, "destination_id": destination, "deadline": deadline}, map_manager)

func _normalize(source: Dictionary, map_manager: Node) -> Dictionary:
	var result := source.duplicate(true)
	var destination := str(result.get("destination_id", "base"))
	if not result.has("destination_position") and map_manager and map_manager.has_method("get_navigation_position"):
		result["destination_position"] = map_manager.get_navigation_position(destination)
	if not result.has("destination_name"):
		result["destination_name"] = map_manager.get_location_display_name(destination) if map_manager and map_manager.has_method("get_location_display_name") else destination
	return result

func _status_label(status: String) -> String:
	return str({"available": "対応可能", "active": "進行中", "completed": "完了", "failed": "失敗", "expired": "期限切れ"}.get(status, "確認中"))
