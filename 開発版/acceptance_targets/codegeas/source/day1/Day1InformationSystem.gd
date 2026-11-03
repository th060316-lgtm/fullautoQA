extends "res://day1/Day1InformationSystemLegacy.gd"
## Day1 case rows and travel estimates are read from the canonical Day1Controller.

func get_known_case_overviews() -> Array:
	var d1 := _find_day1_controller()
	if d1 and d1.has_method("get_known_case_overviews"):
		return d1.get_known_case_overviews()
	return super.get_known_case_overviews()

func _get_travel_estimate(from: String, to: String, mode: String) -> Dictionary:
	if from == to:
		return {
			"from": from,
			"to": to,
			"mode": mode,
			"estimated_minutes": 0,
			"foot_minutes": 0,
			"kmf_minutes": 0,
			"is_estimate": true,
			"warning": "現在地です。",
		}
	return super._get_travel_estimate(from, to, mode)
