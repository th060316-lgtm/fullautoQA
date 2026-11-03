extends RefCounted
## CombatCore - mode-agnostic 戦闘基盤 (Phase 0.5 Block 4)
##
## 3つの戦闘方式 (Full Realtime / Realtime+Tactical Pause / Lightweight WEGO) が
## 共有する唯一の戦闘処理置き場。
##
## 方針 (契約 01 [4] C / 開発計画 3.3):
##   - damage / hit / target / combat event / part damage / feedback / AI interface を集約。
##   - 戦闘方式固有の処理 (時間進行・判断間隔・planning 中の操作) は
##     一切このクラスに入れない。方式は CombatMode 側 (game/lab/CombatMode.gd) の責務。
##   - 既存 DamageSystem の Human/KMF 部位プロファイルを再利用する (複製しない)。
##   - 互換用集計HP を保持しつつ部位ダメージを並走させる。
##
## 外部 API:
##   register_combatant(c) / get_combatant(id) / list_combatants()
##   resolve_shot(shooter_id, target_id, part_id, amount, context) -> Dictionary
##   apply_damage(target_id, part_id, amount, context) -> Dictionary
##   choose_part(target, aim_point) -> String
##   get_event_log() / get_feedback_log() / clear_logs()
##
## signal:
##   combat_event(event: Dictionary)         戦闘イベント
##   feedback_requested(feedback: Dictionary) 描画・UI 向けフィードバック要求

const DamageSystem = preload("res://sandbox/DamageSystem.gd")
const CombatBalance = preload("res://combat/core/CombatBalance.gd")
const CombatEvent = preload("res://combat/core/CombatEvent.gd")
const PartEffects = preload("res://combat/core/PartEffects.gd")

signal combat_event(event: Dictionary)
signal feedback_requested(feedback: Dictionary)

var _combatants: Dictionary = {}
var _event_log: Array = []
var _feedback_log: Array = []
var _clock: float = 0.0

# ------------------------------------------------------------------
# 登録 / 参照
# ------------------------------------------------------------------

func register_combatant(combatant) -> bool:
	if combatant == null:
		return false
	var cid: String = str(combatant.get("id"))
	if cid.is_empty():
		return false
	combatant.ensure_body()
	_combatants[cid] = combatant
	return true

func unregister_combatant(combatant_id: String) -> void:
	_combatants.erase(combatant_id)

func get_combatant(combatant_id: String):
	if not _combatants.has(combatant_id):
		return null
	return _combatants[combatant_id]

func has_combatant(combatant_id: String) -> bool:
	return _combatants.has(combatant_id)

func list_combatants() -> Array:
	return _combatants.values()

func get_team(team: String) -> Array:
	var out: Array = []
	for c in _combatants.values():
		if str(c.team) == team:
			out.append(c)
	return out

func set_clock(seconds: float) -> void:
	_clock = seconds

func get_clock() -> float:
	return _clock

# ------------------------------------------------------------------
# 部位選択
# ------------------------------------------------------------------

## 射撃点から部位を決める (決定的・乱数なし)。
## 明示指定が無い場合は 'auto' として扱い、正規化矩形へヒットさせる。
func choose_part(target, aim_point: Vector2) -> String:
	if target == null:
		return ""
	var profile: String = str(target.kind)
	var boxes: Dictionary = CombatBalance.PART_HITBOXES.get(profile, {})
	if boxes.is_empty():
		return ""
	var body_size: Vector2 = CombatBalance.get_body_size(profile)
	# ターゲット中心基準・正規化空間
	var offset: Vector2 = (aim_point - target.position) / body_size + Vector2(0.5, 0.5)
	var best_part: String = ""
	var best_overlap: float = 1.0e20
	for part_id in boxes.keys():
		var rect: Rect2 = boxes[part_id]
		if rect.has_point(offset):
			return str(part_id)
		# 当たらなければ最も重なっている部位を退避として選ぶ
		var distance: float = _rect_distance(rect, offset)
		if distance < best_overlap:
			best_overlap = distance
			best_part = str(part_id)
	if not best_part.is_empty():
		return best_part
	# 最終退避: 生命部位のうち残HPが最も低いもの
	return pick_weakest_vital(target)

