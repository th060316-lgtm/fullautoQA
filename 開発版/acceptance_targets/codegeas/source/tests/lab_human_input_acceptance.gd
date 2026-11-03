extends SceneTree
## Human-input readiness acceptance for Combat & Exploration Lab.
## Verifies the exact keyboard/mouse routes a human playtester uses.

const EXPECTED_CHECKS: int = 14
const InputRouter = preload("res://core/InputRouter.gd")
const LabFixture = preload("res://lab/LabFixture.gd")

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

func _frames(n: int = 2) -> void:
	for _i in range(n):
		await process_frame
		await physics_frame

func _tap(action: String) -> void:
	Input.action_press(action)
	await process_frame
	Input.action_release(action)
	await process_frame

func _run() -> void:
	print("=== LAB HUMAN INPUT ACCEPTANCE ===")
	InputRouter.ensure_actions_registered()
	var packed: PackedScene = load("res://lab/CombatExplorationLab.tscn")
	check("Lab scene loads", packed != null)
	if packed == null:
		_finish()
		return
	lab = packed.instantiate()
	get_root().add_child(lab)
	await _frames(3)

	# E: board/dismount through real Input action.
	lab._player_pos = Vector2(210.0, 480.0)
	await _tap("board_kmf")
	check("E boards the KMF when in range", lab.get_player_mode() == "kmf")
	await _tap("board_kmf")
	check("E dismounts the KMF", lab.get_player_mode() == "foot")

	# P: tactical pause must toggle both directions.
	lab.set_mode("tactical_pause")
	await _frames(1)
	await _tap("lab_pause")
	check("P enters tactical pause", lab.mode.is_planning())
	await _tap("move_up")
	var shots_before_pause_attack: int = int(lab.get_metrics().get("shots_fired", 0))
	await _tap("primary_attack")
	await _tap("lab_pause")
	check("P resumes tactical pause mode", not lab.mode.is_planning())
	check("paused WASD order persists after resume", lab.mode.get_move_direction().y < -0.9)
	check("paused left-click attack fires after resume", int(lab.get_metrics().get("shots_fired", 0)) > shots_before_pause_attack)

	# WEGO must be operable by human keys, not only issue_command() tests.
	lab.set_mode("wego")
	await _frames(1)
	check("WEGO begins in planning", lab.mode.is_planning())
	await _tap("lab_target_cycle")
	check("Q cycles the targeted part", lab.get_locked_part() == "cockpit")
	await _tap("move_right")
	check("WASD queues a WEGO move order", lab.mode.get_move_direction().x > 0.9)
	await _tap("primary_attack")
	check("left click queues a WEGO attack", not lab.mode._queued_shot.is_empty())
	await _tap("lab_plan_confirm")
	check("Enter starts the WEGO resolution phase", not lab.mode.is_planning())

	# Tab / R are the comparison-loop controls used by the human playtest.
	lab.set_mode("realtime")
	await _tap("lab_mode_cycle")
	check("Tab cycles to the next combat mode", lab.get_mode_id() == "tactical_pause")
	lab._player_pos = Vector2(500.0, 500.0)
	await _tap("lab_reset")
	check("R resets the player to the shared fixture", lab.get_player_position().is_equal_approx(LabFixture.PLAYER_START))

	_finish()

func _finish() -> void:
	print("Ran %d / %d; failures=%d" % [passed + failed, EXPECTED_CHECKS, failed])
	if passed == EXPECTED_CHECKS and failed == 0:
		print("ALL CHECKS PASSED")
		quit(0)
	else:
		print("LAB HUMAN INPUT ACCEPTANCE FAILED")
		quit(1)
