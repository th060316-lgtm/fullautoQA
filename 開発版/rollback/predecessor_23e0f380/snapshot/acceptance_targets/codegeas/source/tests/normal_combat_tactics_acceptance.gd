extends SceneTree
## Phase 0.5 Blocks 6-7 acceptance for the normal (non-Lab) combat path.

const EXPECTED_CHECKS: int = 11
var passed: int = 0
var failed: int = 0
var current_main: Node = null

func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("[PASS] " + label)
	else:
		failed += 1
		print("[FAIL] " + label)

func _init() -> void:
	call_deferred("_run")

func _frames(n: int = 2) -> void:
	for _i in range(n):
		await process_frame
		await physics_frame

func _fresh() -> Dictionary:
	if current_main != null and is_instance_valid(current_main):
		current_main.queue_free()
		await _frames(2)
	var gs := get_root().get_node_or_null("GameState")
	if gs != null and gs.has_method("_init_default_state"):
		gs._init_default_state()
	var packed: PackedScene = load("res://scenes/Main.tscn")
	current_main = packed.instantiate()
	get_root().add_child(current_main)
	await _frames(4)
	return {"main": current_main, "gs": gs}

func _find_enemy(combat: Node, enemy_type: String) -> Node:
	for child in combat.get_children():
		if child.has_meta("type") and str(child.get_meta("type")) == enemy_type:
			return child
	return null

func _run() -> void:
	print("=== NORMAL COMBAT TACTICS ACCEPTANCE ===")
	var r := await _fresh()
	var main: Node = r.main
	var gs: Node = r.gs
	var combat: Node = main.get_node("CombatManager")
	var player: Node2D = main.get_node("Player")
	var core = combat.get_combat_core()

	check("normal CombatManager exposes shared CombatCore", core != null)
	check("normal combat starts with four registered world enemies", combat.get_enemy_count() == 4 and core.get_team("enemy").size() == 4)

	var kmf: Node = _find_enemy(combat, "enemy_kmf")
	var infantry: Node = _find_enemy(combat, "infantry")
	check("world enemies are linked to Combatants", kmf != null and infantry != null and combat.get_enemy_combatant(kmf) != null and combat.get_enemy_combatant(infantry) != null)

	# Block 6: normal-world part damage, aggregate HP sync and mechanical effect.
	var hp_before: float = float(kmf.get_meta("hp", 0.0)) if kmf != null else -1.0
	var part_result: Dictionary = combat.apply_enemy_part_damage(kmf, "left_leg", 100.0, kmf.global_position) if kmf != null else {}
	var kmf_combatant = combat.get_enemy_combatant(kmf) if kmf != null and is_instance_valid(kmf) else null
	check("normal-world KMF part damage routes through CombatCore", bool(part_result.get("ok", false)) and str(part_result.get("part_id", "")) == "left_leg" and bool(part_result.get("part_destroyed", false)))
	check("aggregate HP remains synchronized after part damage", kmf != null and is_instance_valid(kmf) and is_equal_approx(float(kmf.get_meta("hp", -1.0)), hp_before - float(part_result.get("damage", 0.0))))
	check("one destroyed leg mechanically reduces mobility", kmf_combatant != null and is_equal_approx(float(kmf_combatant.get_effects().get("mobility_multiplier", 1.0)), 0.6))
	check("part destruction produces normal-world feedback", combat.get_feedback_history().any(func(f): return str(f.get("kind", "")) == "part_destroyed"))

	# Block 7: damaged KMF receives the shared AI event and retreats in the live normal loop.
	if kmf != null and is_instance_valid(kmf):
		gs.set_player_location("industrial_area")
		var home: Vector2 = kmf.get_meta("home_position", kmf.global_position)
		player.global_position = home + Vector2(-70, 0)
		gs.set_player_position(player.global_position)
		kmf.global_position = home
		var before_retreat: float = kmf.global_position.distance_to(player.global_position)
		combat._update_enemies(0.25)
		var after_retreat: float = kmf.global_position.distance_to(player.global_position)
		check("normal-world damaged AI performs retreat movement", str(kmf.get_meta("last_ai_action", "")) == "retreat" and after_retreat > before_retreat)
	else:
		check("normal-world damaged AI performs retreat movement", false)

	# Fresh infantry, close range -> flank; this must be mechanical movement, not a label only.
	if infantry != null and is_instance_valid(infantry):
		gs.set_player_location("industrial_area")
		var ihome: Vector2 = infantry.get_meta("home_position", infantry.global_position)
		player.global_position = ihome + Vector2(-8, 0)
		gs.set_player_position(player.global_position)
		infantry.global_position = ihome
		var before_flank: Vector2 = infantry.global_position
		combat._update_enemies(0.25)
		var moved: Vector2 = infantry.global_position - before_flank
		check("normal-world AI performs flank movement", str(infantry.get_meta("last_ai_action", "")) == "flank" and absf(moved.y) > absf(moved.x))
	else:
		check("normal-world AI performs flank movement", false)

	var counts: Dictionary = combat.get_ai_tactical_counts()
	check("normal-world non-shooting tactics are counted", int(counts.get("retreat", 0)) >= 1 and int(counts.get("flank", 0)) >= 1)
	check("shared CombatCore logs AI tactic events", core.get_event_log().any(func(e): return str(e.get("kind", "")) == "ai_tactic"))

	print("Ran %d / %d; failures=%d" % [passed + failed, EXPECTED_CHECKS, failed])
	if passed == EXPECTED_CHECKS and failed == 0:
		print("ALL CHECKS PASSED")
		quit(0)
	else:
		print("NORMAL COMBAT TACTICS ACCEPTANCE FAILED")
		quit(1)
