extends RefCounted
## LabMetrics - 戦闘方式比較用メトリクス (Phase 0.5 Block 2 / Block 3)
##
## 契約 DOCS/02_COMBAT_LAB_CONTRACT.txt が要求するログ項目をすべて保持する:
##   elapsed combat time / damage received / KMF damage / shots fired / hits /
##   enemies incapacitated-destroyed / part hits / pauses-planning phases /
##   retreat success / player death
## Block 3 の要求:
##   操作量 / 判断頻度 / 戦闘時間 / 被ダメージ / KMF損傷 / 射撃数 / 命中数 /
##   撃破数 / 撤退成否 / 主人公死亡 / pause-planning 回数
##
## 3方式で同じ集計処理を使うため、方式固有の項目は持たない。
## 方式の性質 (pause/planning) も「回数」として同じ枠で記録する。

const OUTCOME_RUNNING: String = "running"
const OUTCOME_EXTRACTED: String = "extracted"
const OUTCOME_DEAD: String = "dead"
const OUTCOME_TIMEOUT: String = "timeout"

var mode_id: String = ""
var combat_time: float = 0.0        # シミュレーション時間 (秒)
var real_time: float = 0.0          # 実時間 (秒)
var action_count: int = 0           # 操作量: 受理されたプレイヤーコマンド数
var decision_count: int = 0         # 判断回数: 戦術判断と数えるコマンド数
var shots_fired: int = 0
var hits: int = 0
var misses: int = 0
var part_hits: int = 0
var part_destroys: int = 0
var enemies_neutralized: int = 0    # 無力化 (incapacitated)
var enemies_destroyed: int = 0      # 撃破 (destroyed)
var damage_received: float = 0.0    # 被ダメージ (主人公)
var kmf_damage: float = 0.0         # KMF 損傷
var player_hp_lost: float = 0.0
var pause_count: int = 0            # pause 回数 (Tactical Pause)
var planning_count: int = 0         # planning 回数 (Tactical Pause / WEGO)
var planning_seconds: float = 0.0
var retreat_attempted: bool = false
var retreat_success: bool = false
var player_dead: bool = false
var timeout: bool = false
var outcome: String = OUTCOME_RUNNING
var foot_shots: int = 0
var kmf_shots: int = 0
var dodges: int = 0
var boards: int = 0
var dismounts: int = 0
var mode_switches: int = 0
var retreat_orders: int = 0
## AI tactical action counts (mode-agnostic). Keys are action names from TacticsInterface.
var ai_tactical_actions: Dictionary = {}
var ai_tactical_total: int = 0

func reset(p_mode_id: String = "") -> void:
	mode_id = p_mode_id
	combat_time = 0.0
	real_time = 0.0
	action_count = 0
	decision_count = 0
	shots_fired = 0
	hits = 0
	misses = 0
	part_hits = 0
	part_destroys = 0
	enemies_neutralized = 0
	enemies_destroyed = 0
	damage_received = 0.0
	kmf_damage = 0.0
	player_hp_lost = 0.0
	pause_count = 0
	planning_count = 0
	planning_seconds = 0.0
	retreat_attempted = false
	retreat_success = false
	player_dead = false
	timeout = false
	outcome = OUTCOME_RUNNING
	foot_shots = 0
	kmf_shots = 0
	dodges = 0
	boards = 0
	dismounts = 0
	mode_switches = 0
	retreat_orders = 0
	ai_tactical_actions = {}
	ai_tactical_total = 0

## 判断頻度: 戦闘 1 秒あたりの判断回数。
func get_decision_frequency() -> float:
	if combat_time <= 0.0001:
		return 0.0
	return float(decision_count) / combat_time

## 命中率
func get_hit_rate() -> float:
	if shots_fired <= 0:
		return 0.0
	return float(hits) / float(shots_fired)

## 1分あたり被ダメージ
func get_damage_per_minute() -> float:
	if combat_time <= 0.0001:
		return 0.0
	return damage_received / (combat_time / 60.0)

func to_dictionary() -> Dictionary:
	return {
		"mode_id": mode_id,
		"outcome": outcome,
		"combat_time": combat_time,
		"real_time": real_time,
		"action_count": action_count,
		"decision_count": decision_count,
		"decision_frequency": get_decision_frequency(),
		"shots_fired": shots_fired,
		"foot_shots": foot_shots,
		"kmf_shots": kmf_shots,
		"hits": hits,
		"misses": misses,
		"hit_rate": get_hit_rate(),
		"part_hits": part_hits,
		"part_destroys": part_destroys,
		"enemies_neutralized": enemies_neutralized,
		"enemies_destroyed": enemies_destroyed,
		"damage_received": damage_received,
		"damage_per_minute": get_damage_per_minute(),
		"kmf_damage": kmf_damage,
		"player_hp_lost": player_hp_lost,
		"pause_count": pause_count,
		"planning_count": planning_count,
		"planning_seconds": planning_seconds,
		"retreat_attempted": retreat_attempted,
		"retreat_success": retreat_success,
		"player_dead": player_dead,
		"timeout": timeout,
		"dodges": dodges,
		"boards": boards,
		"dismounts": dismounts,
		"mode_switches": mode_switches,
		"retreat_orders": retreat_orders,
		"ai_tactical_actions": ai_tactical_actions.duplicate(),
		"ai_tactical_total": ai_tactical_total,
	}

## 表比較用 (1行) 。
func get_comparison_row() -> Dictionary:
	return {
		"方式": mode_id,
		"結果": outcome,
		"戦闘時間": snappedf(combat_time, 0.1),
		"操作量": action_count,
		"判断回数": decision_count,
		"判断頻度": snappedf(get_decision_frequency(), 0.01),
		"被ダメージ": snappedf(damage_received, 0.1),
		"KMF損傷": snappedf(kmf_damage, 0.1),
		"射撃数": shots_fired,
		"命中数": hits,
		"撃破数": enemies_destroyed,
		"無力化": enemies_neutralized,
		"撤退成否": "成功" if retreat_success else ("失敗" if retreat_attempted else "-"),
		"主人公死亡": "あり" if player_dead else "なし",
		"pause/planning": pause_count + planning_count,
		"AI戦術回数": ai_tactical_total,
	}