## 生命部位のうち残HPが最も低い部位 (決定的)。
func pick_weakest_vital(target) -> String:
	if target == null:
		return ""
	var vital: Array = CombatBalance.VITAL_PRIORITY.get(str(target.kind), [])
	var best: String = ""
	var best_hp: float = 1.0e20
	for part_id in vital:
		var hp: float = target.get_part_hp(str(part_id))
		if hp < best_hp:
			best_hp = hp
			best = str(part_id)
	return best

## 正規化点と矩形の最短距離 (0 なら矩形内)。
func _rect_distance(rect: Rect2, point: Vector2) -> float:
	var closest := Vector2(
		clampf(point.x, rect.position.x, rect.position.x + rect.size.x),
		clampf(point.y, rect.position.y, rect.position.y + rect.size.y)
	)
	return closest.distance_to(point)

# ------------------------------------------------------------------
# ダメージ / 命中
# ------------------------------------------------------------------

## 射撃の解決。shooter_id は任意 (不明なら "" で可)。
## part_id が空または 'auto' のときは射撃点から部位を自動選択する。
func resolve_shot(shooter_id: String, target_id: String, part_id: String, amount: float, context: Dictionary = {}) -> Dictionary:
	var shooter = get_combatant(shooter_id) if not shooter_id.is_empty() else null
	var target = get_combatant(target_id)
	if target == null:
		_emit_event(CombatEvent.make(CombatEvent.KIND_MISS, {
			"time": _clock,
			"source_id": shooter_id,
			"target_id": target_id,
			"mode_id": str(context.get("mode_id", "")),
			"meta": {"reason": "no_target"},
		}))
		return {"ok": false, "reason": "no_target", "hit": false}
	if not target.is_active():
		return {"ok": false, "reason": "target_inactive", "hit": false}

	var resolved_part: String = part_id
	if resolved_part.is_empty() or resolved_part == "auto":
		var aim_point: Vector2 = context.get("aim_point", target.position)
		resolved_part = choose_part(target, aim_point)
	if resolved_part.is_empty():
		resolved_part = pick_weakest_vital(target)
		if resolved_part.is_empty():
			resolved_part = "torso"

	_emit_event(CombatEvent.make(CombatEvent.KIND_SHOT, {
		"time": _clock,
		"source_id": shooter_id,
		"target_id": target_id,
		"part_id": resolved_part,
		"amount": amount,
		"position": context.get("origin", shooter.position if shooter != null else target.position),
		"mode_id": str(context.get("mode_id", "")),
	}))

	return apply_damage(target_id, resolved_part, amount, context)

