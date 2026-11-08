extends "res://combat/CombatManagerLegacy.gd"
## Formal Day1 encounter integration based on the accepted Phase 0.5 core.
## Phase 0.5 Blocks 5-7: normal combat is wired to the same mode-agnostic
## CombatCore / DamageSystem / BaselineTactics used by the Combat Lab.

const CombatCore = preload("res://combat/core/CombatCore.gd")
const Combatant = preload("res://combat/core/Combatant.gd")
const BaselineTactics = preload("res://combat/core/BaselineTactics.gd")
const CombatEvent = preload("res://combat/core/CombatEvent.gd")

const SAFE_LOCATIONS: Array = ["base", "hospital", "evacuation_center", "maintenance"]
const DANGER_LOCATIONS: Array = ["industrial_area", "outskirts"]
const NORMAL_MELEE_RANGE: float = 24.0
const NORMAL_AI_DESIRED_RANGE: float = 24.0
const FEEDBACK_HISTORY_LIMIT: int = 32

var _encounter_active: bool = false
var _combat_core = CombatCore.new()
var _enemy_ai: Dictionary = {}
var _enemy_serial: int = 0
var _ai_tactical_actions: Dictionary = {}
var _feedback_history: Array = []

func _ready() -> void:
	_combat_core.combat_event.connect(_on_core_event)
	_combat_core.feedback_requested.connect(_on_core_feedback)
	super._ready()

func _create_enemy(pos: Vector2, enemy_type: String, hp: float, color: Color) -> void:
	super._create_enemy(pos, enemy_type, hp, color)
	if _enemies.is_empty():
		return
	var enemy = _enemies.back()
	if not is_instance_valid(enemy):
		return
	enemy.set_meta("home_position", pos)
	enemy.set_meta("encounter_state", "idle")
	match enemy_type:
		"enemy_kmf":
			enemy.set_meta("detection_range", 240.0)
			enemy.set_meta("leash_range", 280.0)
		"light_armor":
			enemy.set_meta("detection_range", 165.0)
			enemy.set_meta("leash_range", 210.0)
		_:
			enemy.set_meta("detection_range", 150.0)
			enemy.set_meta("leash_range", 190.0)

	var combatant_id := "world_enemy_%d" % _enemy_serial
	var entity_index := _enemy_serial
	_enemy_serial += 1
	var kind := "kmf" if enemy_type == "enemy_kmf" else "human"
	var combatant = Combatant.new(combatant_id, enemy_type, "enemy", kind, hp)
	combatant.position = enemy.global_position
	combatant.meta = {"enemy_type": enemy_type, "world_instance_id": enemy.get_instance_id()}
	_combat_core.register_combatant(combatant)
	enemy.set_meta("combatant_id", combatant_id)
	var ai := BaselineTactics.new()
	ai.reset({"entity_index": entity_index})
	_enemy_ai[combatant_id] = ai

	var label := Label.new()
	label.name = "EnemyTypeLabel"
	label.position = Vector2(-30, -34)
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(1, 0.86, 0.72))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	enemy.add_child(label)
	var alert := Label.new()
	alert.name = "AlertMark"
	alert.text = "!"
	alert.position = Vector2(-3, -51)
	alert.add_theme_font_size_override("font_size", 20)
	alert.add_theme_color_override("font_color", Color(1, 0.3, 0.2))
	alert.visible = false
	alert.mouse_filter = Control.MOUSE_FILTER_IGNORE
	enemy.add_child(alert)
	_refresh_enemy_readability(enemy, false)

