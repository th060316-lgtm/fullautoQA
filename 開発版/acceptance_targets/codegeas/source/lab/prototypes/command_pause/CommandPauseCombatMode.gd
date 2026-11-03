extends "res://lab/CombatMode.gd"
## CommandPauseCombatMode - Prototype D
## Destination / target commands replace continuous movement and manual aiming.
## CombatCore / damage / AI numbers remain shared with the existing Lab.

func get_mode_id() -> String:
	return "command_pause"

func get_display_name() -> String:
	return "D: コマンド移動+ポーズ"

func get_description() -> String:
	return "地点と対象をクリック指定。移動経路・到達見込みを表示し、Pで停止して指示を組み直せる。"

func begin_run() -> void:
	super.begin_run()
	_planning = false
	if lab != null and is_instance_valid(lab) and lab.has_method("clear_command_destination"):
		lab.clear_command_destination()

func uses_live_movement() -> bool:
	return false

func enter_planning() -> bool:
	if _planning:
		return false
	_planning = true
	_planning_elapsed = 0.0
	if lab != null and is_instance_valid(lab) and lab.has_method("on_pause_started"):
		lab.on_pause_started()
	return true

func exit_planning() -> bool:
	if not _planning:
		return false
	_planning = false
	if lab != null and is_instance_valid(lab) and lab.has_method("on_pause_ended"):
		lab.on_pause_ended()
	return true

func get_move_direction() -> Vector2:
	if _planning or lab == null or not is_instance_valid(lab):
		return Vector2.ZERO
	if lab.has_method("get_command_move_direction"):
		return lab.get_command_move_direction()
	return Vector2.ZERO

func poll_shot() -> Dictionary:
	if _planning:
		return {}
	if not _queued_shot.is_empty():
		var shot: Dictionary = _queued_shot
		_queued_shot = {}
		return shot
	return {}

func issue_action(action: String, payload: Dictionary = {}) -> Dictionary:
	match action:
		"pause":
			if not enter_planning():
				return {"ok": false, "reason": "already_paused"}
			_record_action(action, payload, false)
			return {"ok": true, "reason": ""}
		"resume":
			if not exit_planning():
				return {"ok": false, "reason": "not_paused"}
			_record_action(action, payload, false)
			return {"ok": true, "reason": ""}
		"move_target":
			if lab == null or not lab.has_method("set_command_destination"):
				return {"ok": false, "reason": "no_command_path"}
			var result: Dictionary = lab.set_command_destination(payload.get("position", Vector2.ZERO))
			if bool(result.get("ok", false)):
				_record_action(action, payload, true)
			return result
		"attack_target":
			if not payload.has("aim_point"):
				return {"ok": false, "reason": "no_target"}
			_queued_shot = {
				"aim_point": payload.get("aim_point", Vector2.ZERO),
				"part_id": str(payload.get("part_id", _queued_part)),
			}
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		"target_part":
			_queued_part = str(payload.get("part_id", ""))
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		"retreat_order":
			_record_action(action, payload, true)
			if lab != null and lab.has_method("set_command_destination") and lab.has_method("get_extraction_point"):
				lab.set_command_destination(lab.get_extraction_point())
			return {"ok": true, "reason": ""}
		_:
			return super.issue_action(action, payload)

func get_status_lines() -> Array:
	var lines: Array = []
	lines.append("状態: %s" % ("停止中 (Pで再開)" if _planning else "実時間"))
	if lab != null and is_instance_valid(lab) and lab.has_method("get_command_status_lines"):
		lines.append_array(lab.get_command_status_lines())
	return lines
