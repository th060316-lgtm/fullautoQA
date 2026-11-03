extends SceneTree
## Acceptance for the two post-playtest open gameplay prototypes.
## D = destination/target command + pause.
## E = compressed decision points.
## Both must share the existing fixture and CombatCore without choosing a winner.

const EXPECTED_CHECKS: int = 27
const LabMetrics = preload("res://lab/LabMetrics.gd")

var passed: int = 0
var failed: int = 0
var lab: Node = null

func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("[PASS] " + label)
	else:
		failed += 1
		print("[FAIL] " + label)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== OPEN GAMEPLAY PROTOTYPE ACCEPTANCE ===")
	var packed: PackedScene = load("res://lab/CombatExplorationLab.tscn")
	check("Lab scene loads", packed != null)
	if packed == null:
		_finish()
		return
	lab = packed.instantiate()
	get_root().add_child(lab)
	await process_frame
	await process_frame
	lab.set_manual_step(true)

	var modes: Array = lab.get_available_modes()
	check("five modes are exposed", modes.size() == 5)
	check("command-pause prototype is available", modes.has("command_pause"))
	check("decision-point prototype is available", modes.has("decision_point"))

	var core_script: Script = lab.core.get_script()

	# D: visible destination command, automatic path movement, target-designated shooting.
	check("D can be activated", lab.set_mode("command_pause") and lab.get_mode_id() == "command_pause")
	var move_result: Dictionary = lab.handle_world_click(Vector2(520.0, 300.0))
	check("D accepts an empty-map destination click", bool(move_result.get("ok", false)))
	check("D stores an active destination/path", lab.has_command_destination())
	check("D derives movement from the path", lab.get_command_move_direction().length() > 0.9)
	var enemy_id: String = lab.find_enemy_at(Vector2(720.0, 360.0))
	check("D can identify the enemy under a world click", enemy_id == "enemy_a")
	var shot_before: int = int(lab.get_metrics().get("shots_fired", 0))
	var attack_result: Dictionary = lab.handle_world_click(Vector2(720.0, 360.0))
	check("D accepts enemy click as target-designated attack", bool(attack_result.get("ok", false)))
	lab.step_fixed(1.0 / 60.0)
	check("D fires from target designation without manual aim", int(lab.get_metrics().get("shots_fired", 0)) > shot_before)

	var pause_result: Dictionary = lab.issue_command("pause", {})
	check("D can enter pause", bool(pause_result.get("ok", false)) and lab.mode.is_planning())
	var clock_before: float = float(lab.get_metrics().get("combat_time", 0.0))
	lab.step_fixed(0.5)
	check("D pause freezes simulation combat time", is_equal_approx(float(lab.get_metrics().get("combat_time", 0.0)), clock_before))
	var resume_result: Dictionary = lab.issue_command("resume", {})
	check("D can resume", bool(resume_result.get("ok", false)) and not lab.mode.is_planning())

	# E: select a decision, see it, confirm it, and resolve deterministic costs/results.
	check("E can be activated and starts in decision planning",
		lab.set_mode("decision_point") and lab.get_mode_id() == "decision_point" and lab.mode.is_planning())
	check("E exposes five explicit decision points", lab.get_decision_nodes_view().size() == 5)
	var choose_result: Dictionary = lab.handle_world_click(Vector2(500.0, 300.0))
	check("E accepts clicking a decision point", bool(choose_result.get("ok", false)))
	var selected_found: bool = false
	for node in lab.get_decision_nodes_view():
		if node is Dictionary and str((node as Dictionary).get("id", "")) == "north_cover":
			selected_found = bool((node as Dictionary).get("selected", false))
	check("E marks the selected decision before commitment", selected_found)
	var resolve_result: Dictionary = lab.issue_command("plan_confirm", {})
	check("E confirms and resolves the selected decision", bool(resolve_result.get("ok", false)))
	check("E advances compressed simulation time by the decision cost",
		float(lab.get_metrics().get("combat_time", 0.0)) >= 18.0)
	check("E moves state to the resolved section", lab.get_player_position().distance_to(Vector2(500.0, 300.0)) < 0.1)
	var decision_state: Dictionary = lab.get_decision_state()
	check("E applies information/resource consequences",
		int(decision_state.get("intel", 0)) == 1 and (decision_state.get("history", []) as Array).size() == 1)

	var pick_extract: Dictionary = lab.issue_command("decision_select", {"node_id": "extract"})
	check("E can choose retreat as a decision", bool(pick_extract.get("ok", false)))
	var do_extract: Dictionary = lab.issue_command("plan_confirm", {})
	check("E can commit the retreat decision", bool(do_extract.get("ok", false)))
	var end_metrics: Dictionary = lab.get_metrics()
	check("E records retreat success", bool(end_metrics.get("retreat_success", false)))
	check("E ends with extracted outcome", str(end_metrics.get("outcome", "")) == LabMetrics.OUTCOME_EXTRACTED)

	check("D/E still use the same CombatCore class", lab.core.get_script() == core_script)
	_finish()

func _finish() -> void:
	print("Ran %d / %d; failures=%d" % [passed + failed, EXPECTED_CHECKS, failed])
	if passed == EXPECTED_CHECKS and failed == 0:
		print("ALL CHECKS PASSED")
		quit(0)
	else:
		print("OPEN GAMEPLAY PROTOTYPE ACCEPTANCE FAILED")
		quit(1)
