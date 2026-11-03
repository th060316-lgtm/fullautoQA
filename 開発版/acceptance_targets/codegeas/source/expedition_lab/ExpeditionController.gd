extends Node2D

const ExpeditionFixture = preload("res://expedition_lab/ExpeditionFixture.gd")
const ExpeditionState = preload("res://expedition_lab/state/ExpeditionState.gd")
const CombatCore = preload("res://combat/core/CombatCore.gd")
const PerceptionSystem = preload("res://expedition_lab/systems/PerceptionSystem.gd")
const OrderSystem = preload("res://expedition_lab/systems/OrderSystem.gd")
const AutoPauseSystem = preload("res://expedition_lab/systems/AutoPauseSystem.gd")
const InteractionSystem = preload("res://expedition_lab/systems/InteractionSystem.gd")
const ExtractionSystem = preload("res://expedition_lab/systems/ExtractionSystem.gd")
const CompanionRoleAI = preload("res://expedition_lab/ai/CompanionRoleAI.gd")
const EnemyPatrolAI = preload("res://expedition_lab/ai/EnemyPatrolAI.gd")
const AreaKnowledge = preload("res://expedition_lab/state/AreaKnowledge.gd")
const SoundEventSystem = preload("res://expedition_lab/systems/SoundEventSystem.gd")
const TacticalEquipmentSystem = preload("res://expedition_lab/systems/TacticalEquipmentSystem.gd")
const IntentSystem = preload("res://expedition_lab/systems/IntentSystem.gd")
const InputRouter = preload("res://core/InputRouter.gd")

signal state_changed
signal context_menu_requested(screen_position: Vector2, commands: Array)

var state = ExpeditionState.new()
var core = CombatCore.new()
var perception = PerceptionSystem.new()
var order_system = OrderSystem.new()
var auto_pause = AutoPauseSystem.new()
var interaction = InteractionSystem.new()
var extraction = ExtractionSystem.new()
var companion_ai = CompanionRoleAI.new()
var enemy_ai = EnemyPatrolAI.new()
var time_scale := 1.0
var real_time := 0.0
var _first_hit_seen := false
var _last_auto_pause_code := ""
var _confirmed_once: Dictionary = {}
var context_target: Dictionary = {"kind":"ground","id":"","position":Vector2.ZERO}
var last_feedback_text := ""
var last_feedback_position := Vector2.ZERO
var last_feedback_age := 99.0
var last_action_result: Dictionary = {}
var debug_hud := false
var launch_snapshot: Dictionary = {}
var area_knowledge = AreaKnowledge.new()
var sound_system = SoundEventSystem.new()
var equipment_system = TacticalEquipmentSystem.new()
var intent_system = IntentSystem.new(ExpeditionFixture.build())
var intent_mode := "MOVE"
var intent_draft: Dictionary = {}
var active_intents: Dictionary = {}
var last_sound_scan_time: Dictionary = {}
var preparation_options: Dictionary = {"scout":true,"medic":true,"kmf":true,"preset":"balanced"}
var preparation_locked := false

func _ready() -> void:
	InputRouter.ensure_actions_registered()
	if has_node("/root/CampaignManager") and CampaignManager.has_method("get_active_hospital_district_launch_snapshot"):
		var active_snapshot: Dictionary = CampaignManager.get_active_hospital_district_launch_snapshot()
		if bool(active_snapshot.get("ok", false)):
			launch_snapshot = active_snapshot.duplicate(true)
	reset_prototype()
	set_process(true)

func reset_prototype() -> void:
	state.reset(ExpeditionFixture.build())
	if not launch_snapshot.is_empty():
		_apply_campaign_launch_state()
	_rebuild_combat_core()
	auto_pause = AutoPauseSystem.new()
	companion_ai = CompanionRoleAI.new()
	enemy_ai.reset()
	area_knowledge.reset()
	sound_system.reset()
	equipment_system.reset()
	intent_system = IntentSystem.new(ExpeditionFixture.build())
	intent_draft = {}
	active_intents.clear()
	last_sound_scan_time.clear()
	preparation_locked = false
	_configure_equipment_for_party()
	time_scale = 1.0
	real_time = 0.0
	_first_hit_seen = false
	_last_auto_pause_code = ""
	_confirmed_once.clear()
	last_feedback_text = "Unit選択 → Intent選択 → 地面を右クリックでPreview → Enter/CONFIRM"
	last_feedback_position = state.actors.get("hero").position
	last_feedback_age = 0.0
	last_action_result = {}
	queue_redraw()
	state_changed.emit()

func _process(delta: float) -> void:
	real_time += delta
	last_feedback_age += delta
	state.metrics["elapsed_real_time"] = real_time
	if auto_pause.paused or state.phase == "complete":
		return
	step_simulation(delta * time_scale)

func step_simulation(delta: float) -> void:
	if delta <= 0.0:
		return
	state.sim_time += delta
	state.metrics["elapsed_sim_time"] = state.sim_time
	core.set_clock(state.sim_time)
	equipment_system.tick(state, delta)
	area_knowledge.set_time(state.sim_time)
	area_knowledge.update_decay(state.sim_time)
	for id in state.actors.keys():
		if order_system.tick_movement(state, str(id), delta):
			state.metrics["arrivals"] = int(state.metrics.get("arrivals", 0)) + 1
			_handle_intent_arrival(str(id))
			var arrived = state.actors.get(str(id))
			if arrived != null and (str(id) == state.selected_id or str(id) == get_controlled_actor_id(state.selected_id)):
				_set_feedback("到着: " + str(active_intents.get(str(id), {}).get("intent", "MOVE")), arrived.position)
	var companion_reports := companion_ai.tick(state, order_system, perception, delta)
	for report in companion_reports:
		if str(report.get("kind",""))=="guard_attack":
			attack(str(report.get("source","")),str(report.get("target","")),"auto")
		else:
			_handle_knowledge_event(report)
	for event in enemy_ai.tick(state, delta):
		match str(event.get("kind","")):
			"enemy_detected_player":
				request_auto_pause("enemy_spotted_us", "敵に発見された: " + str(event.get("enemy_id","")))
			"enemy_attack":
				_resolve_enemy_attack(event)
		if auto_pause.paused:
			queue_redraw()
			state_changed.emit()
			return
	for observer_id in _perception_observer_ids():
		for event in perception.scan(state, observer_id):
			_handle_knowledge_event(event)
			if auto_pause.paused:
				queue_redraw()
				state_changed.emit()
				return
		var since := float(last_sound_scan_time.get(observer_id, maxf(0.0, state.sim_time - delta - 0.01)))
		for sound_event in perception.scan_sounds(state, observer_id, sound_system, since):
			_handle_knowledge_event(sound_event)
		last_sound_scan_time[observer_id] = state.sim_time
	_tick_intent_exploration()
	_tick_intent_combat()
	state.knowledge.decay(state.sim_time)
	queue_redraw()
	state_changed.emit()

