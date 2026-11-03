extends RefCounted
## TacticsInterface - AI / 戦術 の境界 (Phase 0.5 Block 4)
##
## 開発計画 3.3:
##   「敵AIも現在の単純追尾から、将来的には、距離維持 / 射程管理 / 遮蔽物利用 /
##     側面移動 / 撤退 / 部位損傷への対応 / 武器特性別行動 へ拡張する。」
##
## ここでは「判断の語彙」だけを固定する。
## 戦闘方式 (RT / Paused / WEGO) はこの境界を固定しない。
## 方式が変わっても AI は同じ入力を守り、同じ出力を返す。
## 実装例は game/combat/core/BaselineTactics.gd。

const ACTION_HOLD: String = "hold"
const ACTION_APPROACH: String = "approach"
const ACTION_ENGAGE: String = "engage"
const ACTION_RETREAT: String = "retreat"
const ACTION_FLANK: String = "flank"
const ACTION_SEEK_COVER: String = "seek_cover"
const ACTION_HOLD_FIRE: String = "hold_fire"

## 意思決定。
## context のキー:
##   self_position, player_position, distance, desired_range, detection_range,
##   weapon_ready, effects (PartEffects.evaluate 結果), hp_ratio, cover_available,
##   allies_alive, mode_id
## 戻り値:
##   { "action": String, "aim_part": String, "reason": String, "fire": bool }
func evaluate(context: Dictionary) -> Dictionary:
	return {
		"action": ACTION_HOLD,
		"aim_part": "",
		"reason": "no_context",
		"fire": false,
	}

## 戦闘イベント通知 (戦術の学習・反応用)。
func on_event(event: Dictionary) -> void:
	pass

## ラン開始時のリセット。
func reset(context: Dictionary = {}) -> void:
	pass

## 現在の内部状態 (デバッグ用)。
func get_debug_state() -> Dictionary:
	return {}