## 部位指定ダメージ。実害はすべてここを通る (Core の唯一の入口)。
func apply_damage(target_id: String, part_id: String, amount: float, context: Dictionary = {}) -> Dictionary:
	var target = get_combatant(target_id)
	if target == null:
		return {"ok": false, "reason": "no_target", "hit": false}
	if not target.is_active():
		return {"ok": false, "reason": "target_inactive", "hit": false}

	# Transition events must compare against the state before this damage application.
	var was_destroyed: bool = target.destroyed
	var was_incapacitated: bool = target.incapacitated
	var parts_before: Dictionary = target.body.get("parts", {})
	var part_before: Dictionary = parts_before.get(part_id, {})
	var was_part_destroyed: bool = bool(part_before.get("destroyed", false))
	var body_result: Dictionary = DamageSystem.apply_damage(target.body, part_id, amount)
	if not bool(body_result.get("applied", false)):
		return {"ok": false, "reason": str(body_result.get("reason", "invalid_target")), "hit": false}

	var applied: float = float(body_result.get("damage", 0.0))
	var part_destroyed: bool = bool(body_result.get("disabled", false))
	target.hp = maxf(0.0, target.hp - applied)
	if bool(body_result.get("incapacitated", false)):
		target.incapacitated = true

	var effects: Dictionary = PartEffects.evaluate(target.body)
	if target.hp <= 0.0:
		target.hp = 0.0
		target.destroyed = true
		target.alive = false
	elif target.incapacitated:
		target.alive = false

	var source_id: String = str(context.get("source_id", ""))
	var mode_id: String = str(context.get("mode_id", ""))
	var hit_pos: Variant = context.get("hit_position", target.position)

	_emit_event(CombatEvent.make(CombatEvent.KIND_HIT, {
		"time": _clock,
		"source_id": source_id,
		"target_id": target_id,
		"part_id": part_id,
		"amount": applied,
		"position": hit_pos,
		"mode_id": mode_id,
	}))
	_emit_event(CombatEvent.make(CombatEvent.KIND_PART_HIT, {
		"time": _clock,
		"source_id": source_id,
		"target_id": target_id,
		"part_id": part_id,
		"amount": applied,
		"position": hit_pos,
		"mode_id": mode_id,
		"meta": {"hp_ratio": target.get_hp_ratio()},
	}))
	# Every successful hit requests readable player-facing feedback.
	_emit_feedback({
		"kind": "hit",
		"position": hit_pos,
		"part_id": part_id,
		"amount": applied,
		"text": "%s -%.0f" % [part_id, applied],
	})

	if part_destroyed and not was_part_destroyed:
		_emit_event(CombatEvent.make(CombatEvent.KIND_PART_DESTROYED, {
			"time": _clock,
			"source_id": source_id,
			"target_id": target_id,
			"part_id": part_id,
			"amount": applied,
			"position": hit_pos,
			"mode_id": mode_id,
			"meta": {"description": PartEffects.describe_part_effect(part_id)},
		}))
		_emit_feedback({
			"kind": "part_destroyed",
			"position": hit_pos,
			"part_id": part_id,
			"amount": applied,
			"text": PartEffects.describe_part_effect(part_id),
		})

	if target.incapacitated and not was_incapacitated:
		_emit_event(CombatEvent.make(CombatEvent.KIND_INCAPACITATED, {
			"time": _clock,
			"source_id": source_id,
			"target_id": target_id,
			"part_id": part_id,
			"amount": applied,
			"position": hit_pos,
			"mode_id": mode_id,
		}))
		_emit_feedback({
			"kind": "incapacitated",
			"position": hit_pos,
			"part_id": part_id,
			"amount": applied,
			"text": "無力化",
		})

	if target.destroyed and not was_destroyed:
		_emit_event(CombatEvent.make(CombatEvent.KIND_DESTROYED, {
			"time": _clock,
			"source_id": source_id,
			"target_id": target_id,
			"part_id": part_id,
			"amount": applied,
			"position": hit_pos,
			"mode_id": mode_id,
			"meta": {"effects": effects},
		}))
		_emit_feedback({
			"kind": "destroyed",
			"position": hit_pos,
			"part_id": part_id,
			"amount": applied,
			"text": "撃破",
		})

	return {
		"ok": true,
		"hit": true,
		"part_id": part_id,
		"damage": applied,
		"target_id": target_id,
		"target_hp": target.hp,
		"part_destroyed": part_destroyed,
		"incapacitated": target.incapacitated,
		"destroyed": target.destroyed,
		"effects": effects,
	}

## 外部 (Lab 等) から追加情報を分析与イベントへ流す。
func emit_event(kind: String, data: Dictionary = {}) -> void:
	_emit_event(CombatEvent.make(kind, data))

func _emit_event(event: Dictionary) -> void:
	_event_log.append(event)
	combat_event.emit(event)

func _emit_feedback(feedback: Dictionary) -> void:
	_feedback_log.append(feedback)
	feedback_requested.emit(feedback)

func get_event_log() -> Array:
	return _event_log.duplicate(true)

func get_feedback_log() -> Array:
	return _feedback_log.duplicate(true)

func clear_logs() -> void:
	_event_log.clear()
	_feedback_log.clear()

## 方式比較用にイベント種別ごとの件数を集計する。
func summarize_events() -> Dictionary:
	var counts: Dictionary = {}
	for event in _event_log:
		var kind: String = str(event.get("kind", ""))
		counts[kind] = int(counts.get(kind, 0)) + 1
	return counts