## Normal-world projectiles use the same part-damage path as the Lab.
func _update_projectiles(delta: float) -> void:
	var to_remove: Array = []
	for i in range(_projectiles.size()):
		var p = _projectiles[i]
		p["life"] -= delta
		p["pos"] += p["dir"] * p["speed"] * delta
		if p["node"]:
			p["node"].position = p["pos"] - p["node"].size / 2
		if p["life"] <= 0:
			to_remove.append(i)
			continue
		if p["is_player"]:
			for enemy in _enemies.duplicate():
				if not is_instance_valid(enemy):
					continue
				if p["pos"].distance_to(enemy.global_position) < 18.0:
					apply_enemy_part_damage(enemy, "auto", float(p["damage"]), p["pos"])
					to_remove.append(i)
					break
	to_remove.sort()
	to_remove.reverse()
	for idx in to_remove:
		if idx < 0 or idx >= _projectiles.size():
			continue
		if _projectiles[idx]["node"]:
			_projectiles[idx]["node"].queue_free()
		_projectiles.remove_at(idx)

## Public integration point for tests/future targeting UI.
func apply_enemy_part_damage(enemy: Node, part_id: String, amount: float, hit_position: Vector2) -> Dictionary:
	if enemy == null or not is_instance_valid(enemy):
		return {"ok": false, "reason": "invalid_enemy", "hit": false}
	var combatant_id := str(enemy.get_meta("combatant_id", ""))
	var combatant = _combat_core.get_combatant(combatant_id)
	if combatant == null:
		return {"ok": false, "reason": "unregistered_enemy", "hit": false}
	combatant.position = enemy.global_position
	var result: Dictionary = _combat_core.resolve_shot("player", combatant_id, part_id, amount, {
		"origin": hit_position,
		"aim_point": hit_position,
		"hit_position": hit_position,
		"source_id": "player",
		"mode_id": "world_realtime",
	})
	if not bool(result.get("ok", false)):
		return result
	enemy.set_meta("hp", float(result.get("target_hp", combatant.hp)))
	enemy.set_meta("last_hit_part", str(result.get("part_id", "")))
	enemy.set_meta("part_effects", result.get("effects", {}).duplicate(true))
	_refresh_enemy_readability(enemy, str(enemy.get_meta("encounter_state", "idle")) == "engage")
	if bool(result.get("destroyed", false)) or bool(result.get("incapacitated", false)) or float(result.get("target_hp", 1.0)) <= 0.0:
		_neutralize_enemy(enemy, result)
	return result

func _neutralize_enemy(enemy: Node, result: Dictionary) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var combatant_id := str(enemy.get_meta("combatant_id", ""))
	enemy.set_meta("encounter_state", "neutralized")
	if enemy is CharacterBody2D:
		enemy.velocity = Vector2.ZERO
	if _enemies.has(enemy):
		_enemies.erase(enemy)
	_enemy_ai.erase(combatant_id)
	_combat_core.unregister_combatant(combatant_id)
	if is_instance_valid(enemy):
		enemy.queue_free()
	if bool(result.get("incapacitated", false)) and not bool(result.get("destroyed", false)):
		EventBus.player_notice.emit("敵を無力化しました")

