extends "res://lab/CombatMode.gd"
## DecisionPointCombatMode - Prototype E
## Continuous micro-input is replaced by explicit scene decisions.
## Each confirmation advances time/state through the Lab's deterministic resolver.

var _selected_id: String = ""

func get_mode_id() -> String:
	return "decision_point"

func get_display_name() -> String:
	return "E: 圧縮時間・判断点"

func get_description() -> String:
	return "地図上の判断点を選び、時間・危険・資源・結果を確認してEnterで確定する。"

func begin_run() -> void:
	super.begin_run()
	_planning = true
	_selected_id = ""
	if lab != null and is_instance_valid(lab) and lab.has_method("on_planning_started"):
		lab.on_planning_started()

func tick(delta: float) -> void:
	if lab == null or not is_instance_valid(lab) or not lab.is_run_active():
		return
	_tick_planning(delta)
	lab.on_planning_tick(delta)

func can_simulate() -> bool:
	return false

func uses_live_movement() -> bool:
	return false

func get_move_direction() -> Vector2:
	return Vector2.ZERO

func poll_shot() -> Dictionary:
	return {}

func issue_action(action: String, payload: Dictionary = {}) -> Dictionary:
	match action:
		"decision_select":
			var node_id: String = str(payload.get("node_id", ""))
			if node_id.is_empty() or lab == null or not lab.has_method("select_decision_node"):
				return {"ok": false, "reason": "invalid_decision"}
			var result: Dictionary = lab.select_decision_node(node_id)
			if bool(result.get("ok", false)):
				_selected_id = node_id
				_record_action(action, payload, true)
			return result
		"plan_confirm":
			if _selected_id.is_empty():
				return {"ok": false, "reason": "no_decision_selected"}
			if lab == null or not lab.has_method("resolve_decision_node"):
				return {"ok": false, "reason": "no_decision_resolver"}
			var result: Dictionary = lab.resolve_decision_node(_selected_id)
			if bool(result.get("ok", false)):
				_record_action(action, {"node_id": _selected_id}, true)
				_selected_id = ""
			return result
		"retreat_order":
			if lab == null or not lab.has_method("select_decision_node"):
				return {"ok": false, "reason": "no_decision_resolver"}
			var pick: Dictionary = lab.select_decision_node("extract")
			if not bool(pick.get("ok", false)):
				return pick
			_selected_id = "extract"
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		_:
			return {"ok": false, "reason": "action_not_used_in_decision_mode"}

func get_status_lines() -> Array:
	var lines: Array = ["状態: 判断待ち (判断点をクリック → Enterで確定)"]
	if lab != null and is_instance_valid(lab) and lab.has_method("get_decision_status_lines"):
		lines.append_array(lab.get_decision_status_lines())
	return lines