func _handle_knowledge_event(event: Dictionary) -> void:
	if not bool(event.get("changed", false)):
		return
	var transition := "%s->%s" % [str(event.get("previous", "unknown")), str(event.get("current", "unknown"))]
	var transitions: Dictionary = state.metrics.get("contact_transitions", {})
	transitions[transition] = int(transitions.get(transition, 0)) + 1
	state.metrics["contact_transitions"] = transitions
	if str(event.get("current", "")) == "confirmed":
		var contact_id := str(event.get("contact", {}).get("id", ""))
		if not _confirmed_once.has(contact_id):
			_confirmed_once[contact_id] = true
			state.metrics["confirmed_contacts"] = int(state.metrics.get("confirmed_contacts", 0)) + 1
			_set_feedback("敵影を確認。攻撃・部位狙い・回避を選択", event.get("contact", {}).get("estimated_position", Vector2.ZERO))
			request_auto_pause("first_confirmed_enemy", "敵を初確認: " + (contact_id if not contact_id.is_empty() else "不明"))
	elif str(event.get("current", "")) == "lost_contact":
		_set_feedback("接触喪失。表示は最終確認位置", event.get("contact", {}).get("estimated_position", Vector2.ZERO))

func request_auto_pause(code: String, message: String) -> void:
	if auto_pause.paused and _last_auto_pause_code == code:
		return
	_last_auto_pause_code = code
	auto_pause.trigger(code, message, state.sim_time, state.metrics)

func set_time_scale(value: float) -> Dictionary:
	if value == 0.0:
		auto_pause.manual_pause(state.metrics)
		time_scale = 0.0
		return {"ok": true, "paused": true}
	if not value in [1.0, 4.0, 8.0]:
		return {"ok": false, "reason": "invalid_scale"}
	time_scale = value
	auto_pause.resume()
	_last_auto_pause_code = ""
	return {"ok": true, "scale": value}

func select_actor(actor_id: String) -> Dictionary:
	if not state.actors.has(actor_id):
		return _record_result({"ok": false, "reason": "no_actor"}, "select", Vector2.ZERO)
	state.selected_id = actor_id
	var actor = state.actors[actor_id]
	return _record_result({"ok": true, "actor_id": actor_id}, "select", actor.position)

func issue_move(actor_id: String, destination: Vector2) -> Dictionary:
	var result := order_system.issue_move(state, actor_id, destination)
	return _record_result(result, "repath" if bool(result.get("replaced", false)) else "move", destination)

func cancel_move(actor_id: String = "") -> Dictionary:
	var actual_id := get_controlled_actor_id(state.selected_id if actor_id.is_empty() else actor_id)
	var result := order_system.cancel_move(state, actual_id)
	return _record_result(result, "cancel_move", state.actors.get(actual_id).position if state.actors.has(actual_id) else Vector2.ZERO)

func set_role(actor_id: String, role: String) -> Dictionary:
	var result := order_system.issue_role(state, actor_id, role)
	if bool(result.get("ok", false)):
		state.metrics["non_attack_actions"] = int(state.metrics.get("non_attack_actions", 0)) + 1
		if role == "Scout": state.metrics["scout_actions"] = int(state.metrics.get("scout_actions", 0)) + 1
	return _record_result(result, "role:" + role, state.actors.get(actor_id).position if state.actors.has(actor_id) else Vector2.ZERO)

func attack(attacker_id: String, target_id: String, part_id: String = "auto") -> Dictionary:
	var controlled_attacker_id := _controlled_actor_id(attacker_id)
	var attacker = state.actors.get(controlled_attacker_id)
	var target = state.actors.get(target_id)
	if attacker == null or target == null:
		return {"ok": false, "reason": "missing_actor"}
	if attacker.incapacitated or attacker.destroyed:
		return {"ok": false, "reason": "attacker_incapacitated"}
	if attacker.kind=="kmf" and attacker.team=="player" and not bool(attacker.meta.get("boarded",false)):
		return {"ok":false,"reason":"kmf_unoccupied"}
	if not state.knowledge.has_exact_truth(target_id):
		return {"ok": false, "reason": "target_not_confirmed"}
	if not equipment_system.can_attack(controlled_attacker_id):
		return {"ok": false, "reason": "weapon_cooldown"}
	var distance: float = attacker.position.distance_to(target.position)
	var weapon: Dictionary = equipment_system.choose_weapon(attacker, distance)
	if weapon.is_empty():
		return {"ok": false, "reason": "weapon_disabled"}
	if distance > float(weapon.get("max", 0.0)):
		return {"ok": false, "reason": "out_of_range", "max_range":weapon.get("max",0.0)}
	attacker.meta["facing"] = (target.position - attacker.position).angle()
	state.phase = "combat"
	state.metrics["combat_started"] = true
	if part_id != "auto":
		state.metrics["part_target_actions"] = int(state.metrics.get("part_target_actions", 0)) + 1
	var accuracy_scale := float(attacker.meta.get("suppression_accuracy", 1.0))
	var damage := float(weapon.get("damage", 8.0)) * lerpf(0.72, 1.0, accuracy_scale)
	var result := core.resolve_shot(controlled_attacker_id, target_id, part_id, damage, {
		"source_id": controlled_attacker_id,
		"mode_id": "intent_tactical_expedition",
		"origin": attacker.position,
		"hit_position": target.position,
		"weapon_slot": weapon.get("slot","primary"),
		"weapon_name": weapon.get("name",""),
	})
	equipment_system.trigger_cooldown(controlled_attacker_id, float(weapon.get("cooldown", 0.7)))
	equipment_system.apply_suppression(target_id, float(weapon.get("suppression", 0.0)))
	sound_system.emit_sound(attacker.position, float(weapon.get("noise", 180.0)), 1.0, "weapon", controlled_attacker_id, state.sim_time, attacker.team)
	if bool(result.get("incapacitated", false)):
		state.metrics["enemies_incapacitated"] = int(state.metrics.get("enemies_incapacitated", 0)) + 1
	if bool(result.get("destroyed", false)):
		state.metrics["enemies_killed"] = int(state.metrics.get("enemies_killed", 0)) + 1
	return result