func _update_enemies(delta: float) -> void:
	_combat_core.set_clock(_real_play_seconds)
	var player = get_tree().get_first_node_in_group("player")
	if player == null or not GameState.is_player_alive():
		_set_encounter_active(false, [])
		return
	var player_pos: Vector2 = player.global_position
	var location: String = GameState.get_player_location() if GameState.has_method("get_player_location") else str(GameState.get_section("player").get("locationId", "base"))
	var safe: bool = location in SAFE_LOCATIONS
	var zone_multiplier: float = 1.0
	if safe:
		zone_multiplier = 0.0
	elif location not in DANGER_LOCATIONS:
		zone_multiplier = 0.72
	var engaged_types: Array = []
	for enemy in _enemies.duplicate():
		if not is_instance_valid(enemy):
			continue
		var enemy_type: String = str(enemy.get_meta("type"))
		var base_speed: float = float(enemy.get_meta("speed"))
		var home: Vector2 = enemy.get_meta("home_position", enemy.get_meta("spawn_position", enemy.global_position))
		var combatant_id := str(enemy.get_meta("combatant_id", ""))
		var combatant = _combat_core.get_combatant(combatant_id)
		if combatant == null:
			continue
		combatant.position = enemy.global_position
		var effects: Dictionary = combatant.get_effects()
		var detection_multiplier := float(effects.get("detection_multiplier", 1.0))
		var detection: float = float(enemy.get_meta("detection_range", 150.0)) * zone_multiplier * detection_multiplier
		var leash: float = float(enemy.get_meta("leash_range", 190.0))
		var player_distance: float = enemy.global_position.distance_to(player_pos)
		var player_from_home: float = home.distance_to(player_pos)
		var can_engage: bool = not safe and detection > 0.0 and player_distance <= detection and player_from_home <= leash
		if can_engage:
			enemy.set_meta("encounter_state", "engage")
			engaged_types.append(enemy_type)
			var speed := base_speed * float(effects.get("mobility_multiplier", 1.0))
			if bool(effects.get("immobilized", false)):
				speed = 0.0
			var ai = _enemy_ai.get(combatant_id)
			var context := {
				"self_position": enemy.global_position,
				"player_position": player_pos,
				"distance": player_distance,
				"desired_range": NORMAL_AI_DESIRED_RANGE,
				"detection_range": detection,
				"weapon_ready": not bool(effects.get("weapon_disabled", false)),
				"effects": effects,
				"hp_ratio": combatant.get_hp_ratio(),
				"cover_available": false,
				"allies_alive": _enemies.size(),
				"mode_id": "world_realtime",
				"target_kind": "kmf" if GameState.get_player_mode() == "kmf" else "human",
				"delta": delta,
			}
			var decision: Dictionary = ai.evaluate(context) if ai != null else {"action": "hold", "direction": Vector2.ZERO, "fire": false, "reason": "no_ai"}
			var action := str(decision.get("action", "hold"))
			_record_ai_action(enemy, combatant_id, action, decision)
			var move_dir: Vector2 = decision.get("direction", Vector2.ZERO)
			if action in ["approach", "flank", "retreat", "seek_cover"] and speed > 0.0:
				enemy.velocity = move_dir.normalized() * speed
				enemy.move_and_slide()
			elif action == "engage" and speed > 0.0 and player_distance > NORMAL_MELEE_RANGE * 0.8:
				enemy.velocity = move_dir.normalized() * speed * 0.45
				enemy.move_and_slide()
			else:
				enemy.velocity = Vector2.ZERO
			combatant.position = enemy.global_position
			if bool(decision.get("fire", false)) and not bool(effects.get("weapon_disabled", false)) and enemy.global_position.distance_to(player_pos) < NORMAL_MELEE_RANGE:
				var damage: float = 5.0 if enemy_type == "infantry" else (12.0 if enemy_type == "light_armor" else 20.0)
				GameState.damage_player(damage * delta)
				if GameState.get_player_mode() == "kmf":
					GameState.damage_kmf(damage * delta * 0.5)
		else:
			var distance_home: float = enemy.global_position.distance_to(home)
			if distance_home > 2.0 and not bool(effects.get("immobilized", false)):
				enemy.set_meta("encounter_state", "return")
				var return_speed: float = minf(base_speed * float(effects.get("mobility_multiplier", 1.0)), 70.0)
				enemy.velocity = (home - enemy.global_position).normalized() * return_speed
				enemy.move_and_slide()
			else:
				enemy.set_meta("encounter_state", "idle")
				enemy.velocity = Vector2.ZERO
			combatant.position = enemy.global_position
		_refresh_enemy_readability(enemy, can_engage)
	_set_encounter_active(not engaged_types.is_empty(), engaged_types)

func _record_ai_action(enemy: Node, combatant_id: String, action: String, decision: Dictionary) -> void:
	var previous := str(enemy.get_meta("last_ai_action", ""))
	if action == previous:
		return
	enemy.set_meta("last_ai_action", action)
	if action in ["", "hold", "engage", "approach", "hold_fire"]:
		return
	_ai_tactical_actions[action] = int(_ai_tactical_actions.get(action, 0)) + 1
	_combat_core.emit_event(CombatEvent.KIND_AI_TACTIC, {
		"time": _real_play_seconds,
		"source_id": combatant_id,
		"mode_id": "world_realtime",
		"position": enemy.global_position,
		"meta": {
			"action": action,
			"reason": str(decision.get("reason", "")),
			"direction": decision.get("direction", Vector2.ZERO),
		},
	})

