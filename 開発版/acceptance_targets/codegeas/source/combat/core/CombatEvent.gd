extends RefCounted
## CombatEvent - 戦闘イベントの共通ペイロード (Phase 0.5 Block 4)
##
## 戦闘方式 (Full Realtime / Realtime+Tactical Pause / Lightweight WEGO) は
## 異なるが、「何が起きたか」の語彙は共通にする。
## ここを共通化することで、方式ごとのログ比較・メトリクス集計が成立する。

const KIND_SHOT: String = "shot"
const KIND_MISS: String = "miss"
const KIND_HIT: String = "hit"
const KIND_PART_HIT: String = "part_hit"
const KIND_PART_DESTROYED: String = "part_destroyed"
const KIND_INCAPACITATED: String = "incapacitated"
const KIND_DESTROYED: String = "destroyed"
const KIND_DAMAGE_TAKEN: String = "damage_taken"
const KIND_BOARD: String = "board"
const KIND_DISMOUNT: String = "dismount"
const KIND_RETREAT: String = "retreat"
const KIND_EXTRACTION: String = "extraction"
const KIND_PLAYER_DEATH: String = "player_death"
const KIND_MODE_SWITCH: String = "mode_switch"
const KIND_RESET: String = "reset"
const KIND_PLAN_START: String = "plan_start"
const KIND_PLAN_END: String = "plan_end"
const KIND_AI_TACTIC: String = "ai_tactic"

## イベント種別ごとの日本語表示 (ログ/UI 共通)
const KIND_LABELS: Dictionary = {
	"shot": "射撃",
	"miss": "MISS",
	"hit": "命中",
	"part_hit": "部位命中",
	"part_destroyed": "部位破壊",
	"incapacitated": "無力化",
	"destroyed": "撃破",
	"damage_taken": "被ダメージ",
	"board": "搭乗",
	"dismount": "降機",
	"retreat": "撤退開始",
	"extraction": "離脱成功",
	"player_death": "主人公死亡",
	"mode_switch": "方式切替",
	"reset": "リセット",
	"plan_start": "計画開始",
	"plan_end": "計画終了",
	"ai_tactic": "AI戦術",
}

## イベントを生成する。
static func make(kind: String, data: Dictionary = {}) -> Dictionary:
	var event: Dictionary = {
		"kind": kind,
		"label": str(KIND_LABELS.get(kind, kind)),
		"time": float(data.get("time", 0.0)),
		"source_id": str(data.get("source_id", "")),
		"target_id": str(data.get("target_id", "")),
		"part_id": str(data.get("part_id", "")),
		"amount": float(data.get("amount", 0.0)),
		"position": data.get("position", Vector2.ZERO),
		"mode_id": str(data.get("mode_id", "")),
		"meta": data.get("meta", {}),
	}
	return event