func apply_incoming_damage(target_id: String, part_id: String, amount: float, source_id: String = "enemy") -> Dictionary:
	var before = state.actors.get(target_id)
	var source = state.actors.get(source_id)
	var source_position: Vector2 = before.position + Vector2.RIGHT * -100.0 if before != null else Vector2.ZERO
	if source != null:
		source_position = source.position
	var shield := equipment_system.resolve_incoming(before, source_position, amount)
	var mitigated := float(shield.get("damage", amount))
	var result := core.apply_damage(target_id, part_id, mitigated, {"source_id": source_id, "mode_id": "intent_tactical_expedition", "shield_blocked":shield.get("blocked",false)})
	if bool(shield.get("blocked", false)) and before != null:
		_set_feedback("盾で被弾を軽減  残耐久 %.0f" % float(shield.get("shield",0.0)), before.position)
	if bool(result.get("ok", false)):
		state.metrics["damage_received"] = float(state.metrics.get("damage_received", 0.0)) + float(result.get("damage", 0.0))
		if not _first_hit_seen:
			_first_hit_seen = true
			request_auto_pause("first_friendly_hit", "味方が初被弾: " + target_id)
		if bool(result.get("incapacitated", false)):
			request_auto_pause("friendly_incapacitated", "重傷・行動不能: " + target_id)
		if before != null and before.kind == "kmf" and bool(result.get("part_destroyed", false)) and part_id in ["cockpit", "sensor", "frame", "left_leg", "right_leg", "weapon"]:
			request_auto_pause("kmf_critical_part", "KMF重要部位破壊: " + part_id)
	return result

func observe_contact(contact_id: String, level: String, source: String = "manual") -> Dictionary:
	var enemy = state.actors.get(contact_id)
	if enemy == null:
		return {"ok": false}
	var uncertainty := 0.0 if level == "confirmed" else 60.0
	var estimate: Vector2 = enemy.position
	if level != "confirmed":
		var angle := deg_to_rad(float(abs(contact_id.hash()) % 360))
		estimate += Vector2.RIGHT.rotated(angle) * uncertainty * 0.45
	var event: Dictionary = state.knowledge.observe(contact_id, level, source, 1.0 if level == "confirmed" else 0.65, state.sim_time, estimate, uncertainty)
	_handle_knowledge_event(event)
	return {"ok": true, "event": event}

func ordered_observe(observer_id: String, contact_id: String) -> Dictionary:
	var controlled_observer_id:=_controlled_actor_id(observer_id)
	var result := perception.ordered_observe(state, controlled_observer_id, contact_id)
	if bool(result.get("ok", false)):
		state.metrics["observe_actions"] = int(state.metrics.get("observe_actions", 0)) + 1
		state.metrics["non_attack_actions"] = int(state.metrics.get("non_attack_actions", 0)) + 1
		_handle_knowledge_event(result.get("event", {}))
	return result

func board_kmf(actor_id: String = "hero") -> Dictionary:
	return interaction.board(state, actor_id, "friendly_kmf")

func dismount_kmf(actor_id: String = "hero") -> Dictionary:
	return interaction.dismount(state, actor_id, "friendly_kmf")

func collect_loot(actor_id: String, loot_id: String) -> Dictionary:
	var result := interaction.collect_loot(state, actor_id, loot_id)
	return _record_result(result, "collect", state.loot.get(loot_id, {}).get("position", Vector2.ZERO))

func acquire_intel(actor_id: String, source_id: String) -> Dictionary:
	var result := interaction.acquire_intel(state, actor_id, source_id)
	if bool(result.get("ok", false)):
		state.metrics["non_attack_actions"] = int(state.metrics.get("non_attack_actions", 0)) + 1
	if bool(result.get("ok", false)) and source_id == "hospital_terminal":
		request_auto_pause("important_objective", "重要目標を確認: 病院端末")
	return _record_result(result, "inspect", state.intel_sources.get(source_id, {}).get("position", Vector2.ZERO))

func rescue(actor_id: String, target_id: String = "civilian_01") -> Dictionary:
	var result := interaction.rescue(state, actor_id, target_id)
	if bool(result.get("ok", false)):
		state.metrics["non_attack_actions"] = int(state.metrics.get("non_attack_actions", 0)) + 1
		request_auto_pause("important_person", "重要人物を確保: 救助対象")
	return _record_result(result, "rescue", state.rescue_targets.get(target_id, {}).get("position", Vector2.ZERO))

func carry(carrier_id: String, casualty_id: String) -> Dictionary:
	return interaction.carry(state, carrier_id, casualty_id)

func start_retreat() -> Dictionary:
	request_auto_pause("retreat_route_threat", "撤退開始: 主退路と予備退路を確認")
	state.metrics["non_attack_actions"] = int(state.metrics.get("non_attack_actions", 0)) + 1
	return _record_result(extraction.start_retreat(state), "retreat", ExpeditionFixture.EXTRACTION_PRIMARY)

func evaluate_extraction(use_backup: bool = false) -> Dictionary:
	var point := ExpeditionFixture.EXTRACTION_BACKUP if use_backup else ExpeditionFixture.EXTRACTION_PRIMARY
	var result := extraction.evaluate(state, point)
	_record_result(result, "extract", point)
	if bool(result.get("retreat_success", false)):
		finalize_campaign_return()
	return result

func abandon_kmf() -> void:
	state.abandoned_kmf = true
	state.metrics["kmf_abandoned"] = 1
	var kmf = state.actors.get("friendly_kmf")
	if kmf != null:
		kmf.meta["abandoned"] = true

func context_commands(target_kind: String) -> Array:
	match target_kind:
		"ground":
			var controlled_id := get_controlled_actor_id(state.selected_id)
			return ["move", "cancel_move"] if str(state.orders.peek(controlled_id).get("kind", "")) == "move" else ["move"]
		"enemy": return ["observe", "attack", "target_part", "reposition", "retreat", "hold_fire"]
		"friendly": return ["carry"]
		"kmf": return ["board", "dismount", "move", "field_repair"]
		"loot": return ["collect"]
		"intel": return ["inspect"]
		"rescue_target": return ["rescue"]
	return []

func get_context_presentations() -> Array:
	var commands: Array = context_commands(str(context_target.get("kind", "ground")))
	var out: Array = []
	for command in commands:
		var reason := _command_block_reason(str(command))
		out.append({
			"command": str(command), "target_name": _context_target_name(),
			"action_label": _command_label(str(command)),
			"input": InputRouter.get_label("tactical_context"),
			"distance": _context_distance(), "required_mode": _required_mode(str(command)),
			"blocked": not reason.is_empty(), "reason": reason,
			"hint": _command_hint(str(command)),
		})
	return out

