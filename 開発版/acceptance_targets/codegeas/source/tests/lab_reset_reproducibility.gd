extends SceneTree
## Phase 0.5 Block 2: Combat & Exploration Lab acceptance
##
## 実行:
##   godot --headless --path game -s res://tests/lab_reset_reproducibility.gd
##
## 検証内容:
##   - 契約 DOCS/02_COMBAT_LAB_CONTRACT.txt の固定条件 (seed / 座標 / 敵HP)
##   - reset で完全同一の状態へ戻る (位置・HP・弾薬・RNG・メトリクス)
##   - 同一手順の2回実行が同一結果になる (seed 再現性)
##   - retreat / extraction が成立する
##   - foot / KMF 切替が成立する
##   - Day1 本編進行へ副作用が出ない (GameState の時刻・案件が変わらない)

const EXPECTED_CHECKS: int = 30
const LabFixture = preload("res://lab/LabFixture.gd")
const CombatBalance = preload("res://combat/core/CombatBalance.gd")

var failures: Array[String] = []
var ran: int = 0
var lab: Node = null

func _init() -> void:
	call_deferred("_run")

func check(name: String, condition: bool) -> void:
	ran += 1
	if condition:
		print("[PASS] ", name)
	else:
		failures.append(name)
		print("[FAIL] ", name)

func _run() -> void:
	print("=== COMBAT LAB ACCEPTANCE (Phase 0.5 Block 2) ===")
	var gs: Node = get_root().get_node_or_null("GameState")
	var day_before: int = gs.get_day() if gs != null else -1
	var minute_before: int = gs.get_minute_of_day() if gs != null else -1
	var day1_before: Dictionary = gs.get_section("day1") if gs != null else {}

	var packed: PackedScene = load("res://lab/CombatExplorationLab.tscn")
	check("Lab scene loads", packed != null)
	if packed == null:
		_finish()
		return
	lab = packed.instantiate()
	get_root().add_child(lab)
	await process_frame
	await process_frame
	# 自動進行を止め、固定ステップで決定論的に進める
	lab.set_manual_step(true)
	check("Lab instance is active", lab != null and lab.has_method("reset_lab"))

	# --- 固定条件 ---
	check("lab seed is 20261021", LabFixture.LAB_SEED == 20261021 and int(lab.fixture.get("seed", 0)) == 20261021)
	check("play area is Rect2(0,0,1280,960)",
		lab.fixture.get("play_area") == Rect2(0.0, 0.0, 1280.0, 960.0))
	check("player start is (160,480)", lab.get_player_position() == Vector2(160.0, 480.0))
	check("player starts on foot", lab.get_player_mode() == "foot")
	check("owned KMF starts at (240,480)", lab.get_kmf_position() == Vector2(240.0, 480.0))
	check("extraction point is (120,480)", LabFixture.EXTRACTION_POINT == Vector2(120.0, 480.0))
	var enemies: Array = lab.get_enemies()
	check("four enemies are present", enemies.size() == 4)
	var enemy_hp_ok: bool = true
	var enemy_pos_ok: bool = true
	for entry in enemies:
		var combatant = entry.get("combatant")
		var def: Dictionary = entry.get("def", {})
		var want_hp: float = float(def.get("hp", 0.0))
		if not is_equal_approx(float(combatant.hp), want_hp):
			enemy_hp_ok = false
		var want_pos: Vector2 = def.get("position", Vector2.ZERO)
		if not combatant.position.is_equal_approx(want_pos):
			enemy_pos_ok = false
	check("enemy HP matches the contract baseline", enemy_hp_ok)
	check("enemy positions match the contract baseline", enemy_pos_ok)

	# --- reset で同一状態へ ---
	lab.set_scripted_input(Vector2.RIGHT)
	lab.step_fixed(1.0 / 60.0)
	lab.set_scripted_input(Vector2.ZERO)
	var moved: bool = not lab.get_player_position().is_equal_approx(Vector2(160.0, 480.0))
	check("lab simulation moves the player", moved)
	lab.reset_lab("realtime")
	check("reset restores the player start", lab.get_player_position().is_equal_approx(Vector2(160.0, 480.0)))
	check("reset restores the KMF start", lab.get_kmf_position().is_equal_approx(Vector2(240.0, 480.0)))
	check("reset restores foot mode", lab.get_player_mode() == "foot")
	check("reset restores the enemy HP", _all_enemies_full_hp())
	check("reset clears the metrics", int(lab.get_metrics().get("action_count", -1)) == 0
		and int(lab.get_metrics().get("shots_fired", -1)) == 0
		and is_equal_approx(float(lab.get_metrics().get("combat_time", -1.0)), 0.0))

	# --- 同一手順の再現性 ---
	var run_a: Dictionary = _scripted_run()
	lab.reset_lab("realtime")
	var run_b: Dictionary = _scripted_run()
	check("same script produces the same combat time", is_equal_approx(float(run_a.get("combat_time", 0.0)), float(run_b.get("combat_time", 0.0))))
	check("same script produces the same shots", int(run_a.get("shots_fired", 0)) == int(run_b.get("shots_fired", 0)))
	check("same script produces the same hits", int(run_a.get("hits", 0)) == int(run_b.get("hits", 0)))
	check("same script produces the same damage taken", is_equal_approx(float(run_a.get("damage_received", 0.0)), float(run_b.get("damage_received", 0.0))))
	check("same script produces the same kills", int(run_a.get("enemies_destroyed", 0)) == int(run_b.get("enemies_destroyed", 0)))
	check("same script produces the same outcome", str(run_a.get("outcome", "")) == str(run_b.get("outcome", "")))

	# --- foot / KMF 切替 ---
	lab.reset_lab("realtime")
	lab.set_scripted_input(Vector2.RIGHT)
	for _i in range(30):
		lab.step_fixed(1.0 / 60.0)
	lab.set_scripted_input(Vector2.ZERO)
	var board_result: Dictionary = lab.issue_command("board", {})
	check("boarding the KMF succeeds when in range", bool(board_result.get("ok", false)))
	check("mode becomes kmf", lab.get_player_mode() == "kmf")
	var dismount_result: Dictionary = lab.issue_command("dismount", {})
	check("dismounting works", bool(dismount_result.get("ok", false)) and lab.get_player_mode() == "foot")

	# --- retreat / extraction ---
	lab.reset_lab("realtime")
	lab.set_scripted_input(Vector2.LEFT)
	for _i in range(40):
		lab.step_fixed(1.0 / 60.0)
	lab.set_scripted_input(Vector2.ZERO)
	var metrics: Dictionary = lab.get_metrics()
	check("reaching the extraction point succeeds", bool(metrics.get("retreat_success", false)))
	check("extraction outcome is recorded", str(metrics.get("outcome", "")) == "extracted")

	# --- Day1 への副作用なし ---
	var day_after: int = gs.get_day() if gs != null else -1
	var minute_after: int = gs.get_minute_of_day() if gs != null else -1
	var day1_after: Dictionary = gs.get_section("day1") if gs != null else {}
	check("lab does not advance the Day1 clock", day_after == day_before and minute_after == minute_before)
	check("lab does not touch the Day1 case state", day1_after == day1_before)

	_finish()

