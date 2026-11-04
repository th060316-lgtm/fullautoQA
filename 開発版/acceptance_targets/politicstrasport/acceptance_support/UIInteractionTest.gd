extends SceneTree

var failures: Array[String] = []
var passes: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _ok(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		passes.append(label)
		print("PASS: ", label)
	else:
		failures.append(label + (" :: " + detail if detail != "" else ""))
		push_error("FAIL: " + label + (" :: " + detail if detail != "" else ""))

func _button_by_text(parent: Node, label: String) -> Button:
	for child in parent.get_children():
		if child is Button and child.text == label:
			return child
	return null

func _left_click(map_view: Control, pos: Vector2) -> void:
	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	map_view._gui_input(ev)

func _run() -> void:
	print("=== PoliticsTrasport UI interaction test ===")
	var packed = load("res://scenes/Main.tscn")
	_ok(packed != null, "Main scene loads for UI interaction")
	if packed == null:
		quit(1)
		return
	var main = packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	var game = main.get_node_or_null("GameController")
	var ui = main.get_node_or_null("UI")
	var map_view = main.get_node_or_null("UI/MapView")
	var btn_road = main.get_node_or_null("UI/ActionBar/BtnRoad")
	var btn_rail = main.get_node_or_null("UI/ActionBar/BtnRail")
	var btn_remove = main.get_node_or_null("UI/ActionBar/BtnRemove")
	var btn_x1 = main.get_node_or_null("UI/TopBar/BtnX1")
	var btn_x5 = main.get_node_or_null("UI/TopBar/BtnX5")
	var btn_pause = main.get_node_or_null("UI/TopBar/BtnPause")
	var btn_force_war = main.get_node_or_null("UI/ActionBar/BtnForceWar")
	var info_panel = main.get_node_or_null("UI/RightPanel/InfoPanel")
	var log_panel = main.get_node_or_null("UI/RightPanel/LogPanel")
	var war_label = main.get_node_or_null("UI/TopBar/WarLabel")
	var action_bar = main.get_node_or_null("UI/ActionBar")
	var change_banner = main.get_node_or_null("UI/WorldChangeBanner")
	_ok(game != null and ui != null and map_view != null, "Core UI nodes exist")
	_ok(btn_road != null and btn_rail != null and btn_remove != null and btn_x1 != null and btn_x5 != null and btn_pause != null and btn_force_war != null, "All prototype control buttons exist")
	if game == null or map_view == null or btn_road == null:
		quit(1)
		return

	btn_road.emit_signal("pressed")
	_ok(game.build_mode == 0, "Road button enters road build mode")
	btn_rail.emit_signal("pressed")
	_ok(game.build_mode == 1, "Rail button enters rail build mode")
	game.cancel_build()

	btn_x5.emit_signal("pressed")
	_ok(is_equal_approx(game.time_scale, 5.0), "x5 button sets 5x speed")
	btn_x1.emit_signal("pressed")
	_ok(is_equal_approx(game.time_scale, 1.0), "x1 button restores 1x speed")
	var paused_before: bool = game.paused
	btn_pause.emit_signal("pressed")
	_ok(game.paused != paused_before, "Pause button toggles pause")
	btn_pause.emit_signal("pressed")
	_ok(game.paused == paused_before, "Pause button toggles back")

	btn_road.emit_signal("pressed")
	var s0 = game.world.get_settlement(0)
	var s1 = game.world.get_settlement(1)
	var terminal0: Vector2i = game.world.ground.get_terminal(0)
	var terminal1: Vector2i = game.world.ground.get_terminal(1)
	for tile in game.world.ground._bresenham_line(terminal0, terminal1):
		_left_click(map_view, game.world.ground.tile_to_world_center(tile))
	game.cancel_build()
	_ok(game.build_mode == -1, "Road tile build mode can be completed and cancelled")
	var built_route = null
	for r in game.world.routes:
		if r.active and ((r.from_id == 0 and r.to_id == 1) or (r.from_id == 1 and r.to_id == 0)):
			built_route = r
			break
	_ok(built_route != null, "Mouse interaction creates road between clicked cities")

	_left_click(map_view, s0.position)
	await process_frame
	_ok(game.selected_settlement_id == 0, "Map click selects city")
	_ok(info_panel != null and info_panel.text.contains(s0.name) and info_panel.text.contains("人口"), "City selection updates info panel")
	_ok(change_banner != null, "World-change banner exists")
	if action_bar != null:
		var support_button := _button_by_text(action_bar, "都市支援")
		var industry_button := _button_by_text(action_bar, "産業建設")
		_ok(support_button != null and industry_button != null, "Player intervention buttons are visible")
		if support_button != null:
			support_button.emit_signal("pressed")
			await process_frame
			_ok(info_panel.text.contains("プレイヤー介入") and info_panel.text.contains("都市支援"),
				"City support is visibly reflected in selected-city info")
			_ok(change_banner != null and change_banner.text.contains("都市開発支援"),
				"City support creates prominent world-change feedback")
		if industry_button != null:
			industry_button.emit_signal("pressed")
			await process_frame
			_ok(info_panel.text.contains("産業施設") and info_panel.text.contains("building"),
				"Industry construction is visibly reflected in selected-city info")

	if built_route != null:
		var mid = (s0.position + s1.position) * 0.5
		_left_click(map_view, mid)
		await process_frame
		_ok(game.selected_route_id == built_route.id, "Map click selects route")
		_ok(info_panel != null and info_panel.text.contains("路線") and info_panel.text.contains("容量"), "Route selection updates info panel")
		btn_remove.emit_signal("pressed")
		_ok(not built_route.active, "Remove button removes selected route")

	btn_force_war.emit_signal("pressed")
	await process_frame
	_ok(game.world.war_active, "Force-war button starts war")
	_ok(war_label != null and war_label.text.contains("戦争中"), "War label visibly changes to wartime")
	_ok(log_panel != null and log_panel.text.contains("開戦"), "Event log visibly records war start")
	var base = game.world.get_settlement(game.world.war_supply_base_id)
	_ok(base != null and base.active and base.is_supply_base, "Force-war creates active supply base")
	if base != null:
		_left_click(map_view, base.position)
		await process_frame
		_ok(game.selected_settlement_id == base.id, "Supply base can be selected by mouse")
		_ok(info_panel != null and info_panel.text.contains("補給基地") and info_panel.text.contains("支援側"), "Supply-base panel shows demands/support side")

	game.paused = false
	game.time_scale = 1.0
	game.tick_accumulator = 0.0
	var day_before: int = game.world.day
	game._process(game.DAY_LENGTH + 0.01)
	_ok(game.world.day == day_before + 1, "GameController time processing advances exactly one day")

	print("=== UI SUMMARY ===")
	print("PASS COUNT: ", passes.size())
	print("FAIL COUNT: ", failures.size())
	if failures.size() > 0:
		for f in failures:
			print("FAILED: ", f)
		quit(1)
	else:
		print("ALL UI INTERACTION TESTS PASSED")
		quit(0)