func get_available_target_parts(target_id: String) -> Array:
	var target = state.actors.get(target_id)
	if target == null: return []
	if target.kind == "kmf":
		return ["weapon", "sensor", "left_leg", "right_leg", "frame", "cockpit"]
	return ["left_leg", "right_leg", "left_arm", "right_arm", "torso"]

func get_part_presentations(target_id: String) -> Array:
	var out: Array = []
	for part_id in get_available_target_parts(target_id):
		out.append({"command": "target_part:" + str(part_id), "target_name": _context_target_name(), "action_label": _part_label(str(part_id)), "input": "選択", "distance": _context_distance(), "required_mode": "射撃可能", "blocked": false, "reason": "", "hint": _part_hint(str(part_id))})
	return out

func resolve_context(point: Vector2) -> Dictionary:
	for contact in state.knowledge.visible_contacts():
		if (contact.get("estimated_position",Vector2.ZERO) as Vector2).distance_to(point) <= 28.0:
			return {"kind":"enemy","id":str(contact.get("id","")),"position":point}
	for id in state.loot.keys():
		if not bool(state.loot[id].get("taken",false)) and (state.loot[id].get("position",Vector2.ZERO) as Vector2).distance_to(point)<=26.0:
			return {"kind":"loot","id":str(id),"position":point}
	for id in state.intel_sources.keys():
		if not bool(state.intel_sources[id].get("examined",false)) and (state.intel_sources[id].get("position",Vector2.ZERO) as Vector2).distance_to(point)<=26.0:
			return {"kind":"intel","id":str(id),"position":point}
	for id in state.rescue_targets.keys():
		if str(state.rescue_targets[id].get("status",""))=="waiting" and (state.rescue_targets[id].get("position",Vector2.ZERO) as Vector2).distance_to(point)<=28.0:
			return {"kind":"rescue_target","id":str(id),"position":point}
	for id in state.actors.keys():
		var actor=state.actors[id]
		if actor.team!="player":
			continue
		if actor.kind=="human" and not str(actor.meta.get("inside_kmf","")).is_empty():
			continue
		if actor.position.distance_to(point)<=28.0:
			return {"kind":"kmf" if actor.kind=="kmf" else "friendly","id":str(id),"position":point}
	return {"kind":"ground","id":"","position":point}

func execute_context_command(command: String) -> Dictionary:
	var target_id:=str(context_target.get("id",""))
	state.metrics["context_interactions"] = int(state.metrics.get("context_interactions", 0)) + 1
	if command == "target_part":
		return {"ok": false, "reason": "part_selection_required", "parts": get_available_target_parts(target_id)}
	if command.begins_with("target_part:"):
		var part_id := command.trim_prefix("target_part:")
		return _record_result(attack(state.selected_id, target_id, part_id), command, context_target.get("position", Vector2.ZERO))
	match command:
		"move": return issue_move(state.selected_id,context_target.get("position",Vector2.ZERO))
		"cancel_move": return cancel_move()
		"observe": return _record_result(ordered_observe(state.selected_id,target_id), "observe", context_target.get("position", Vector2.ZERO))
		"attack": return _record_result(attack(state.selected_id,target_id,"auto"), "attack", context_target.get("position", Vector2.ZERO))
		"reposition":
			var actor = state.actors.get(get_controlled_actor_id(state.selected_id))
			if actor == null: return _record_result({"ok": false, "reason": "no_actor"}, command, Vector2.ZERO)
			var target_position: Vector2 = context_target.get("position", actor.position)
			var away: Vector2 = (actor.position - target_position).normalized()
			if away == Vector2.ZERO: away = Vector2.LEFT
			return issue_move(state.selected_id, actor.position + away.rotated(0.55) * 130.0)
		"retreat": return start_retreat()
		"hold_fire": return set_role(state.selected_id, "HoldFire")
		"collect": return collect_loot(state.selected_id,target_id)
		"inspect":
			if str(context_target.get("kind",""))=="intel": return acquire_intel(state.selected_id,target_id)
			return {"ok":true,"inspected":target_id}
		"rescue": return rescue(state.selected_id,target_id)
		"carry": return _record_result(carry(state.selected_id,target_id), command, context_target.get("position", Vector2.ZERO))
		"board": return _record_result(interaction.board(state,state.selected_id,target_id), command, context_target.get("position", Vector2.ZERO))
		"dismount":
			var kmf=state.actors.get(target_id)
			if kmf==null: return {"ok":false,"reason":"no_kmf"}
			return _record_result(interaction.dismount(state,str(kmf.meta.get("pilot_id","")),target_id), command, context_target.get("position", Vector2.ZERO))
		"field_repair":
			var repair_actor = state.actors.get(state.selected_id)
			var repair_target = state.actors.get(target_id)
			if repair_actor == null or repair_actor.kind != "human" or state.selected_id == "hero" or not str(repair_actor.meta.get("inside_kmf","")).is_empty():
				return _record_result({"ok":false,"reason":"requires_companion_repairer"}, command, context_target.get("position", Vector2.ZERO))
			if repair_target == null or repair_target.kind != "kmf":
				return _record_result({"ok":false,"reason":"no_kmf"}, command, context_target.get("position", Vector2.ZERO))
			if repair_actor.position.distance_to(repair_target.position) > 75.0:
				return _record_result({"ok":false,"reason":"out_of_range"}, command, context_target.get("position", Vector2.ZERO))
			return set_role(state.selected_id,"Repair")
	return _record_result({"ok":false,"reason":"not_implemented","command":command}, command, context_target.get("position", Vector2.ZERO))

func _controlled_actor_id(actor_id: String) -> String:
	var actor = state.actors.get(actor_id)
	if actor == null:
		return actor_id
	var kmf_id := str(actor.meta.get("inside_kmf", ""))
	if not kmf_id.is_empty() and state.actors.has(kmf_id):
		return kmf_id
	return actor_id

func get_controlled_actor_id(actor_id: String) -> String:
	return _controlled_actor_id(actor_id)

func _default_target_part(target_id: String) -> String:
	var target=state.actors.get(target_id)
	if target==null:
		return "auto"
	return "weapon" if target.kind=="kmf" else "left_leg"

func _context_target_name() -> String:
	var kind := str(context_target.get("kind", "ground"))
	var id := str(context_target.get("id", ""))
	if kind == "ground": return "指定地点"
	if kind == "enemy":
		var contact: Dictionary = state.knowledge.get_contact(id)
		if str(contact.get("status", "unknown")) != "confirmed": return "不明接触"
		var enemy = state.actors.get(id)
		return id if enemy == null else enemy.display_name
	var names := {"medical_cache":"医療物資", "spare_parts":"KMF部品", "food_crate":"食料箱", "hospital_terminal":"病院端末", "radio_wreck":"無線機残骸", "resident_report":"住民証言", "civilian_01":"救助対象"}
	if names.has(id): return str(names[id])
	var actor = state.actors.get(id)
	return id if actor == null else actor.display_name

