extends SceneTree
## Player-visible Day1 regression for opening enemies, navigation and parked KMF.
var failed: int = 0

func _check(ok: bool, label: String) -> void:
	if ok:
		print("[FIRST PLAY PASS] " + label)
	else:
		print("[FIRST PLAY FAIL] " + label)
		failed += 1

func _init() -> void:
	call_deferred("_run")

func _tick() -> void:
	await process_frame
	await physics_frame

func _run() -> void:
	var packed: PackedScene = load("res://scenes/Main.tscn")
	_check(packed != null, "Main scene loads")
	if packed == null:
		quit(1)
		return
	var gs: Node = get_root().get_node_or_null("GameState")
	_check(gs != null, "GameState autoload accessible")
	var main: Node = packed.instantiate()
	get_root().add_child(main)
	for n in range(4):
		await _tick()
	var player: Node = main.get_node("Player")
	var marker: Node2D = main.get_node("OwnedKMFMarker")
	var combat: Node = main.get_node("CombatManager")
	var hud: Node = main.get_node("HUD")
	var kmf: Dictionary = gs.get_section("kmf")
	var kpos_dict: Dictionary = kmf.get("position", {})
	var kpos := Vector2(float(kpos_dict.get("x", 0.0)), float(kpos_dict.get("y", 0.0)))
	_check(marker.visible and marker.global_position.distance_to(kpos) < 1.0, "Parked KMF drawn at canonical position")
	_check(hud._navigation_label != null and hud._navigation_label.text.contains("ユイ"), "Initial destination guidance")
	_check(hud._navigation_label.text.contains("自機KMF"), "KMF direction on HUD")
	var enemy_kmf: Node2D = null
	for child in combat.get_children():
		if child is Node2D and child.has_meta("type") and str(child.get_meta("type")) == "enemy_kmf":
			enemy_kmf = child
	_check(enemy_kmf != null, "Enemy KMF retained for future threats")
	if enemy_kmf != null:
		var original_pos := enemy_kmf.global_position
		for n in range(20):
			await _tick()
		_check(enemy_kmf.global_position.distance_to(original_pos) < 1.0, "No instant cross-city enemy KMF pursuit")
	player.global_position = kpos
	gs.set_player_position(kpos)
	player._try_board_or_disembark()
	for n in range(3):
		await _tick()
	_check(gs.get_player_mode() == "kmf" and not marker.visible, "Boarding hides parked marker")
	player.global_position = kpos + Vector2(40, 0)
	gs.set_player_position(player.global_position)
	player._try_board_or_disembark()
	for n in range(3):
		await _tick()
	_check(gs.get_player_mode() == "foot" and marker.visible, "Dismount restores marker")
	var moved_kmf: Dictionary = gs.get_section("kmf").get("position", {})
	var expected_pos := Vector2(float(moved_kmf.get("x", 0)), float(moved_kmf.get("y", 0)))
	_check(marker.global_position.distance_to(expected_pos) < 1.0, "Marker follows saved KMF position")
	_check(hud._navigation_label.text.contains("自機KMF"), "KMF guidance remains available after dismount")
	print("FIRST PLAY UX: " + ("PASSED" if failed == 0 else "FAILED"))
	quit(0 if failed == 0 else 1)
