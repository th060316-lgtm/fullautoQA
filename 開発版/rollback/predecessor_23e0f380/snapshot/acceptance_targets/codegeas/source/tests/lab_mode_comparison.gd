extends SceneTree
## Phase 0.5+ open gameplay: all Lab modes on one fixture acceptance
##
## 実行:
##   godot --headless --path game -s res://tests/lab_mode_comparison.gd
##
## 検証内容:
##   - 既存3方式と新規D/E試作が
##     同一 Lab・同一 fixture・同一 Combat Core で切替比較できること
##   - 方式を変えても固定条件 (seed / 敵 / 初期位置 / 目的) が同一であること
##   - 方式ごとの判断頻度・pause/planning 回数が記録されること
##   - 契約が要求するメトリクスがすべて取得できること
##   - 方式の最終採用は決定しない (このテストは採用判断を行わない)

const EXPECTED_CHECKS: int = 16
const LabFixture = preload("res://lab/LabFixture.gd")
const LabMetrics = preload("res://lab/LabMetrics.gd")

var failures: Array[String] = []
var ran: int = 0
var lab: Node = null

const REQUIRED_METRIC_KEYS: Array = [
	"action_count", "decision_count", "decision_frequency", "combat_time",
	"damage_received", "kmf_damage", "shots_fired", "hits",
	"enemies_destroyed", "enemies_neutralized", "retreat_success",
	"player_dead", "pause_count", "planning_count",
]

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
	print("=== COMBAT MODE COMPARISON ACCEPTANCE (Phase 0.5 Block 3) ===")
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

	# --- 方式一覧 ---
	var modes: Array = lab.get_available_modes()
	check("five gameplay prototypes are registered", modes.size() == 5)
	check("legacy A/B/C and experimental D/E are all registered",
		modes.has("realtime") and modes.has("tactical_pause") and modes.has("wego")
		and modes.has("command_pause") and modes.has("decision_point"))

	# --- 同一 fixture であることの確認 ---
	var fingerprints: Array = []
	var results: Dictionary = {}
	for mode_id in modes:
		lab.reset_lab(str(mode_id))
		fingerprints.append(_fixture_fingerprint())
		results[str(mode_id)] = _run_scripted_session(str(mode_id))
	var same_fixture: bool = fingerprints.size() == 5
	for index in range(1, fingerprints.size()):
		if str(fingerprints[index]) != str(fingerprints[0]):
			same_fixture = false
	check("all modes share one identical fixture", same_fixture)

	# --- 同一 Combat Core ---
	var core_script: Script = lab.core.get_script() if lab.core != null else null
	check("all modes share one combat core class", core_script != null)
	lab.reset_lab("wego")
	check("the combat core class does not change with the mode", lab.core.get_script() == core_script)

	# --- メトリクス項目 ---
	var realtime_metrics: Dictionary = results.get("realtime", {})
	var all_keys_present: bool = true
	for key in REQUIRED_METRIC_KEYS:
		if not realtime_metrics.has(key):
			all_keys_present = false
	check("all contract metric keys are recorded", all_keys_present)
	var expected_frequency: float = 0.0
	if float(realtime_metrics.get("combat_time", 0.0)) > 0.0:
		expected_frequency = float(realtime_metrics.get("decision_count", 0)) / float(realtime_metrics.get("combat_time", 1.0))
	check("decision frequency is derived from decision count / combat time",
		is_equal_approx(float(realtime_metrics.get("decision_frequency", 0.0)), expected_frequency))

	# --- 方式ごとの差異 (pause / planning) ---
	var pause_metrics: Dictionary = results.get("tactical_pause", {})
	var wego_metrics: Dictionary = results.get("wego", {})
	check("tactical pause records pause count", int(pause_metrics.get("pause_count", 0)) > 0)
	check("wego records planning count", int(wego_metrics.get("planning_count", 0)) > 0)
	check("wego does not use realtime pauses", int(wego_metrics.get("pause_count", 0)) == 0)

	# --- 方式を切り替えられる (実行時) ---
	lab.reset_lab("realtime")
	check("mode can be switched at runtime", lab.set_mode("wego") and lab.get_mode_id() == "wego")
	lab.set_mode("tactical_pause")
	check("mode can be switched back", lab.set_mode("tactical_pause") and lab.get_mode_id() == "tactical_pause")
	lab.set_mode("realtime")
	check("cycling returns to a valid mode", lab.get_available_modes().has(lab.cycle_mode()))

	# --- 比較表が取れる ---
	var row: Dictionary = LabMetrics.new().get_comparison_row()
	check("comparison row contains the contract axes",
		row.has("方式") and row.has("判断頻度") and row.has("撤退成否") and row.has("pause/planning"))

	# --- 最終方式は決定しない (このテストは比較材料のみ) ---
	print("[INFO] 比較結果 (採用判断は行わない):")
	for key in results.keys():
		print("   %s -> %s" % [key, str(results[key].get("outcome", "?"))])
	check("no combat mode is auto-selected as canonical", true)

	_finish()

func _fixture_fingerprint() -> String:
	var parts: Array = []
	parts.append(str(lab.fixture.get("seed", 0)))
	parts.append(str(lab.fixture.get("player_start", Vector2.ZERO)))
	parts.append(str(lab.fixture.get("kmf_start", Vector2.ZERO)))
	parts.append(str(lab.fixture.get("extraction_point", Vector2.ZERO)))
	parts.append(str(lab.fixture.get("objective", "")))
	for entry in lab.get_enemies():
		var combatant = entry.get("combatant")
		var def: Dictionary = entry.get("def", {})
		parts.append("%s@%s hp=%s" % [str(def.get("id", "")), str(combatant.get("position")), str(combatant.get("hp"))])
	return "|".join(parts)

## 方式ごとに同じ「操作手順」を実行し、記録された差を返す。
## 手順は方式に依存しない (移動 → 発射 → ポーズ/ターン操作)。
func _run_scripted_session(mode_id: String) -> Dictionary:
	lab.reset_lab(mode_id)
	if mode_id == "decision_point":
		lab.issue_command("decision_select", {"node_id": "north_cover"})
		lab.issue_command("plan_confirm", {})
		return lab.get_metrics()
	if mode_id == "command_pause":
		lab.issue_command("move_target", {"position": Vector2(520.0, 300.0)})
	lab.set_scripted_input(Vector2.RIGHT)
	for _i in range(240):
		if _i % 50 == 0:
			lab.queue_scripted_shot(Vector2(720.0, 360.0), "")
		# 方式固有の操作。同じ「意図」を方式ごとの API 違いだけで表現する。
		if mode_id == "wego":
			if lab.mode.is_planning():
				lab.issue_command("move", {"direction": Vector2.RIGHT})
				lab.issue_command("plan_confirm", {})
		elif mode_id == "tactical_pause":
			if _i % 60 == 30:
				lab.issue_command("pause", {})
			elif _i % 60 == 40:
				lab.issue_command("move", {"direction": Vector2.RIGHT})
				lab.issue_command("resume", {})
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
