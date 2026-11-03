extends "res://combat/core/TacticsInterface.gd"
## BaselineTactics - 既定の AI 実装 (Phase 0.5 Block 4)
##
## 3方式 (RT / Paused / WEGO) で同一の AI を使うためにこのファイルへ固定する。
## 方式差分は「AI の中味」ではなく「AI を呼ぶ頻度と時間」にあるべき。
##
## 行動:
##   hold      - 索敵範囲外 / 武器使用不可
##   approach  - 射程外。距離を詰める
##   engage    - 射程内。射撃
##   retreat   - 深刻損傷時に後退
##   flank     - 近接時、側面へ回り込む
##   seek_cover- 被弾後、遮蔽へ退避

const CombatBalance = preload("res://combat/core/CombatBalance.gd")

var _last_action: String = "hold"
var _flank_sign: float = 1.0
var _retreat_timer: float = 0.0

func reset(context: Dictionary = {}) -> void:
	_last_action = "hold"
	_flank_sign = 1.0 if int(context.get("entity_index", 0)) % 2 == 0 else -1.0
	_retreat_timer = 0.0

func on_event(event: Dictionary) -> void:
	# 部位破壊を受けたら、その部位に応じて戦術を変える (最小実装)。
	var kind: String = str(event.get("kind", ""))
	if kind == "part_destroyed":
		var part_id: String = str(event.get("part_id", ""))
		if part_id == "left_leg" or part_id == "right_leg":
			_retreat_timer = 2.0
		elif part_id == "left_arm" or part_id == "right_arm" or part_id == "weapon":
			_retreat_timer = maxf(_retreat_timer, 1.0)

func evaluate(context: Dictionary) -> Dictionary:
	var distance: float = float(context.get("distance", 9999.0))
	var desired_range: float = float(context.get("desired_range", 160.0))
	var detection_range: float = float(context.get("detection_range", 220.0))
	var effects: Dictionary = context.get("effects", {})
	var weapon_ready: bool = bool(context.get("weapon_ready", true))
	var hp_ratio: float = float(context.get("hp_ratio", 1.0))
	var self_position: Vector2 = context.get("self_position", Vector2.ZERO)
	var player_position: Vector2 = context.get("player_position", Vector2.ZERO)

	if _retreat_timer > 0.0:
		_retreat_timer = maxf(0.0, _retreat_timer - float(context.get("delta", 0.0)))

	var to_player: Vector2 = player_position - self_position
	var dir: Vector2 = to_player.normalized() if to_player.length() > 0.001 else Vector2.RIGHT

	# 脚を破壊された状態では移動できない。
	if bool(effects.get("immobilized", false)):
		_last_action = ACTION_HOLD_FIRE
		return _decision(ACTION_HOLD_FIRE, "immobilized", weapon_ready and distance <= desired_range, dir)

	if _retreat_timer > 0.0 or hp_ratio < 0.25:
		# Prefer seek_cover when cover is available and not fully immobilized;
		# otherwise pure retreat (disengage).
		var cover_available: bool = bool(context.get("cover_available", false))
		if cover_available and not bool(effects.get("immobilized", false)) and hp_ratio >= 0.15:
			_last_action = ACTION_SEEK_COVER
			# Move perpendicular + slightly away to seek cover rather than pure backpedal.
			var side := Vector2(-dir.y, dir.x) * _flank_sign
			var cover_dir: Vector2 = (-dir * 0.55 + side * 0.45).normalized()
			return _decision(ACTION_SEEK_COVER, "damaged_seek_cover", false, cover_dir)
		_last_action = ACTION_RETREAT
		return _decision(ACTION_RETREAT, "damaged", false, -dir)

	if distance > detection_range:
		_last_action = ACTION_HOLD
		return _decision(ACTION_HOLD, "out_of_detection", false, dir)

	if distance > desired_range * 1.25:
		_last_action = ACTION_APPROACH
		return _decision(ACTION_APPROACH, "too_far", false, dir)

	if distance < desired_range * 0.55:
		# 近すぎる: 側面へ
		var side := Vector2(-dir.y, dir.x) * _flank_sign
		_last_action = ACTION_FLANK
		return _decision(ACTION_FLANK, "too_close", false, side)

	_last_action = ACTION_ENGAGE
	var aim_part: String = _choose_aim_part(context)
	return _decision(ACTION_ENGAGE, "in_range", weapon_ready, dir, aim_part)

func _decision(action: String, reason: String, fire: bool, dir: Vector2, aim_part: String = "") -> Dictionary:
	return {
		"action": action,
		"aim_part": aim_part,
		"reason": reason,
		"fire": fire,
		"direction": dir,
	}

func _choose_aim_part(context: Dictionary) -> String:
	# 敵KMF への射撃はコックピットを優先する (鹵獲可能性が高いため)。
	var kind: String = str(context.get("target_kind", "human"))
	if kind == "kmf":
		return "cockpit"
	return "torso"

func get_debug_state() -> Dictionary:
	return {"last_action": _last_action, "retreat_timer": _retreat_timer, "flank_sign": _flank_sign}
