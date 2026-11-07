extends "res://lab/CombatMode.gd"
## TacticalPauseCombatMode - 方式 B: リアルタイム + 戦術ポーズ (Phase 0.5 Block 3)
##
## 特徴:
##   - 通常は方式 A と同じ連続シミュレーション。
##   - P キー (lab_pause) で停止し、停止中に判断・指示を出せる。
##   - 停止中もワールドは完全に凍結 (戦闘時間は進まない)。
##   - 停止中の判断は「移動指示」「狙う部位の指定」「退避指示」「射撃予約」としてキューされる。
##
## 比較軸の予想:
##   操作しやすさ (中) / 部位攻撃との相性 (高) / 仲間指示 (中) /
##   戦術の幅 (高) / 視認性 (中) / AI実装負荷 (中) / コンテンツ制作負荷 (高)
##
## 設計上の注意:
##   停止中は「時間経過を止める」だけで、判定や数値は一切変えない。
##   停止中のコマンドも CombatCore を通すので、方式 A/B/C で結果の解釈が揃う。

func get_mode_id() -> String:
	return "tactical_pause"

func get_display_name() -> String:
	return "B: リアルタイム+戦術ポーズ"

func get_description() -> String:
	return "連続シミュレーション＋Pで凍結して判断・指示。停止中は戦闘時間が進まない。"

func begin_run() -> void:
	super.begin_run()
	_planning = false

## ポーズに入る。
func enter_planning() -> bool:
	if _planning:
		return false
	_planning = true
	_planning_elapsed = 0.0
	_queued_move = Vector2.ZERO
	_queued_shot = {}
	_queued_retreat = false
	if lab != null and is_instance_valid(lab):
		if lab.has_method("on_pause_started"):
			lab.on_pause_started()
	return true

## ポーズを解除する。
func exit_planning() -> bool:
	if not _planning:
		return false
	_planning = false
	if lab != null and is_instance_valid(lab):
		if lab.has_method("on_pause_ended"):
			lab.on_pause_ended()
	return true

## ポーズ中: キューされた移動指示のみ反映する。
func get_move_direction() -> Vector2:
	if _planning:
		return _queued_move
	# A direction chosen during pause remains an actual order after resume.
	# Any live movement input immediately takes control back and clears the order.
	var live_direction: Vector2 = super.get_move_direction()
	if live_direction != Vector2.ZERO:
		_queued_move = Vector2.ZERO
		return live_direction
	return _queued_move

## 発射: ポーズ中は発射せず、再開後にキューされた弾を1発だけ返す。
func poll_shot() -> Dictionary:
	if _planning:
		return {}
	if not _queued_shot.is_empty():
		var shot: Dictionary = _queued_shot
		_queued_shot = {}
		return shot
	return _read_live_shot()

## ポーズ中のコマンド受付。
func issue_action(action: String, payload: Dictionary = {}) -> Dictionary:
	match action:
		"pause":
			if _planning:
				return {"ok": false, "reason": "already_paused"}
			enter_planning()
			_record_action(action, payload, false)
			return {"ok": true, "reason": ""}
		"resume":
			if not _planning:
				return {"ok": false, "reason": "not_paused"}
			exit_planning()
			_record_action(action, payload, false)
			return {"ok": true, "reason": ""}
		"move_order":
			_queued_move = payload.get("direction", Vector2.ZERO)
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		"target_part":
			_queued_part = str(payload.get("part_id", ""))
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		"retreat_order":
			_queued_retreat = true
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		"attack":
			# ポーズ中は発射要求をキューする (再開時に実行)。
			_queued_shot = {
				"aim_point": payload.get("aim_point", Vector2.ZERO),
				"part_id": str(payload.get("part_id", _queued_part)),
			}
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		_:
			return super.issue_action(action, payload)

func get_status_lines() -> Array:
	var lines: Array = []
	lines.append("方式: %s" % get_display_name())
	lines.append("状態: %s" % ("戦術ポーズ中 (P で再開)" if _planning else "実時間"))
	return lines
