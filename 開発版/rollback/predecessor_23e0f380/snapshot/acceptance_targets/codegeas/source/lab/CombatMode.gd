extends RefCounted
## CombatMode - 戦闘方式の境界 (Phase 0.5 Block 3)
##
## 3方式 (Full Realtime / Realtime+Tactical Pause / Lightweight WEGO) を
## 「別ゲーム」ではなく「同一 fixture + 同一 Combat Core の時間制御の違い」にするため、
## 方式固有の責務をこの基底クラスに集約する。
##
## 方式が持てるもの:
##   - シミュレーションを進めるタイミング (連続 / 一時停止 / ターン)
##   - プレイヤー判断の粒度 (連続 / 停止中に判断 / ターンごとに判断)
##   - planning 中のコマンド受付
##
## 方式が持ってはならないもの:
##   - ダメージ計算 / 部位判定 / 命中判定 (すべて CombatCore の責務)
##   - 敵 AI の判断内容 (BaselineTactics の責務)
##   - 方式ごとの数値調整 (rebalance 禁止)
##
## 抽象メソッド相当 (サブクラスで実装):
##   get_mode_id() / get_display_name() / get_description()
##   can_simulate() / enter_planning() / exit_planning()
##   get_move_direction() / poll_shot()

var lab: Node = null
var _planning: bool = false
var _planning_elapsed: float = 0.0
var _queued_move: Vector2 = Vector2.ZERO
var _queued_shot: Dictionary = {}
var _queued_retreat: bool = false
var _queued_part: String = ""

func configure(lab_node: Node) -> void:
	lab = lab_node

func get_mode_id() -> String:
	return "base"

func get_display_name() -> String:
	return "ベース"

func get_description() -> String:
	return ""

## ラン開始時の初期化。
func begin_run() -> void:
	_planning = false
	_planning_elapsed = 0.0
	_queued_move = Vector2.ZERO
	_queued_shot = {}
	_queued_retreat = false
	_queued_part = ""

func end_run() -> void:
	pass

## 毎フレームの入口。方式ごとに「どれだけシミュレーションを進めるか」を決める。
func tick(delta: float) -> void:
	if lab == null or not is_instance_valid(lab):
		return
	if not lab.is_run_active():
		return
	if can_simulate():
		var sim_delta: float = get_sim_delta(delta)
		if sim_delta > 0.0:
			lab.sim_advance(sim_delta)
		else:
			lab.on_planning_tick(delta)
	else:
		lab.on_planning_tick(delta)

## 1フレームで進めるシミュレーション時間 (既定は連続)。
func get_sim_delta(delta: float) -> float:
	return delta

## シミュレーションを進めてよいか (planning 中は false)。
func can_simulate() -> bool:
	return not _planning

func is_planning() -> bool:
	return _planning

## planning へ入る。不可な方式は false を返す。
func enter_planning() -> bool:
	return false

## planning を終える。
func exit_planning() -> bool:
	return false

## 現在の移動方向。
func get_move_direction() -> Vector2:
	if lab == null or not is_instance_valid(lab):
		return Vector2.ZERO
	return lab.get_input_direction()

## 今この瞬間に発射すべき弾があるか (空辞書 = 発射なし)。
## 方式A: 生の入力をそのまま読む。
## 方式B: ポーズ中は何も発射せず、再開後にキューされた弾を1発だけ返す。
## 方式C: ターン開始時にキューされた弾を1発だけ返す (解決フェーズ中のみ)。
func poll_shot() -> Dictionary:
	if lab == null or not is_instance_valid(lab):
		return {}
	if not can_simulate():
		return {}
	# キューされた発射 (スクリプト / 戦術ポーズ) を優先する
	if not _queued_shot.is_empty():
		var queued: Dictionary = _queued_shot
		_queued_shot = {}
		return queued
	return _read_live_shot()

## プレイヤーコマンドの受付。方式ごとに異なる (予算・planning 制約)。
## 戻り値: { "ok": bool, "reason": String }
func issue_action(action: String, payload: Dictionary = {}) -> Dictionary:
	if lab == null or not is_instance_valid(lab):
		return {"ok": false, "reason": "no_lab"}
	match action:
		"pause":
			if not enter_planning():
				return {"ok": false, "reason": "pause_not_supported"}
			_record_action(action, payload, false)
			return {"ok": true, "reason": ""}
		"resume":
			if not exit_planning():
				return {"ok": false, "reason": "not_planning"}
			_record_action(action, payload, false)
			return {"ok": true, "reason": ""}
		"plan_confirm":
			if not exit_planning():
				return {"ok": false, "reason": "plan_not_supported"}
			_record_action(action, payload, false)
			return {"ok": true, "reason": ""}
		"dodge":
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		"retreat_order":
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		"attack":
			_queued_shot = {
				"aim_point": payload.get("aim_point", Vector2.ZERO),
				"part_id": str(payload.get("part_id", _queued_part)),
			}
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		"move_order":
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		"target_part":
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}
		_:
			_record_action(action, payload, true)
			return {"ok": true, "reason": ""}

## 方式ごとの表示行 (Lab HUD 用)。
func get_status_lines() -> Array:
	var lines: Array = []
	lines.append("方式: %s" % get_display_name())
	lines.append("状態: %s" % ("計画中" if _planning else "実時間"))
	return lines

## 生入力の移動をそのまま使う方式か (WEGO はキューされた移動を使う)。
func uses_live_movement() -> bool:
	return true

## 1ターン/1回の判断で受け付けるコマンド上限 (-1 = 無制限)。
func get_action_budget() -> int:
	return -1

## 現在の planning 経過時間。
func get_planning_elapsed() -> float:
	return _planning_elapsed

## 共通: 生入力からの発射要求を読む。
func _read_live_shot() -> Dictionary:
	if lab == null or not is_instance_valid(lab):
		return {}
	if not lab.has_method("read_fire_input"):
		return {}
	var fired: Variant = lab.call("read_fire_input")
	if fired is Dictionary and not (fired as Dictionary).is_empty():
		return fired
	return {}

## 共通: planning 時間の集計。
func _tick_planning(delta: float) -> void:
	_planning_elapsed += delta
	if lab != null and is_instance_valid(lab) and lab.has_method("add_planning_time"):
		lab.add_planning_time(delta)

## 共通: コマンド受理の記録。
func _record_action(action: String, payload: Dictionary, is_decision: bool) -> void:
	if lab != null and is_instance_valid(lab) and lab.has_method("record_player_action"):
		lab.record_player_action(action, payload, is_decision)
