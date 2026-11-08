extends Node2D
## Main - 起動エントリ
## EXT-20261019-010: Day1Controller 正式配線 + 初期化追加
## 既存7日構造・Core自己テストは維持

var _debug_tools_enabled: bool = false

## Phase 0.5 Block 1: カメラ政策とインタラクションを独立ノードとして束ねる
var camera_manager: Node = null
var interaction_service: Node = null

func _ready() -> void:
	_debug_tools_enabled = bool(ProjectSettings.get_setting("day1_debug/tools_enabled", false))
	# Seed固定（再現性）
	RngService.set_seed(20261018)
	GameState.get_section("meta")  # ensure init
	var meta = GameState.get_section("meta")
	meta["seed"] = 20261018
	GameState.set_section("meta", meta)
	print("=== GeassDisasterSurvival Core (EXT-20261019-010 Day1 Integration Candidate) ===")
	print("Seed: ", RngService.get_seed())
	print("Day: ", GameState.get_day(), " Time: ", GameState.get_time_string())
	print("操作: WASD移動 / F:インタラクト / E搭乗降機 / Space射撃 / F5 Save / F6 Load / I 情報")

	if has_node("/root/SocialManager"):
		SocialManager.initialize()

	# --- Phase 0.5 Block 1: CameraManager / InteractionService の接続 ---
	camera_manager = get_node_or_null("Player/CameraManager")
	interaction_service = get_node_or_null("InteractionService")
	if camera_manager and camera_manager.has_method("set_hud"):
		camera_manager.set_hud(get_node_or_null("HUD"))
	if camera_manager and camera_manager.has_method("setup"):
		camera_manager.setup(get_node_or_null("Player"), get_node_or_null("Player/Camera2D"), get_node_or_null("MapManager"))

	# --- Day1 正式初期化 ---
	var day1_ctrl = get_node_or_null("Day1Controller")
	if day1_ctrl and day1_ctrl.has_method("initialize_day1"):
		day1_ctrl.initialize_day1()
		print("[Main] Day1Controller.initialize_day1() called")
		# Child _ready() runs before Main._ready(), so refresh the HUD after
		# Day 1 has reached its canonical initialized state.
		var hud = get_node_or_null("HUD")
		if hud and hud.has_method("_refresh"):
			hud.call_deferred("_refresh")
		# 時間進行をDay1へ接続（プレイヤーが知らなくても案件進行）
		if not EventBus.time_advanced.is_connected(_on_time_advanced_day1):
			EventBus.time_advanced.connect(_on_time_advanced_day1)
	else:
		push_error("[Main] Day1Controller not found or missing initialize_day1 — Day1 will not start")
		EventBus.debug_message.emit("ERROR: Day1Controller missing")

	EventBus.debug_message.emit("統合候補起動完了 Seed=" + str(RngService.get_seed()))

func _on_time_advanced_day1(minutes: int) -> void:
	var day1_ctrl = get_node_or_null("Day1Controller")
	if day1_ctrl and day1_ctrl.has_method("on_time_advanced"):
		day1_ctrl.on_time_advanced(minutes)

func _unhandled_input(event: InputEvent) -> void:
	if _debug_tools_enabled and event is InputEventKey and event.pressed:
		if event.keycode == KEY_F9:
			_run_fast_7day()
		if event.keycode == KEY_F8:
			_run_core_tests()
		if event.keycode == KEY_F7 and has_node("/root/DebugHooks"):
			print(DebugHooks.run_qa_tests())
		if event.keycode == KEY_F10:
			_open_combat_lab()
		# F interact は InputMap "interact" 経由で Player / Day1Controller 側で処理する想定
		# ここでの直接 KEY_F 処理は行わない（InputMap 統一）

## Phase 0.5: Combat & Exploration Lab を別シーンで開く (debug のみ)。
## Lab は Day1 の GameState を触らないため、戻れば Day1 はそのまま継続する。
func _open_combat_lab() -> void:
	if not _debug_tools_enabled:
		return
	var lab_path := "res://lab/CombatExplorationLab.tscn"
	if not ResourceLoader.exists(lab_path):
		push_warning("[Main] Combat Lab scene not found: " + lab_path)
		return
	get_tree().change_scene_to_file(lab_path)
	print("[Main] Combat & Exploration Lab を起動しました (F10 で再開は R キー etc.)")