func _context_distance() -> float:
	var actor = state.actors.get(get_controlled_actor_id(state.selected_id))
	if actor == null: return -1.0
	return actor.position.distance_to(context_target.get("position", actor.position))

func _command_block_reason(command: String) -> String:
	var target_id := str(context_target.get("id", ""))
	var actor = state.actors.get(get_controlled_actor_id(state.selected_id))
	if actor == null or actor.incapacitated or actor.destroyed: return "選択Unitが行動不能"
	if command in ["attack", "target_part"]:
		if not state.knowledge.has_exact_truth(target_id): return "目標未確認 — 先に観察"
		if bool(actor.get_effects().get("weapon_disabled", false)): return "武器使用不能"
		var target = state.actors.get(target_id)
		if target == null: return "対象なし"
		var attack_range := 220.0 if actor.kind == "human" else 320.0
		if actor.position.distance_to(target.position) > attack_range: return "射程外 — 再配置が必要"
	if command == "observe" and _context_distance() > 300.0: return "観測範囲外 — 接近が必要"
	if command == "carry":
		var carry_target = state.actors.get(target_id)
		if carry_target == null or not carry_target.incapacitated: return "搬送対象ではない"
	if command == "board":
		var board_target = state.actors.get(target_id)
		if board_target == null or bool(board_target.meta.get("boarded", false)): return "搭乗不可または使用中"
	if command == "dismount":
		var dismount_target = state.actors.get(target_id)
		if dismount_target == null or str(dismount_target.meta.get("pilot_id", "")).is_empty(): return "搭乗者なし"
	if command in ["collect", "inspect", "rescue"] and _context_distance() > 65.0: return "距離不足 — 先に移動"
	if command == "field_repair":
		var repair_actor = state.actors.get(state.selected_id)
		if repair_actor == null or repair_actor.kind != "human" or state.selected_id == "hero" or not str(repair_actor.meta.get("inside_kmf","")).is_empty(): return "整備役の仲間を選択"
		if _context_distance() > 75.0: return "距離不足 — KMFへ接近"
	return ""

func _command_label(command: String) -> String:
	var labels := {"move":"移動", "cancel_move":"移動命令を取消", "observe":"観察・識別", "attack":"攻撃", "target_part":"部位を選んで攻撃", "reposition":"射線から再配置", "retreat":"撤退開始", "hold_fire":"射撃停止", "carry":"搬送", "board":"搭乗", "dismount":"降機", "field_repair":"応急修理役割", "collect":"回収", "inspect":"調査", "rescue":"救助・同行"}
	return str(labels.get(command, command))

func _required_mode(command: String) -> String:
	if command in ["attack", "target_part"]: return "確認済み接触・射程内"
	if command == "observe": return "観測範囲内"
	if command in ["collect", "inspect", "rescue", "carry", "board"]: return "接近"
	if command == "field_repair": return "徒歩の仲間・KMFへ接近"
	return "戦術指揮"

func _command_hint(command: String) -> String:
	var hints := {"move":"経路と到達予測を表示", "cancel_move":"現在の経路を取り消す", "observe":"不確実な接触を確認へ進める", "attack":"自動部位で射撃", "target_part":"武器・センサー・脚などを明示選択", "reposition":"敵から距離を取り側面へ移動", "retreat":"離脱地点への帰還を開始", "hold_fire":"選択Unitの自動射撃を停止", "collect":"帰還時にCampaign物資へ反映", "inspect":"Intelを取得し判断材料を増やす", "rescue":"対象を同行させ物理的離脱が必要"}
	return str(hints.get(command, "実行結果を画面上部へ表示"))

func _part_label(part_id: String) -> String:
	var labels := {"weapon":"武器", "sensor":"センサー", "left_leg":"左脚", "right_leg":"右脚", "left_arm":"左腕", "right_arm":"右腕", "frame":"機体フレーム", "cockpit":"コックピット", "torso":"胴体"}
	return "部位狙い: " + str(labels.get(part_id, part_id))

func _part_hint(part_id: String) -> String:
	if part_id == "weapon": return "反撃能力を奪う非致死無力化候補"
	if part_id in ["left_leg", "right_leg"]: return "移動力を削り、両脚破壊で無力化"
	if part_id == "sensor": return "索敵性能を低下"
	if part_id == "cockpit": return "致命部位。非致死目的には不向き"
	return "局所損傷を与える"

func _record_result(result: Dictionary, action: String, at: Vector2) -> Dictionary:
	last_action_result = result.duplicate(true)
	if bool(result.get("ok", false)) or bool(result.get("retreat_success", false)):
		if float(state.metrics.get("first_valid_order_time", -1.0)) < 0.0:
			state.metrics["first_valid_order_time"] = real_time
		_set_feedback(_success_feedback(action, result), at)
	else:
		state.metrics["invalid_commands"] = int(state.metrics.get("invalid_commands", 0)) + 1
		var reason := str(result.get("reason", "実行不可"))
		var blocked: Dictionary = state.metrics.get("blocked_commands", {})
		blocked[reason] = int(blocked.get(reason, 0)) + 1
		state.metrics["blocked_commands"] = blocked
		_set_feedback("実行不可: " + _reason_label(reason), at)
	state_changed.emit()
	return result

func _success_feedback(action: String, result: Dictionary) -> String:
	if action in ["move", "repath"]:
		return ("経路変更" if action == "repath" else "移動開始") + " — 到着予測 %.1f秒" % float(result.get("eta", 0.0))
	if action.begins_with("target_part:"): return _part_label(action.trim_prefix("target_part:")) + "を実行"
	var labels := {"select":"Unit選択", "observe":"観察を実行", "attack":"攻撃を実行", "collect":"物資を確保", "inspect":"Intelを取得", "rescue":"救助対象が同行", "retreat":"撤退開始 — 離脱地点へ移動", "extract":"離脱成立", "cancel_move":"移動命令を取消"}
	return str(labels.get(action, "命令を受理"))

func _reason_label(reason: String) -> String:
	var labels := {"out_of_range":"射程・距離外", "target_not_confirmed":"目標未確認", "weapon_disabled":"武器使用不能", "no_path":"経路なし", "immobilized":"脚部損傷で移動不能", "requires_medic":"衛生・整備担当が必要", "requires_companion_repairer":"整備役の仲間が必要", "not_implemented":"未実装行動", "no_active_move":"移動命令なし"}
	return str(labels.get(reason, reason))

