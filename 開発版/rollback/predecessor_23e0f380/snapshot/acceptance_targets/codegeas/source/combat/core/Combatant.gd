extends RefCounted
## Combatant - 戦闘参加主体の統一モデル (Phase 0.5 Block 4)
##
## Human / KMF を同じ型で扱い、部位 (DamageSystem body) と互換用集計HP を同時に持つ。
## 互換用集計HP は main の既存挙動 (hp meta) を壊さないために保持する。

var id: String = ""
var display_name: String = ""
var team: String = "enemy"          # "player" | "enemy" | "neutral"
var kind: String = "human"          # "human" | "kmf"
var hp: float = 100.0
var max_hp: float = 100.0
var body: Dictionary = {}
var alive: bool = true
var destroyed: bool = false
var incapacitated: bool = false
var position: Vector2 = Vector2.ZERO
var facing: Vector2 = Vector2.RIGHT
var meta: Dictionary = {}

const DamageSystem = preload("res://sandbox/DamageSystem.gd")
const PartEffects = preload("res://combat/core/PartEffects.gd")

func _init(p_id: String = "", p_name: String = "", p_team: String = "enemy", p_kind: String = "human", p_max_hp: float = 100.0) -> void:
	id = p_id
	display_name = p_name if not p_name.is_empty() else p_id
	team = p_team
	kind = p_kind
	max_hp = p_max_hp
	hp = p_max_hp

## DamageSystem 互換の body を作る (既存プロファイルを再利用・複製しない)。
func ensure_body() -> void:
	if body.is_empty():
		body = DamageSystem.create_body(kind)

func get_profile_id() -> String:
	return str(body.get("profile_id", kind))

func get_hp_ratio() -> float:
	if max_hp <= 0.0:
		return 0.0
	return clampf(hp / max_hp, 0.0, 1.0)

## 部位破壊から導かれる効果 (PartEffects)。
func get_effects() -> Dictionary:
	return PartEffects.evaluate(body)

func get_part_ids() -> Array:
	var parts: Dictionary = body.get("parts", {})
	return parts.keys()

func get_part_hp(part_id: String) -> float:
	var parts: Dictionary = body.get("parts", {})
	if not parts.has(part_id):
		return 0.0
	return float((parts[part_id] as Dictionary).get("hp", 0.0))

## 生存可否 (討伐済み・戦闘不能は別概念として保持する)。
func is_active() -> bool:
	return alive and not destroyed

func to_dictionary() -> Dictionary:
	return {
		"id": id,
		"display_name": display_name,
		"team": team,
		"kind": kind,
		"hp": hp,
		"max_hp": max_hp,
		"alive": alive,
		"destroyed": destroyed,
		"incapacitated": incapacitated,
		"position": {"x": position.x, "y": position.y},
	}
