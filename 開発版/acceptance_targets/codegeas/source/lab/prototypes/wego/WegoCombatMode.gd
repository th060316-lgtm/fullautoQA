extends "res://lab/CombatMode.gd"
## WegoCombatMode - 方式 C: 軽量 WEGO (Phase 0.5 Block 3)
##
## 特徴:
##   - ワールドは「ターン」で進む。各ターンは TURN_SIM_SECONDS 秒分のシミュレーション。
##   - プレイヤーは planning フェーズ (ターン開始時) にだけコマンドを出せる。
##   - 1ターンあたりのコマンド上限 (MAX_ACTIONS_PER_TURN) があるため、
##     方式A/B と比較して「判断回数/戦闘時間」が構造的に少なくなる。
##   - 移動は方式A/B と同じ速度で連続的に進む (解決フェーズ中に解決)。
##     つまり移動性能は変えず、「判断の粒度」だけを変える。
##
## 比較軸の予想:
##   操作しやすさ (低〜中) / 部位攻撃との相性 (高) / 仲間指示 (高) /
##   戦術の幅 (高) / 視認性 (中) / AI実装負荷 (中〜高) / コンテンツ制作負荷 (中)
##
## EXPERIMENTAL: TURN_SIM_SECONDS / MAX_ACTIONS_PER_TURN は方式固有の変数。
## ダメージ数値・敵性能は他方式と同一 (rebalance しない)。

const TURN_SIM_SECONDS: float = 1.0
const MAX_ACTIONS_PER_TURN: int = 2

var _turn_remaining: float = 0.0
var _actions_this_turn: int = 0
var _shot_consumed: bool = true
var _plan_retreat: bool = false

func get_mode_id() -> String:
	return "wego"

func get_display_name() -> String:
	return "C: 軽量WEGO"

func get_description() -> String:
	return "1秒=1ターン。planning フェーズにだけ判断でき、1ターン%dコマンドまで。" % MAX_ACTIONS_PER_TURN

func begin_run() -> void:
	super.begin_run()
	_turn_remaining = 0.0
	_actions_this_turn = 0
	_shot_consumed = true
	_plan_retreat = false
	# ラン開始時は planning から入る。
	enter_planning()

## ターン開始: planning フェーズに入る。
func enter_planning() -> bool:
	if _planning:
		return false
	_planning = true
	_planning_elapsed = 0.0
	_actions_this_turn = 0
	_shot_consumed = true
	_queued_move = Vector2.ZERO
	_queued_shot = {}
	_plan_retreat = false
	if lab != null and is_instance_valid(lab):
		if lab.has_method("on_planning_started"):
			lab.on_planning_started()
	return true

## ターン終了: 解決フェーズへ。
func exit_planning() -> bool:
	if not _planning:
		return false
	_planning = false
	_turn_remaining = TURN_SIM_SECONDS
	if lab != null and is_instance_valid(lab):
		if lab.has_method("on_planning_ended"):
			lab.on_planning_ended()
	return true

## 解決フェーズでは turn budget ぶんだけシミュレーションを進める。
func get_sim_delta(delta: float) -> float:
	if _planning:
		return 0.0
	return minf(delta, maxf(_turn_remaining, 0.0))

func tick(delta: float) -> void:
	if lab == null or not is_instance_valid(lab):
		return
	if not lab.is_run_active():
		return
	if _planning:
		_tick_planning(delta)
		lab.on_planning_tick(delta)
		return
	var consume: float = minf(delta, maxf(_turn_remaining, 0.0))
	_turn_remaining -= consume
	if consume > 0.0:
		lab.sim_advance(consume)
	if _turn_remaining <= 0.0001:
		# ターン終了 → 次の planning へ (自動)
		enter_planning()

## WEGO は planning 中の入力だけを反映する (生入力は使わない)。
func uses_live_movement() -> bool:
	return false

## planning 中はキューされた移動だけ反映する。
func get_move_direction() -> Vector2:
	if _planning:
		return _queued_move
	return _queued_move

## 発射: planning 中は不可。解決フェーズ開始時にキューされた1発だけ返す。
func poll_shot() -> Dictionary:
	if _planning or _shot_consumed:
		return {}
	_shot_consumed = true
	return _queued_shot

## コマンド受付: planning 中のみ、上限を超えると拒否される。
func issue_action(action: String, payload: Dictionary = {}) -> Dictionary:
	if not _planning:
		return {"ok": false, "reason": "not_planning"}
	if action == "plan_confirm":
		exit_planning()
		_record_action(action, payload, false)
		return {"ok": true, "reason": ""}
	if _actions_this_turn >= get_action_budget():
		return {"ok": false, "reason": "action_budget_exceeded"}
	match action:
		"move_order":
			_queued_move = payload.get("direction", Vector2.ZERO)
		"target_part":
			_queued_part = str(payload.get("part_id", ""))
		"retreat_order":
			_plan_retreat = true
		"attack":
			_queued_shot = {
				"aim_point": payload.get("aim_point", Vector2.ZERO),
				"part_id": str(payload.get("part_id", _queued_part)),
			}
			_shot_consumed = false
		"dodge":
			pass
		_:
			return {"ok": false, "reason": "unknown_action"}
	_actions_this_turn += 1
	_record_action(action, payload, true)
	return {"ok": true, "reason": ""}

func get_action_budget() -> int:
	return MAX_ACTIONS_PER_TURN

func get_status_lines() -> Array:
	var lines: Array = []
	lines.append("方式: %s" % get_display_name())
	lines.append("状態: %s" % ("計画中 (Enter で解決フェーズへ)" if _planning else "解決フェーズ %.2fs" % maxf(_turn_remaining, 0.0)))
	lines.append("残コマンド: %d / %d" % [maxi(0, get_action_budget() - _actions_this_turn), get_action_budget()])
	return lines