func _set_feedback(message: String, at: Vector2) -> void:
	last_feedback_text = message
	last_feedback_position = at
	last_feedback_age = 0.0

func _resolve_enemy_attack(event: Dictionary) -> void:
	var target_id:=str(event.get("target_id",""))
	var target=state.actors.get(target_id)
	if target==null:
		return
	var enemy_id:=str(event.get("enemy_id","enemy"))
	var enemy=state.actors.get(enemy_id)
	if enemy!=null:
		sound_system.emit_sound(enemy.position, 280.0 if enemy.kind=="human" else 420.0, 1.0, "enemy_weapon", enemy_id, state.sim_time, "enemy")
	var part_id:="sensor" if target.kind=="kmf" and target.get_part_hp("sensor")>0.0 else ("frame" if target.kind=="kmf" else ("left_leg" if target.get_part_hp("left_leg")>0.0 else "torso"))
	apply_incoming_damage(target_id,part_id,float(event.get("amount",6.0)),enemy_id)

func get_hud_model() -> Dictionary:
	var selected = state.actors.get(state.selected_id)
	var arena = get_node_or_null("ExpeditionArena")
	var route: Dictionary = {} if arena == null else arena.get_route_view()
	var objective := "Intel・医療物資・救助対象を確保"
	if state.primary_progress > 0: objective = "確保物を持ち帰る。必要なら撤退を開始"
	if state.retreat_started: objective = "南西の主退路または西の予備退路へ移動"
	var danger := "接触なし — Scoutで北側を偵察"
	var contacts: Array = state.knowledge.visible_contacts()
	if not contacts.is_empty(): danger = "不明接触あり — 観察して確認"
	for contact in contacts:
		if str(contact.get("status", "")) == "confirmed": danger = "敵確認 — 攻撃・部位狙い・回避を選択"
	if not auto_pause.reason.is_empty(): danger = auto_pause.reason
	return {"phase": state.phase, "selected_id": state.selected_id, "selected_name": "" if selected == null else selected.display_name, "selected_role": state.orders.get_role(state.selected_id), "auto_pause_reason": auto_pause.reason, "time_scale": time_scale, "contacts": contacts, "retreat_primary": ExpeditionFixture.EXTRACTION_PRIMARY, "retreat_backup": ExpeditionFixture.EXTRACTION_BACKUP, "summary": state.outcome_summary(), "objective": objective, "danger": danger, "route": route, "feedback": last_feedback_text, "debug": debug_hud, "controls": InputRouter.get_profile_labels(InputRouter.PROFILE_TACTICAL), "metrics": state.metrics.duplicate(true), "intent_mode":intent_mode, "intent_preview":get_intent_preview(), "area_knowledge":area_knowledge.snapshot(), "preparation":preparation_options.duplicate(true), "preparation_locked":preparation_locked}

func get_outcome_summary() -> Dictionary:
	return state.outcome_summary()

func deterministic_snapshot() -> Dictionary:
	return state.snapshot()

func configure_campaign_launch(snapshot: Dictionary) -> Dictionary:
	if str(snapshot.get("site_id", "")) != "hospital_district" or not snapshot.has("seed"):
		return {"ok": false, "reason": "invalid_launch_snapshot"}
	launch_snapshot = snapshot.duplicate(true)
	reset_prototype()
	return {"ok": true, "seed": state.seed, "region_id": snapshot.get("region_id", "")}

func _rebuild_combat_core() -> void:
	core = CombatCore.new()
	for actor in state.actors.values():
		core.register_combatant(actor)

func _apply_campaign_launch_state() -> void:
	state.seed = int(launch_snapshot.get("seed", state.seed))
	var party_ids: Array = launch_snapshot.get("party_ids", [])
	for fixture_id in ["scout", "medic"]:
		if fixture_id not in party_ids:
			state.actors.erase(fixture_id)
			state.orders.roles.erase(fixture_id)
			state.orders.queues.erase(fixture_id)
	var companions: Dictionary = launch_snapshot.get("companions", {})
	var hero = state.actors.get("hero")
	var origin: Vector2 = Vector2(145, 680)
	if hero != null:
		origin = hero.position
	var spawn_index := 0
	for actor_id in party_ids:
		var cid := str(actor_id)
		if cid == "hero" or state.actors.has(cid): continue
		var data: Dictionary = companions.get(cid, {})
		var role := _campaign_role_to_tactical(str(data.get("role", "survivor")))
		var offset := Vector2(30.0 + float(spawn_index % 2) * 26.0, -30.0 + float(spawn_index / 2) * 34.0)
		var meta := {"role": role, "speed": 86.0}
		if role == "Scout": meta["sensor"] = 1.3
		state.add_player_actor({"id": cid, "name": str(data.get("display_name", cid)), "kind": "human", "hp": 100.0, "position": origin + offset, "meta": meta})
		state.orders.set_role(cid, role)
		spawn_index += 1

	var human_status: Dictionary = launch_snapshot.get("human_status", {})
	for actor_id in human_status.keys():
		_restore_actor_status(str(actor_id), human_status[actor_id])

	var kmf_ids: Array = launch_snapshot.get("kmf_ids", [])
	if kmf_ids.is_empty():
		state.actors.erase("friendly_kmf")
		state.orders.roles.erase("friendly_kmf")
		state.orders.queues.erase("friendly_kmf")
	else:
		var kmf = state.actors.get("friendly_kmf")
		if kmf != null:
			var campaign_kmf_id := str(kmf_ids[0])
			kmf.meta["campaign_kmf_id"] = campaign_kmf_id
			var kmf_status: Dictionary = launch_snapshot.get("kmf_status", {}).get(campaign_kmf_id, {})
			_restore_actor_status("friendly_kmf", kmf_status)

func _restore_actor_status(actor_id: String, status: Dictionary) -> void:
	if status.is_empty(): return
	var actor = state.actors.get(actor_id)
	if actor == null: return
	var saved_parts: Dictionary = status.get("parts", {})
	var parts: Dictionary = actor.body.get("parts", {})
	for part_id in saved_parts.keys():
		if parts.has(part_id) and saved_parts[part_id] is Dictionary:
			parts[part_id] = saved_parts[part_id].duplicate(true)
	actor.body["parts"] = parts
	actor.incapacitated = bool(status.get("incapacitated", actor.body.get("incapacitated", false)))
	actor.body["incapacitated"] = actor.incapacitated
	actor.alive = not actor.incapacitated
	var total_hp := 0.0
	var total_max := 0.0
	for part in parts.values():
		total_hp += float(part.get("hp", 0.0))
		total_max += float(part.get("max_hp", 0.0))
	if total_max > 0.0:
		actor.hp = actor.max_hp * clampf(total_hp / total_max, 0.0, 1.0)

