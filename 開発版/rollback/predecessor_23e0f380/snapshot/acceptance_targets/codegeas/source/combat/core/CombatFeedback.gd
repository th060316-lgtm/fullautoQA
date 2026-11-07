extends RefCounted
## CombatFeedback - 戦闘フィードバックの語彙 (Phase 0.5 Block 4)
##
## 開発計画 3.3:
##   「被弾時には、Damage方向 / 攻撃元 / Hit reaction / Muzzle flash / Impact /
##     Armor hit / Part hit / 撃破 / 無力化 などを明確にする。
##    現在の『HP数値だけが下がる』状態から、何が起きたかを視覚的に理解できる状態へ」
##
## here は Core が「何が起きたか」を構造化して渡す部分だけを担う。
## 描画 (CanvasItem / 3D) は presentation 側の責務で、Core は UI 依存を持たない。

const KIND_MUZZLE_FLASH: String = "muzzle_flash"
const KIND_IMPACT: String = "impact"
const KIND_ARMOR_HIT: String = "armor_hit"
const KIND_PART_HIT: String = "part_hit"
const KIND_PART_DESTROYED: String = "part_destroyed"
const KIND_INCAPACITATED: String = "incapacitated"
const KIND_DESTROYED: String = "destroyed"
const KIND_DAMAGE_TAKEN: String = "damage_taken"
const KIND_KMF_DISABLED: String = "kmf_disabled"
const KIND_EXTRACTION: String = "extraction"
const KIND_PLAYER_DEATH: String = "player_death"
const KIND_RETREAT: String = "retreat"
const KIND_BOARD: String = "board"
const KIND_DISMOUNT: String = "dismount"

const KIND_LABELS: Dictionary = {
	"muzzle_flash": "発砲",
	"impact": "着弾",
	"armor_hit": "装甲命中",
	"part_hit": "部位命中",
	"part_destroyed": "部位破壊",
	"incapacitated": "無力化",
	"destroyed": "撃破",
	"damage_taken": "被弾",
	"kmf_disabled": "KMF機能喪失",
	"extraction": "離脱成功",
	"player_death": "主人公死亡",
	"retreat": "撤退",
	"board": "搭乗",
	"dismount": "降機",
}

## フィードバック要求を生成する。
static func make(kind: String, data: Dictionary = {}) -> Dictionary:
	return {
		"kind": kind,
		"label": str(KIND_LABELS.get(kind, kind)),
		"position": data.get("position", Vector2.ZERO),
		"direction": data.get("direction", Vector2.ZERO),
		"amount": float(data.get("amount", 0.0)),
		"part_id": str(data.get("part_id", "")),
		"source_id": str(data.get("source_id", "")),
		"target_id": str(data.get("target_id", "")),
		"text": str(data.get("text", "")),
		"mode_id": str(data.get("mode_id", "")),
	}
