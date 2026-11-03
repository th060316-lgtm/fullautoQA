extends SceneTree

const EXPECTED_CHECKS := 40
const Fixture = preload("res://expedition_lab/ExpeditionFixture.gd")
const KnowledgeState = preload("res://expedition_lab/state/KnowledgeState.gd")

var passed := 0
var failed: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("[EXPEDITION PASS] " + label)
	else:
		failed.append(label)
		print("[EXPEDITION FAIL] " + label)

func _run() -> void:
	var packed: PackedScene = load("res://expedition_lab/ExpeditionPrototypeLab.tscn")
	check("Prototype scene boot resource", packed != null)
	if packed == null:
		_finish()
		return
	var lab = packed.instantiate()
	get_root().add_child(lab)
	await process_frame
	await process_frame

	check("Fixture deterministic seed", Fixture.build() == Fixture.build() and lab.state.seed == 20261022)
	var humans := 0
	for actor in lab.state.actors.values():
		if actor.team == "player" and actor.kind == "human":
			humans += 1
	check("Three humans and one friendly KMF", humans == 3 and lab.state.actors.has("friendly_kmf"))
	check("Enemy truth hidden before discovery", lab.state.enemy_truth.size() == 3 and lab.state.knowledge.visible_contacts().is_empty())

	lab.observe_contact("patrol_a", KnowledgeState.SIGNAL, "sound")
	check("Knowledge signal state", str(lab.state.knowledge.get_contact("patrol_a").get("status", "")) == KnowledgeState.SIGNAL)
	lab.observe_contact("patrol_a", KnowledgeState.ESTIMATED, "scout_sensor")
	check("Knowledge estimated state", str(lab.state.knowledge.get_contact("patrol_a").get("status", "")) == KnowledgeState.ESTIMATED)
	lab.observe_contact("patrol_a", KnowledgeState.CONFIRMED, "visual")
	check("Knowledge confirmed triggers AutoPause", lab.auto_pause.paused and int(lab.state.metrics.get("confirmed_contacts", 0)) == 1)
	check("AutoPause reason is visible", not str(lab.get_hud_model().get("auto_pause_reason", "")).is_empty())

	lab.set_time_scale(1.0)
	var move_result: Dictionary = lab.issue_move("hero", Vector2(300, 680))
	for _i in range(30):
		lab.step_simulation(0.1)
	check("Point command path movement", bool(move_result.get("ok", false)) and lab.state.actors["hero"].position.x > 145.0)
	check("Role command assignment", bool(lab.set_role("scout", "Scout").get("ok", false)) and lab.state.orders.get_role("scout") == "Scout")

	lab.state.actors["scout"].position = lab.state.actors["patrol_b"].position + Vector2(80, 0)
	lab.set_time_scale(1.0)
	lab.step_simulation(0.1)
	check("Scout reports without charging", lab.state.knowledge.visible_contacts().size() >= 2 and lab.state.actors["scout"].position.distance_to(lab.state.actors["patrol_b"].position) >= 70.0)

	lab.state.actors["hero"].position = lab.state.actors["friendly_kmf"].position
	var boarded: Dictionary = lab.board_kmf("hero")
	var dismounted: Dictionary = lab.dismount_kmf("hero")
	check("KMF board and dismount", bool(boarded.get("ok", false)) and bool(dismounted.get("ok", false)))

	lab.state.actors["hero"].position = lab.state.actors["patrol_a"].position + Vector2(-100,0)
	lab.observe_contact("patrol_a", KnowledgeState.CONFIRMED, "visual")
	var attack_result: Dictionary = lab.attack("hero", "patrol_a", "left_leg")
	check("Encounter enters combat on same scene", bool(attack_result.get("ok", false)) and lab.state.phase == "combat" and lab.get_parent() == get_root())
	check("Attack passed through CombatCore", lab.core.get_event_log().size() >= 3 and bool(lab.state.metrics.get("combat_started", false)))
	check("Targeted part damage", lab.state.actors["patrol_a"].get_part_hp("left_leg") < 65.0)

	var human_before: Dictionary = lab.issue_move("medic", lab.state.actors["medic"].position + Vector2(100, 0))
	lab.state.orders.pop("medic")
	lab.apply_incoming_damage("medic", "left_leg", 100.0)
	lab.set_time_scale(1.0)
	var human_after: Dictionary = lab.issue_move("medic", lab.state.actors["medic"].position + Vector2(100, 0))
	check("Human leg injury lowers mobility", float(human_after.get("eta", 0.0)) > float(human_before.get("eta", 0.0)))
	lab.state.orders.pop("medic")

	var kmf = lab.state.actors["friendly_kmf"]
	lab.state.actors["hero"].position = kmf.position
	lab.board_kmf("hero")
	var sensor_before: float = lab.perception.sensor_range(kmf)
	lab.apply_incoming_damage("friendly_kmf", "sensor", 100.0)
	lab.set_time_scale(1.0)
	check("KMF sensor damage lowers perception", lab.perception.sensor_range(kmf) < sensor_before)

	var kmf_move_before: Dictionary = lab.issue_move("friendly_kmf", kmf.position + Vector2(100, 0))
	lab.state.orders.pop("friendly_kmf")
	lab.apply_incoming_damage("friendly_kmf", "left_leg", 120.0)
	lab.set_time_scale(1.0)
	var kmf_move_after: Dictionary = lab.issue_move("friendly_kmf", kmf.position + Vector2(100, 0))
	check("KMF leg damage lowers mobility", float(kmf_move_after.get("eta", 0.0)) > float(kmf_move_before.get("eta", 0.0)))
	lab.state.orders.pop("friendly_kmf")

	lab.apply_incoming_damage("friendly_kmf", "weapon", 80.0)
	lab.set_time_scale(1.0)
	lab.observe_contact("hostile_kmf", KnowledgeState.CONFIRMED, "visual")
	check("KMF weapon destruction blocks attack", str(lab.attack("friendly_kmf", "hostile_kmf", "sensor").get("reason", "")) == "weapon_disabled")
	lab.dismount_kmf("hero")

	lab.apply_incoming_damage("scout", "torso", 150.0)
	check("Incapacitation is not instant game over", lab.state.actors["scout"].incapacitated and lab.state.phase != "complete")
	lab.state.actors["hero"].position = lab.state.actors["scout"].position
	var carry_before: Dictionary = lab.issue_move("hero", lab.state.actors["hero"].position + Vector2(100,0))
	lab.state.orders.pop("hero")
	var carry_result: Dictionary = lab.carry("hero", "scout")
	check("Rescue carry state transition", bool(carry_result.get("ok", false)) and str(lab.state.actors["scout"].meta.get("carried_by", "")) == "hero")
	var carry_after: Dictionary = lab.issue_move("hero", lab.state.actors["hero"].position + Vector2(100,0))
	check("Carrying casualty lowers movement speed", float(carry_after.get("eta",0.0)) > float(carry_before.get("eta",0.0)))
	lab.step_simulation(0.25)
	check("Carried casualty follows carrier", lab.state.actors["scout"].position.distance_to(lab.state.actors["hero"].position) < 0.1)
	lab.state.orders.pop("hero")

	lab.state.actors["hero"].position = lab.state.loot["medical_cache"]["position"]
	check("Loot acquisition", bool(lab.collect_loot("hero", "medical_cache").get("ok", false)) and lab.state.acquired_loot.has("medical_cache"))
	check("Retreat order", bool(lab.start_retreat().get("ok", false)) and lab.state.retreat_started)
	lab.set_time_scale(1.0)
	lab.state.actors["hero"].position = Fixture.EXTRACTION_PRIMARY
	lab.state.actors["medic"].position = Fixture.EXTRACTION_PRIMARY
	lab.state.actors["friendly_kmf"].position = Vector2(900, 500)
	var extraction_result: Dictionary = lab.evaluate_extraction(false)
	check("Extraction arrival succeeds", bool(extraction_result.get("retreat_success", false)))
	check("KMF abandonment still allows foot return", bool(extraction_result.get("kmf_abandoned", false)) and lab.state.retreat_success)
	var summary: Dictionary = lab.get_outcome_summary()
	check("Outcome summary is consequence-ready", summary.has("world_consequence") and summary.has("kmf_parts") and summary.has("elapsed_time"))
	check("Outcome records left-behind actors", summary.has("left_behind") and summary.get("left_behind",[]).has("scout"))

	var snapshot_a: Dictionary = lab.deterministic_snapshot()
	lab.reset_prototype()
	var reset_a: Dictionary = lab.deterministic_snapshot()
	lab.reset_prototype()
	var reset_b: Dictionary = lab.deterministic_snapshot()
	check("RNG and fixture remain deterministic", reset_a == reset_b and int(reset_a.get("seed", 0)) == 20261022)
	check("Reset round-trip clears expedition mutations", snapshot_a != reset_a and lab.state.acquired_loot.is_empty() and lab.state.phase == "infiltration")
	check("Combat Lab A-E regression resources preserved", ResourceLoader.exists("res://lab/CombatExplorationLab.tscn") and ResourceLoader.exists("res://tests/open_gameplay_prototype_acceptance.gd"))
	check("Day1 resources preserved", ResourceLoader.exists("res://scenes/Main.tscn") and ResourceLoader.exists("res://tests/day1_acceptance.gd"))
	check("Save/Load regression resources preserved", ResourceLoader.exists("res://save/SaveManager.gd") and ResourceLoader.exists("res://tests/sandbox_foundation_acceptance.gd"))
	check("Context UI is target-specific", lab.context_commands("enemy").has("target_part") and lab.context_commands("ground") == ["move"])

	lab.reset_prototype()
	lab.set_role("scout","HoldFire")
	var scout_start: Vector2 = lab.state.actors["scout"].position
	lab.issue_move("scout", scout_start + Vector2(200,0))
	lab.step_simulation(0.5)
	var scout_distance: float = lab.state.actors["scout"].position.distance_to(scout_start)
	check("Companion movement advances only once per simulation tick", absf(scout_distance - 48.0) < 0.5)

	lab.reset_prototype()
	lab.observe_contact("patrol_a", KnowledgeState.SIGNAL, "sound")
	lab.context_target = {"kind":"enemy","id":"patrol_a","position":lab.state.knowledge.get_contact("patrol_a").get("estimated_position",Vector2.ZERO)}
	var far_observe: Dictionary = lab.execute_context_command("observe")
	check("Ordered observe cannot reveal distant truth", not bool(far_observe.get("ok",false)) and str(lab.state.knowledge.get_contact("patrol_a").get("status","")) == KnowledgeState.SIGNAL)
	lab.state.actors["hero"].position = lab.state.actors["patrol_a"].position + Vector2(60,0)
	var near_observe: Dictionary = lab.execute_context_command("observe")
	check("Ordered observe confirms only within visual range", bool(near_observe.get("ok",false)) and str(lab.state.knowledge.get_contact("patrol_a").get("status","")) == KnowledgeState.CONFIRMED)

	lab.reset_prototype()
	var board_origin: Vector2 = lab.state.actors["friendly_kmf"].position
	lab.state.actors["hero"].position = board_origin
	lab.board_kmf("hero")
	var redirected_move: Dictionary = lab.issue_move("hero", board_origin + Vector2(100,0))
	lab.step_simulation(0.25)
	check("Boarded pilot commands KMF instead of moving independently", str(redirected_move.get("controlled_actor_id","")) == "friendly_kmf" and lab.state.actors["friendly_kmf"].position.x > board_origin.x and lab.state.actors["hero"].position.distance_to(lab.state.actors["friendly_kmf"].position) < 0.1)

	var enemy_commands: Array = lab.context_commands("enemy")
	var loot_commands: Array = lab.context_commands("loot")
	check("Context menu advertises no dead combat or loot commands", not enemy_commands.has("suppress") and not enemy_commands.has("watch") and not enemy_commands.has("avoid") and loot_commands == ["collect"])

	_finish()

func _finish() -> void:
	var ran := passed + failed.size()
	print("Ran %d / %d; failures=%d" % [ran, EXPECTED_CHECKS, failed.size()])
	if ran == EXPECTED_CHECKS and failed.is_empty():
		print("ALL CHECKS PASSED")
		quit(0)
	else:
		print("EXPEDITION PROTOTYPE ACCEPTANCE FAILED")
		quit(1)
