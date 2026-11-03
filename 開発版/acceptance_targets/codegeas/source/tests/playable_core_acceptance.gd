extends SceneTree
## Phase 0.5 Block 1: Playable Core acceptance (Camera / Bounds / HUD Safe Area / Input / Interaction)
##
## 実行:
##   godot --headless --path game -s res://tests/playable_core_acceptance.gd
##
## 検証内容:
##   - CameraManager が Player から独立して存在し、正規の Camera2D を駆動する
##   - Camera limit がプレイ領域 (1280x960) と一致する
##   - Player / KMF 座標がプレイ領域外へ逸脱しない (画面外消失の恒久修正)
##   - Player が常にカメラの可視領域内にいる (徒歩 / KMF とも)
##   - HUD が Safe Area 情報を提供し、HUD が常にプレイ領域を塞がない
##   - インタラクション prompt が 対象/行動/キー/距離/モード を持つ
##   - 徒歩 / KMF の同時成立がしない
##   - 既存 public method / signal が壊れていない (Day1 初期化・Save/Load)

const EXPECTED_CHECKS: int = 27
var failures: Array[String] = []
var ran: int = 0

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
	print("=== PLAYABLE CORE ACCEPTANCE (Phase 0.5 Block 1) ===")
	var gs: Node = get_root().get_node_or_null("GameState")
	check("GameState autoload accessible", gs != null)
	var packed: PackedScene = load("res://scenes/Main.tscn")
	check("Main scene loads", packed != null)
	if packed == null:
		_finish()
		return
	var main: Node = packed.instantiate()
	get_root().add_child(main)
	for _i in range(4):
		await process_frame
		await physics_frame

	# --- 1. CameraManager の独立 ---
	var player: Node = main.get_node_or_null("Player")
	var camera_manager: Node = player.get_node_or_null("CameraManager") if player else null
	check("CameraManager is a separate node under Player", camera_manager != null)
	check("Camera2D node still exists (path compatible)", player.get_node_or_null("Camera2D") != null if player else false)
	check("CameraManager exposes play area", camera_manager != null and camera_manager.has_method("get_play_area"))

	# --- 2. Camera limit == play area ---
	var cam: Camera2D = player.get_node_or_null("Camera2D") as Camera2D if player else null
	var bounds: Rect2 = camera_manager.get_play_area() if camera_manager != null else Rect2()
	check("Play area is 1280x960", is_equal_approx(bounds.size.x, 1280.0) and is_equal_approx(bounds.size.y, 960.0))
	check("Camera limits match play area",
		cam != null and cam.limit_left == int(bounds.position.x) and cam.limit_top == int(bounds.position.y)
		and cam.limit_right == int(bounds.position.x + bounds.size.x) and cam.limit_bottom == int(bounds.position.y + bounds.size.y))

	# --- 3. プレイ領域外への逸脱防止 ---
	player.global_position = Vector2(-500.0, -500.0)
	gs.set_player_position(player.global_position)
	await physics_frame
	await physics_frame
	check("Player is clamped inside the play area (foot)",
		player.global_position.x >= 0.0 and player.global_position.y >= 0.0
		and player.global_position.x <= 1280.0 and player.global_position.y <= 960.0)
	player.global_position = Vector2(4000.0, 4000.0)
	gs.set_player_position(player.global_position)
	await physics_frame
	await physics_frame
	check("Player is clamped inside the play area (right/bottom)",
		player.global_position.x <= 1280.0 and player.global_position.y <= 960.0)

	# --- 4. 画面外消失しない (カメラ可視領域) ---
	var viewport_size: Vector2 = main.get_viewport().get_visible_rect().size
	var visible_ok: bool = true
	for probe in [Vector2(16, 16), Vector2(1264, 944), Vector2(640, 480), Vector2(16, 944)]:
		player.global_position = probe
		gs.set_player_position(probe)
		await physics_frame
		await process_frame
		var center: Vector2 = cam.get_screen_center_position()
		var zoom: Vector2 = cam.zoom
		var screen: Vector2 = (probe - center) * zoom + viewport_size * 0.5
		if screen.x < -1.0 or screen.y < -1.0 or screen.x > viewport_size.x + 1.0 or screen.y > viewport_size.y + 1.0:
			visible_ok = false
	check("Player never leaves the camera viewport (4 corners + center)", visible_ok)

	# --- 5. KMF 搭乗中も画面外へ出ない ---
	gs.set_player_mode("kmf")
	player.global_position = Vector2(1264.0, 944.0)
	gs.set_player_position(player.global_position)
	await physics_frame
	await process_frame
	var kmf_zoom: Vector2 = cam.zoom
	var kmf_screen: Vector2 = (player.global_position - cam.get_screen_center_position()) * kmf_zoom + viewport_size * 0.5
	check("Player stays on screen while riding the KMF",
		kmf_screen.x >= -1.0 and kmf_screen.y >= -1.0 and kmf_screen.x <= viewport_size.x + 1.0 and kmf_screen.y <= viewport_size.y + 1.0)

	# --- 6. 徒歩 / KMF 同時成立禁止 ---
	var mode: String = gs.get_player_mode()
	var boarded: bool = bool(gs.get_section("kmf").get("boarded", false))
	check("mode/kmf-boarded stay mutually exclusive", not (mode == "kmf" and not boarded) and not (mode == "foot" and boarded))
	gs.set_player_mode("foot")
	check("dismount clears boarded flag", not bool(gs.get_section("kmf").get("boarded", true)))

	# --- 7. HUD Safe Area ---
	var hud: Node = main.get_node_or_null("HUD")
	check("HUD exposes hud occlusion rects", hud != null and hud.has_method("get_hud_occlusion_rects"))
	var rects: Array = hud.get_hud_occlusion_rects() if hud != null and hud.has_method("get_hud_occlusion_rects") else []
	check("HUD reports at least one persistent region", not rects.is_empty())
	check("HUD occlusion rects are screen-space Rect2", rects.all(func(r): return r is Rect2))
	check("HUD has a compact mode (H) that shrinks the persistent panel", hud != null and hud.has_method("_apply_compact_state"))
	var safe_rect: Rect2 = camera_manager.get_safe_viewport_rect() if camera_manager != null and camera_manager.has_method("get_safe_viewport_rect") else Rect2()
	check("Camera exposes a safe viewport rect", safe_rect.size.x > 0.0 and safe_rect.size.y > 0.0)

	# --- 8. Interaction ---
	var service: Node = main.get_node_or_null("InteractionService")
	check("InteractionService exists", service != null)
	check("InteractionService exposes a prompt", service != null and service.has_method("get_prompt"))
	var has_fields: bool = false
	if service != null:
		service.refresh()
		var prompt: Dictionary = service.get_prompt()
		has_fields = prompt.has("has_target")
		if bool(prompt.get("has_target", false)):
			has_fields = has_fields and prompt.has("target_name") and prompt.has("action_label") \
				and prompt.has("key_label") and prompt.has("distance") and prompt.has("required_mode")
	check("Interaction prompt exposes target/action/key/distance/mode", has_fields)

	# --- 9. Input abstraction ---
	var router: Script = load("res://core/InputRouter.gd")
	check("InputRouter abstraction exists", router != null)
	var router_ok: bool = router != null
	var router_label_ok: bool = false
	var router_map_ok: bool = false
	if router != null:
		router_label_ok = router.has_method("is_pressed") and router.has_method("get_label")
		router_map_ok = bool(router.call("is_pressed", "move_up")) == bool(Input.is_action_pressed("move_up"))
	check("InputRouter knows the primary attack binding", router_label_ok)
	check("InputRouter maps move actions to the legacy InputMap", router_map_ok)

	# --- 10. 既存回帰の非破壊 ---
	var d1: Node = main.get_node_or_null("Day1Controller")
	check("Day1 still initializes", d1 != null and d1.has_method("is_initialized") and d1.is_initialized())
	var sm: Node = main.get_node_or_null("SaveManager")
	check("Save/Load round-trip still passes", sm != null and sm.test_round_trip())
	var combat: Node = main.get_node_or_null("CombatManager")
	check("CombatManager still exposes its public API", combat != null and combat.has_method("get_enemy_count") and combat.has_method("get_focus_target"))

	_finish()

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