func _campaign_role_to_tactical(role: String) -> String:
	var value := role.to_lower()
	if value.contains("scout") or value.contains("recon"): return "Scout"
	if value.contains("medic") or value.contains("medical"): return "Medic"
	if value.contains("repair") or value.contains("maintenance"): return "Repair"
	if value.contains("guard") or value.contains("combat"): return "Guard"
	return "Follow"

func _perception_observer_ids() -> Array[String]:
	var out: Array[String] = []
	if state.actors.has("hero"): out.append("hero")
	for actor in state.actors.values():
		if actor.team != "player" or actor.kind != "human" or actor.id == "hero": continue
		if state.orders.get_role(actor.id) == "Scout": out.append(actor.id)
	if state.actors.has("friendly_kmf"): out.append("friendly_kmf")
	return out

func finalize_campaign_return() -> Dictionary:
	if not has_node("/root/CampaignManager"):
		return {"ok": false, "reason": "campaign_manager_unavailable"}
	if not CampaignManager.has_method("apply_hospital_district_outcome"):
		return {"ok": false, "reason": "campaign_adapter_unavailable"}
	return CampaignManager.apply_hospital_district_outcome(get_outcome_summary())

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE: set_time_scale(0.0 if not auto_pause.paused else 1.0)
			KEY_P: set_time_scale(0.0 if not auto_pause.paused else 1.0)
			KEY_1: set_time_scale(1.0)
			KEY_4: set_time_scale(4.0)
			KEY_8: set_time_scale(8.0)
			KEY_H:
				debug_hud = not debug_hud
				state_changed.emit()
			KEY_Q: set_intent_mode("MOVE")
			KEY_W: set_intent_mode("SCOUT")
			KEY_E: set_intent_mode("CLEAR")
			KEY_R: set_intent_mode("ASSAULT")
			KEY_T: set_intent_mode("FIRE_POSITION")
			KEY_ENTER, KEY_KP_ENTER: confirm_intent()
			KEY_ESCAPE: cancel_intent_draft()
	if event is InputEventMouseButton and event.pressed:
		var world_position := get_global_mouse_position()
		if event.button_index == MOUSE_BUTTON_LEFT:
			_select_nearest(world_position)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			context_target = resolve_context(world_position)
			if str(context_target.get("kind","ground")) == "ground":
				if event.ctrl_pressed:
					set_intent_facing(world_position)
				elif event.shift_pressed:
					add_intent_waypoint(world_position)
				else:
					preview_intent_at(world_position)
			else:
				state.metrics["context_menu_uses"] = int(state.metrics.get("context_menu_uses", 0)) + 1
				context_menu_requested.emit(event.position, get_context_presentations())

func _select_nearest(point: Vector2) -> void:
	var best_id := ""
	var best_distance := 36.0
	for id in state.actors.keys():
		var actor = state.actors[id]
		if actor.team != "player":
			continue
		if actor.kind=="human" and not str(actor.meta.get("inside_kmf","")).is_empty():
			continue
		var distance: float = actor.position.distance_to(point)
		if distance < best_distance:
			best_distance = distance
			best_id = str(id)
	if not best_id.is_empty():
		select_actor(best_id)



func set_intent_mode(value: String) -> Dictionary:
	if not intent_system.is_valid_intent(value):
		return {"ok":false,"reason":"invalid_intent"}
	intent_mode = value
	intent_draft = {"intent":value,"waypoints":[],"facing_point":Vector2.INF}
	_set_feedback("Intent: " + value + " — 地面を右クリックでPreview", state.actors.get(get_controlled_actor_id(state.selected_id)).position if state.actors.has(get_controlled_actor_id(state.selected_id)) else Vector2.ZERO)
	state_changed.emit()
	return {"ok":true,"intent":value}

func preview_intent_at(destination: Vector2) -> Dictionary:
	var actor_id := get_controlled_actor_id(state.selected_id)
	var waypoints: Array = intent_draft.get("waypoints", [])
	var facing_point: Vector2 = intent_draft.get("facing_point", Vector2.INF)
	var preview := intent_system.preview(state, order_system, area_knowledge, equipment_system, actor_id, intent_mode, destination, waypoints, facing_point)
	intent_draft["intent"] = intent_mode
	intent_draft["destination"] = destination
	intent_draft["preview"] = preview
	intent_draft["waypoints"] = waypoints
	intent_draft["facing_point"] = facing_point
	if bool(preview.get("ok", false)):
		_set_feedback("%s Preview  ETA %.1fs  Risk %.0f%%" % [intent_mode, float(preview.get("eta",0.0)), float(preview.get("risk",0.0))*100.0], preview.get("destination",destination))
	else:
		_set_feedback("Preview不可: " + str(preview.get("reason","unknown")), destination)
	state_changed.emit()
	return preview

func add_intent_waypoint(point: Vector2) -> Dictionary:
	var waypoints: Array = intent_draft.get("waypoints", [])
	if waypoints.size() >= 4:
		return {"ok":false,"reason":"waypoint_limit"}
	waypoints.append(point)
	intent_draft["waypoints"] = waypoints
	if intent_draft.has("destination"):
		return preview_intent_at(intent_draft["destination"])
	_set_feedback("Waypoint追加 — 最終地点を右クリック", point)
	state_changed.emit()
	return {"ok":true,"waypoints":waypoints}

func set_intent_facing(point: Vector2) -> Dictionary:
	intent_draft["facing_point"] = point
	if intent_draft.has("destination"):
		return preview_intent_at(intent_draft["destination"])
	return {"ok":false,"reason":"set_destination_first"}

func get_intent_preview() -> Dictionary:
	return intent_draft.get("preview", {}).duplicate(true)

func cancel_intent_draft() -> Dictionary:
	intent_draft = {"intent":intent_mode,"waypoints":[],"facing_point":Vector2.INF}
	_set_feedback("Intent Preview取消", Vector2.ZERO)
	state_changed.emit()
	return {"ok":true}

func immediate_stop(actor_id: String = "") -> Dictionary:
	var actual_id := get_controlled_actor_id(state.selected_id if actor_id.is_empty() else actor_id)
	var result := cancel_move(actual_id)
	active_intents.erase(actual_id)
	return result