func _run_fast_7day() -> void:
	print("--- 7日高速完走テスト開始 ---")
	var start_day = GameState.get_day()
	while GameState.get_day() < 7:
		GameState.advance_time(60)  # 1時間ずつ
	print("到達: ", GameState.get_time_string())
	EventBus.debug_message.emit("7日到達テスト完了")
	print("--- 7日高速完走テスト終了 ---")

func _run_core_tests() -> void:
	print("--- Core自己テスト開始 ---")
	var passed = 0
	var failed = 0

	# 1. 徒歩/KMF同時成立禁止
	GameState.set_player_mode("foot")
	GameState.set_player_mode("kmf")
	var mode = GameState.get_player_mode()
	var boarded = GameState.get_section("kmf").get("boarded", false)
	if mode == "kmf" and boarded:
		print("[PASS] mode/boarded consistent")
		passed += 1
	else:
		print("[FAIL] mode inconsistency")
		failed += 1
	GameState.set_player_mode("foot")
	if GameState.get_player_mode() == "foot" and not GameState.get_section("kmf").get("boarded", true):
		print("[PASS] disembark consistent")
		passed += 1
	else:
		print("[FAIL] disembark")
		failed += 1

	# 2. 時刻逆行禁止（advanceは正のみ）
	var before = GameState.get_minute_of_day() + GameState.get_day() * 1440
	GameState.advance_time(-10)
	var after = GameState.get_minute_of_day() + GameState.get_day() * 1440
	if after >= before:
		print("[PASS] no time reverse")
		passed += 1
	else:
		print("[FAIL] time reversed")
		failed += 1

	# 3. day境界
	while GameState.get_day() < 7:
		GameState.advance_time(120)
	if GameState.get_day() == 7:
		print("[PASS] day 7 boundary")
		passed += 1
	else:
		print("[FAIL] day boundary")
		failed += 1

	# 4. KMF境界
	var kmf = GameState.get_section("kmf")
	kmf["energy"] = 0
	kmf["ammo"] = 0
	kmf["durability"] = 0
	GameState.set_section("kmf", kmf)
	GameState.damage_kmf(10)  # already 0
	if float(GameState.get_section("kmf").get("durability", -1)) == 0:
		print("[PASS] kmf durability floor")
		passed += 1
	else:
		print("[FAIL] kmf durability")
		failed += 1

	# 5. Save/Load
	var sm = $SaveManager
	if sm and sm.test_round_trip():
		print("[PASS] Save/Load round-trip")
		passed += 1
	else:
		print("[FAIL] Save/Load")
		failed += 1

	# 6. Seed再現
	var s1 = RngService.randi_range_seeded(0, 1000)
	RngService.set_seed(20261018)
	var s2 = RngService.randi_range_seeded(0, 1000)
	RngService.set_seed(20261018)
	var s3 = RngService.randi_range_seeded(0, 1000)
	if s2 == s3:
		print("[PASS] Seed reproducibility")
		passed += 1
	else:
		print("[FAIL] Seed")
		failed += 1

	# 7. 好感度-100即死しない
	var h = GameState.get_section("heroine")
	h["affection"] = -100
	GameState.set_section("heroine", h)
	if GameState.is_player_alive():
		print("[PASS] affection -100 not instant GO")
		passed += 1
	else:
		print("[FAIL] affection -100 killed player")
		failed += 1

	print("--- 結果: PASS=%d FAIL=%d ---" % [passed, failed])
	EventBus.debug_message.emit("Tests PASS=%d FAIL=%d" % [passed, failed])
	# 結果ファイル出力
	var f = FileAccess.open("user://TEST_RESULTS_GROK.txt", FileAccess.WRITE)
	if f:
		f.store_string("EXT-20261019-010 Grok Day1 Integration Candidate Self-Test\n")
		f.store_string("PASS=%d FAIL=%d\n" % [passed, failed])
		f.store_string("Timestamp: %s\n" % Time.get_datetime_string_from_system())
		f.close()