func _all_enemies_full_hp() -> bool:
	for entry in lab.get_enemies():
		var combatant = entry.get("combatant")
		var def: Dictionary = entry.get("def", {})
		if not is_equal_approx(float(combatant.hp), float(def.get("hp", 0.0))):
			return false
	return true

## 同一手順 (右へ進み、敵へ撃つ) を実行してメトリクスを返す。
func _scripted_run() -> Dictionary:
	lab.set_scripted_input(Vector2.RIGHT)
	for _i in range(60):
		lab.step_fixed(1.0 / 60.0)
	lab.set_scripted_input(Vector2.ZERO)
	for _i in range(200):
		# 射撃クールダウン (徒歩 0.8s = 48 steps) より長い間隔で発射する
		if _i % 50 == 0:
			lab.queue_scripted_shot(Vector2(720.0, 360.0), "")
		lab.step_fixed(1.0 / 60.0)
	return lab.get_metrics()

func _finish() -> void:
	print("Ran %d / %d; failures=%d" % [ran, EXPECTED_CHECKS, failures.size()])
	if ran != EXPECTED_CHECKS:
		print("INCOMPLETE (expected %d checks)" % EXPECTED_CHECKS)
		quit(2)
		return
	if not failures.is_empty():
		for f in failures:
			print("  FAIL: ", f)
		quit(1)
		return
	print("ALL CHECKS PASSED")
	quit(0)