func confirm_intent() -> Dictionary:
	var preview: Dictionary = intent_draft.get("preview", {})
	if not bool(preview.get("ok", false)):
		return _record_result({"ok":false,"reason":"no_valid_preview"}, "intent_confirm", Vector2.ZERO)
	var actor_id := str(preview.get("actor_id", get_controlled_actor_id(state.selected_id)))
	var intent := str(preview.get("intent", intent_mode))
	var meta := {
		"intent":intent,
		"area":preview.get("area",Rect2()),
		"checkpoints":preview.get("checkpoints",[]),
		"facing":preview.get("facing",0.0),
		"risk":preview.get("risk",0.0),
		"cover":preview.get("cover",0.0),
		"info_gain":preview.get("info_gain",0.0),
	}
	var result := order_system.issue_intent_move(state, actor_id, preview.get("destination",Vector2.ZERO), intent, intent_draft.get("waypoints",[]), meta)
	if bool(result.get("ok", false)):
		active_intents[actor_id] = meta
		active_intents[actor_id]["intent"] = intent
		active_intents[actor_id]["area_id"] = "%s:%s:%d" % [intent, actor_id, int(state.sim_time * 10.0)]
		preparation_locked = true
		var actor = state.actors.get(actor_id)
		if actor != null:
			actor.meta["facing"] = float(preview.get("facing",actor.meta.get("facing",0.0)))
		intent_draft = {"intent":intent_mode,"waypoints":[],"facing_point":Vector2.INF}
	return _record_result(result, "intent:"+intent, preview.get("destination",Vector2.ZERO))

func _handle_intent_arrival(actor_id: String) -> void:
	if not active_intents.has(actor_id):
		return
	var row: Dictionary = active_intents[actor_id]
	var actor = state.actors.get(actor_id)
	if actor == null:
		active_intents.erase(actor_id)
		return
	actor.meta["facing"] = float(row.get("facing", actor.meta.get("facing",0.0)))
	var intent := str(row.get("intent","MOVE"))
	if intent == "SCOUT":
		area_knowledge.mark_explored(actor.position, 220.0 if actor.kind=="human" else 300.0)
		active_intents.erase(actor_id)
	elif intent == "CLEAR":
		var area: Rect2 = row.get("area", Rect2(actor.position-Vector2(80,60),Vector2(160,120)))
		area_knowledge.mark_explored(area.get_center(), maxf(area.size.x,area.size.y))
		area_knowledge.set_clear_progress(str(row.get("area_id","clear")), area, 1.0, state.sim_time)
		active_intents.erase(actor_id)
	elif intent == "MOVE":
		active_intents.erase(actor_id)

func _tick_intent_exploration() -> void:
	for actor_id in active_intents.keys():
		var row: Dictionary = active_intents[actor_id]
		var actor = state.actors.get(str(actor_id))
		if actor == null:
			continue
		var intent := str(row.get("intent",""))
		if intent == "SCOUT":
			area_knowledge.mark_explored(actor.position, 180.0 if actor.kind=="human" else 260.0)
		elif intent == "CLEAR":
			var area: Rect2 = row.get("area", Rect2())
			area_knowledge.mark_explored(actor.position, 120.0)
			var order: Dictionary = state.orders.peek(str(actor_id))
			var meta: Dictionary = order.get("meta",{})
			var path: Array = meta.get("path",[])
			var progress := 0.0
			if not path.is_empty():
				progress = clampf(float(meta.get("path_index",0)) / float(path.size()), 0.0, 0.95)
			area_knowledge.set_clear_progress(str(row.get("area_id","clear")), area, progress, state.sim_time)

func _tick_intent_combat() -> void:
	for actor_id in active_intents.keys():
		var row: Dictionary = active_intents[actor_id]
		var intent := str(row.get("intent",""))
		if intent not in ["ASSAULT","FIRE_POSITION"]:
			continue
		if intent == "FIRE_POSITION" and str(state.orders.peek(str(actor_id)).get("kind","")) == "move":
			continue
		var actor = state.actors.get(str(actor_id))
		if actor == null or not equipment_system.can_attack(str(actor_id)):
			continue
		for observation in perception.scan(state, str(actor_id)):
			_handle_knowledge_event(observation)
		var best_id := ""
		var best_distance := INF
		for contact in state.knowledge.visible_contacts():
			var enemy_id := str(contact.get("id",""))
			if str(contact.get("status","")) != "confirmed":
				var observe_result: Dictionary = perception.ordered_observe(state, str(actor_id), enemy_id)
				if bool(observe_result.get("ok", false)):
					_handle_knowledge_event(observe_result.get("event", {}))
					contact = state.knowledge.get_contact(enemy_id)
			if str(contact.get("status","")) != "confirmed":
				continue
			var enemy = state.actors.get(enemy_id)
			if enemy == null or enemy.destroyed:
				continue
			var d: float = actor.position.distance_to(enemy.position)
			if d < best_distance and d <= equipment_system.max_range(actor):
				best_distance = d
				best_id = enemy_id
		if not best_id.is_empty():
			attack(str(actor_id), best_id, "auto")

func _configure_equipment_for_party() -> void:
	for actor in state.actors.values():
		if actor.team != "player":
			continue
		var preset := str(preparation_options.get("preset","balanced"))
		if actor.id == "scout" and preset == "balanced":
			preset = "stealth"
		equipment_system.configure_actor(actor, preset)

func apply_preparation(options: Dictionary) -> Dictionary:
	if preparation_locked:
		return {"ok":false,"reason":"preparation_locked"}
	for key in options.keys():
		preparation_options[key] = options[key]
	state.reset(ExpeditionFixture.build())
	if not launch_snapshot.is_empty():
		_apply_campaign_launch_state()
	else:
		if not bool(preparation_options.get("scout",true)):
			state.actors.erase("scout")
			state.orders.roles.erase("scout")
		if not bool(preparation_options.get("medic",true)):
			state.actors.erase("medic")
			state.orders.roles.erase("medic")
		if not bool(preparation_options.get("kmf",true)):
			state.actors.erase("friendly_kmf")
			state.orders.roles.erase("friendly_kmf")
	_rebuild_combat_core()
	area_knowledge.reset()
	sound_system.reset()
	equipment_system.reset()
	active_intents.clear()
	intent_draft = {"intent":intent_mode,"waypoints":[],"facing_point":Vector2.INF}
	_configure_equipment_for_party()
	_set_feedback("出撃準備を反映: " + str(preparation_options.get("preset","balanced")), Vector2(145,680))
	state_changed.emit()
	return {"ok":true,"preparation":preparation_options.duplicate(true)}
