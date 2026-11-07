extends SceneTree

const InputRouter = preload("res://core/InputRouter.gd")
const KnowledgeState = preload("res://expedition_lab/state/KnowledgeState.gd")

const EXPECTED_CHECKS := 27
var passed := 0
var failed: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("[PLAYER FACING PASS] " + label)
	else:
		failed.append(label)
		print("[PLAYER FACING FAIL] " + label)

func _run() -> void:
	check("Tactical profile is registered", InputRouter.get_profiles().has(InputRouter.PROFILE_TACTICAL))
	var labels := InputRouter.get_profile_labels(InputRouter.PROFILE_TACTICAL)
	check("Tactical labels have one shared source", labels.get("select", "") == "左クリック" and labels.get("context", "") == "右クリック")
	var packed: PackedScene = load("res://expedition_lab/ExpeditionPrototypeLab.tscn")
	check("Player-facing expedition scene loads", packed != null)
	if packed == null:
		_finish()
		return
	var lab = packed.instantiate()
	get_root().add_child(lab)
	await process_frame
	await process_frame
	var arena = lab.get_node_or_null("ExpeditionArena")
	var camera = lab.get_node_or_null("ExpeditionCamera")
	var hud = lab.get_node_or_null("ExpeditionHUD")
	check("Authored actor presentation layer exists", arena != null and arena.actor_views.size() == 4)
	var sprite_views := true
	for view in arena.actor_views.values(): sprite_views = sprite_views and view is Sprite2D and view.texture != null
	check("Main actors use authored textures", sprite_views)
	check("KMF and environment assets are loadable", ResourceLoader.exists("res://expedition_lab/assets/kmf/friendly_kmf.svg") and ResourceLoader.exists("res://expedition_lab/assets/environment/hospital.svg"))
	check("Expedition camera adapter is active", camera != null and camera.enabled)
	var hero_roles_disabled := hud != null
	if hud != null:
		for button in hud.role_buttons:
			hero_roles_disabled = hero_roles_disabled and button.disabled
	check("Hero does not expose inert companion role controls", hero_roles_disabled)
	var scout = lab.state.actors["scout"]
	var friendly_for_role = lab.state.actors["friendly_kmf"]
	scout.position = friendly_for_role.position + Vector2(20, 0)
	lab.select_actor("scout")
	hud.refresh()
	lab.context_target = {"kind":"kmf", "id":"friendly_kmf", "position":friendly_for_role.position}
	var repair_role_result: Dictionary = lab.execute_context_command("field_repair")
	var companion_role_control_enabled := false
	for button in hud.role_buttons:
		if not button.disabled: companion_role_control_enabled = true
	check("Any companion can take the Repair role through the KMF context", companion_role_control_enabled and bool(repair_role_result.get("ok", false)) and lab.state.orders.get_role("scout") == "Repair")
	lab.select_actor("hero")
	hud.refresh()

	var start: Vector2 = lab.state.actors["hero"].position
	var move: Dictionary = lab.issue_move("hero", start + Vector2(240, 0))
	check("First valid order timing is recorded", float(lab.state.metrics.get("first_valid_order_time", -1.0)) >= 0.0)
	var after_issue: Vector2 = lab.state.actors["hero"].position
	var route: Dictionary = arena.get_route_view()
	check("Move command does not teleport", bool(move.get("ok", false)) and after_issue == start)
	check("Route exposes destination ETA and progress", route.has("destination") and float(route.get("eta", 0.0)) > 0.0 and route.has("progress"))
	lab.step_simulation(0.2)
	var after_tick: Vector2 = lab.state.actors["hero"].position
	check("Movement is visible over time", after_tick.distance_to(start) > 0.0 and after_tick.distance_to(start) < 240.0)
	check("Camera keeps selected unit in safe view", camera.is_selected_visible())

	lab.reset_prototype()
	lab.observe_contact("patrol_a", KnowledgeState.ESTIMATED, "test")
	await process_frame
	var contact: Dictionary = lab.state.knowledge.get_contact("patrol_a")
	check("Estimated knowledge does not contain exact truth", (contact.get("estimated_position", Vector2.ZERO) as Vector2).distance_to(lab.state.actors["patrol_a"].position) > 1.0)
	check("Contact view consumes knowledge position", arena.contact_views.has("contact:patrol_a") and arena.contact_views["contact:patrol_a"].position == contact.get("estimated_position", Vector2.ZERO))
	lab.context_target = {"kind":"enemy", "id":"patrol_a", "position":contact.get("estimated_position", Vector2.ZERO)}
	var presentations: Array = lab.get_context_presentations()
	var complete_contract := not presentations.is_empty()
	for row in presentations:
		complete_contract = complete_contract and row.has("target_name") and row.has("action_label") and row.has("input") and row.has("distance") and row.has("required_mode") and row.has("blocked") and row.has("reason") and row.has("hint")
	check("Context actions expose the shared presentation contract", complete_contract)
	var attack_blocked := false
	for row in presentations:
		if str(row.get("command", "")) == "attack": attack_blocked = bool(row.get("blocked", false)) and not str(row.get("reason", "")).is_empty()
	check("Unconfirmed attacks explain why they are blocked", attack_blocked)

	lab.reset_prototype()
	var hostile = lab.state.actors["hostile_kmf"]
	lab.state.actors["hero"].position = hostile.position + Vector2(-100, 0)
	lab.observe_contact("hostile_kmf", KnowledgeState.CONFIRMED, "visual")
	lab.set_time_scale(1.0)
	lab.context_target = {"kind":"enemy", "id":"hostile_kmf", "position":hostile.position}
	var choose: Dictionary = lab.execute_context_command("target_part")
	var weapon_before: float = hostile.get_part_hp("weapon")
	var targeted: Dictionary = lab.execute_context_command("target_part:weapon")
	check("Part targeting requires an explicit choice", str(choose.get("reason", "")) == "part_selection_required" and (choose.get("parts", []) as Array).has("weapon"))
	check("Chosen KMF part receives damage", bool(targeted.get("ok", false)) and hostile.get_part_hp("weapon") < weapon_before)
	check("Part-target action is measured", int(lab.state.metrics.get("part_target_actions", 0)) == 1)

	lab.reset_prototype()
	var hero = lab.state.actors["hero"]
	var medic = lab.state.actors["medic"]
	medic.position = hero.position + Vector2(20, 0)
	lab.state.orders.set_role("medic", "Medic")
	lab.state.sim_time = 10.0
	lab.apply_incoming_damage("hero", "left_leg", 10.0, "acceptance")
	var human_part_before: float = hero.get_part_hp("left_leg")
	var human_hp_before: float = float(hero.hp)
	lab.companion_ai.tick(lab.state, lab.order_system, lab.perception, 0.1)
	check("Medic restores localized human part damage", hero.get_part_hp("left_leg") > human_part_before and hero.hp > human_hp_before)

	lab.reset_prototype()
	var repairer = lab.state.actors["medic"]
	var friendly_kmf = lab.state.actors["friendly_kmf"]
	repairer.position = friendly_kmf.position + Vector2(20, 0)
	lab.state.orders.set_role("medic", "Repair")
	lab.state.sim_time = 10.0
	lab.apply_incoming_damage("friendly_kmf", "weapon", 10.0, "acceptance")
	var kmf_part_before: float = friendly_kmf.get_part_hp("weapon")
	var kmf_hp_before: float = float(friendly_kmf.hp)
	lab.companion_ai.tick(lab.state, lab.order_system, lab.perception, 0.1)
	check("Repair restores localized KMF part damage", friendly_kmf.get_part_hp("weapon") > kmf_part_before and friendly_kmf.hp > kmf_hp_before)

	lab.context_target = {"kind":"enemy", "id":"hostile_kmf", "position":hostile.position}
	var enemy_commands: Array = lab.context_commands("enemy")
	check("Enemy context includes non-attack decisions", enemy_commands.has("observe") and enemy_commands.has("reposition") and enemy_commands.has("retreat") and enemy_commands.has("hold_fire"))
	check("Main HUD hides raw confidence by default", hud != null and not hud.debug_label.visible and not hud.intel_label.text.contains("信頼"))
	lab.debug_hud = true
	hud.refresh()
	check("Raw metrics are isolated behind debug toggle", hud.debug_label.visible and hud.debug_label.text.contains("metrics="))
	check("Playable HUD gives objective and next action", not hud.objective_label.text.is_empty() and not hud.feedback_label.text.is_empty())
	_finish()

func _finish() -> void:
	var ran := passed + failed.size()
	print("Ran %d / %d; failures=%d" % [ran, EXPECTED_CHECKS, failed.size()])
	if ran == EXPECTED_CHECKS and failed.is_empty():
		print("PLAYER FACING CHECKS PASSED")
		quit(0)
	else:
		print("PLAYER FACING CHECKS FAILED")
		quit(1)