func _on_core_event(event: Dictionary) -> void:
	var target_id := str(event.get("target_id", ""))
	if target_id.is_empty():
		return
	var ai = _enemy_ai.get(target_id)
	if ai != null:
		ai.on_event(event)

func _on_core_feedback(feedback: Dictionary) -> void:
	_feedback_history.append(feedback.duplicate(true))
	while _feedback_history.size() > FEEDBACK_HISTORY_LIMIT:
		_feedback_history.pop_front()
	var kind := str(feedback.get("kind", ""))
	var text := str(feedback.get("text", ""))
	if kind in ["part_destroyed", "incapacitated", "destroyed"] and not text.is_empty():
		EventBus.player_notice.emit(text)

func _refresh_enemy_readability(enemy: Node, alerting: bool) -> void:
	var enemy_type: String = str(enemy.get_meta("type", "enemy"))
	var names: Dictionary = {
		"infantry": "敵歩兵",
		"light_armor": "敵軽装甲",
		"enemy_kmf": "敵KMF",
	}
	var label: Label = enemy.get_node_or_null("EnemyTypeLabel")
	if label:
		var hp: float = maxf(0.0, float(enemy.get_meta("hp", 0.0)))
		var max_hp: float = maxf(1.0, float(enemy.get_meta("max_hp", 1.0)))
		var part := str(enemy.get_meta("last_hit_part", ""))
		var suffix := "  [%s]" % part if not part.is_empty() else ""
		label.text = "%s  HP%d%%%s" % [str(names.get(enemy_type, "敵")), int(round(hp / max_hp * 100.0)), suffix]
	var alert: Label = enemy.get_node_or_null("AlertMark")
	if alert:
		alert.visible = alerting

func _set_encounter_active(active: bool, enemy_ids: Array) -> void:
	if active == _encounter_active:
		return
	_encounter_active = active
	if active:
		if EventBus.has_signal("combat_started"):
			EventBus.combat_started.emit(enemy_ids)
	else:
		if EventBus.has_signal("combat_ended"):
			EventBus.combat_ended.emit("disengaged")

## 「交戦中の最も近い敵」を返す。CameraManager はこの情報を使って
## 重要敵が画面端・HUD裏へ消えない構図を保つ。
func get_focus_target() -> Node2D:
	var player: Node2D = get_tree().get_first_node_in_group("player") if get_tree() else null
	if player == null:
		return null
	var best: Node2D = null
	var best_distance: float = 1.0e20
	for enemy in _enemies:
		if not is_instance_valid(enemy):
			continue
		if str(enemy.get_meta("encounter_state", "idle")) != "engage":
			continue
		var distance: float = enemy.global_position.distance_to(player.global_position)
		if distance < best_distance:
			best_distance = distance
			best = enemy
	return best

func get_engaged_enemies() -> Array:
	var out: Array = []
	for enemy in _enemies:
		if is_instance_valid(enemy) and str(enemy.get_meta("encounter_state", "idle")) == "engage":
			out.append(enemy)
	return out

func get_encounter_zone() -> String:
	var location: String = GameState.get_player_location() if GameState.has_method("get_player_location") else str(GameState.get_section("player").get("locationId", "base"))
	if location in SAFE_LOCATIONS:
		return "safe"
	if location in DANGER_LOCATIONS:
		return "danger"
	return "caution"

func is_encounter_active() -> bool:
	return _encounter_active

func get_combat_core():
	return _combat_core

func get_enemy_combatant(enemy: Node):
	if enemy == null or not is_instance_valid(enemy):
		return null
	return _combat_core.get_combatant(str(enemy.get_meta("combatant_id", "")))

func get_ai_tactical_counts() -> Dictionary:
	return _ai_tactical_actions.duplicate(true)

func get_feedback_history() -> Array:
	return _feedback_history.duplicate(true)
