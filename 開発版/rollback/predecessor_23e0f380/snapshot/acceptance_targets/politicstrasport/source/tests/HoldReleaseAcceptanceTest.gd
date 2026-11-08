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
		var message := label + (" :: " + detail if detail != "" else "")
		failures.append(message)
		push_error("FAIL: " + message)


func _left_click(map_view: Control, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = position
	map_view._gui_input(event)


func _route_for_pair(world: WorldState, a: int, b: int, route_type: int):
	for route in world.routes:
		if route.type == route_type and route.company_id == WorldState.PLAYER_COMPANY_ID \
				and ((route.from_id == a and route.to_id == b) or (route.from_id == b and route.to_id == a)):
			return route
	return null


func _run() -> void:
	var packed = load("res://scenes/Main.tscn")
	_ok(packed != null, "Main scene loads")
	if packed == null:
		quit(1)
		return
	var main = packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	var game = main.get_node("GameController")
	var map_view: Control = main.get_node("UI/MapView")
	var action_bar: Control = main.get_node("UI/ActionBar")
	var remove_button: Button = main.get_node("UI/ActionBar/BtnRemove")
	var world: WorldState = game.world
	var player: TransportCompany = world.get_player_company()
	_ok(player != null, "Player company exists")

	# 1280x720: every visible operation button must remain inside the viewport.
	var viewport_size := Vector2(1280, 720)
	for child in action_bar.get_children():
		if child is Button and child.visible:
			var rect: Rect2 = child.get_global_rect()
			_ok(rect.position.x >= 0.0 and rect.position.y >= 0.0 \
				and rect.end.x <= viewport_size.x and rect.end.y <= viewport_size.y,
				"Action button is visible: %s" % child.text, str(rect))

	# Physical player road -> logical route, with exactly-once construction accounting.
	world.money = 500.0
	world.sync_player_company_money()
	var expense_before := player.total_expenses
	var money_before := world.money
	var ta: Vector2i = world.ground.get_terminal(0)
	var tb: Vector2i = world.ground.get_terminal(1)
	var built: Dictionary = world.ground.build_path_between(
		ta, tb, Route.RouteType.ROAD, false, WorldState.PLAYER_COMPANY_ID
	)
	_ok(built.get("ok", false), "Physical player road construction succeeds", str(built))
	var construction_cost := float(built.get("cost", 0.0))
	_ok(construction_cost > 0.0, "Physical road has non-zero construction cost")
	_ok(is_equal_approx(world.money, money_before - construction_cost),
		"Player money charged exactly once for road construction")
	_ok(is_equal_approx(player.total_expenses, expense_before + construction_cost),
		"Player construction expense enters company ledger exactly once")
	_ok(is_equal_approx(player.money, world.money), "Player/world money compatibility preserved")

	var route = world.create_route(0, 1, Route.RouteType.ROAD, WorldState.PLAYER_COMPANY_ID)
	_ok(route != null, "Logical player route follows physical connection")
	var revenue_before := player.total_revenue
	var total_expense_before_day := player.total_expenses
	game._advance_day()
	_ok(player.total_revenue > revenue_before, "Player fare/cargo revenue enters company ledger")
	_ok(player.total_expenses > total_expense_before_day, "Player operating cost enters company ledger")
	_ok(player.last_day_revenue > 0.0, "Player last-day revenue is populated")
	_ok(player.last_day_expense > 0.0, "Player last-day expense is populated")
	_ok(not is_zero_approx(player.lifetime_profit), "Player lifetime profit changes")
	_ok(not is_equal_approx(player.reputation, 1.0), "Player reputation reacts to daily result")
	_ok(is_equal_approx(player.money, world.money), "Player/world money remain synchronized after transport")

	# AI and player go through the same accounting principle.
	var ai_company: TransportCompany = world.get_company(1)
	_ok(ai_company != null, "AI company exists")
	if ai_company != null:
		var ai_money_before := ai_company.money
		var ai_expense_before := ai_company.total_expenses
		var ai_revenue_before := ai_company.total_revenue
		_ok(world.pay_company(ai_company.company_id, 7.0), "AI expense transaction succeeds")
		world.add_company_revenue(ai_company.company_id, 11.0)
		_ok(is_equal_approx(ai_company.money, ai_money_before + 4.0),
			"AI balance reflects one expense and one revenue")
		_ok(is_equal_approx(ai_company.total_expenses, ai_expense_before + 7.0),
			"AI expense ledger records exactly once")
		_ok(is_equal_approx(ai_company.total_revenue, ai_revenue_before + 11.0),
			"AI revenue ledger records exactly once")

	# A: mouse route selection -> keyboard X. Use the real viewport input pipeline.
	route = _route_for_pair(world, 0, 1, Route.RouteType.ROAD)
	if route != null:
		route.obsolete = true
		var midpoint := (world.get_settlement(0).position + world.get_settlement(1).position) * 0.5
		_left_click(map_view, midpoint)
		_ok(game.selected_route_id == route.id, "A mouse selects obsolete route", str(game.selected_route_id))
		var x_event := InputEventKey.new()
		x_event.keycode = KEY_X
		x_event.physical_keycode = KEY_X
		x_event.pressed = true
		Input.parse_input_event(x_event)
		await process_frame
		await process_frame
		_ok(world.get_route(route.id) == null, "A keyboard X removes selected obsolete route")
	else:
		_ok(false, "A route exists before keyboard removal")

	# B: recreate the same logical route, mouse select it, then use the UI button.
	var button_route = world.ground._ensure_logical_route(
		0, 1, Route.RouteType.ROAD, WorldState.PLAYER_COMPANY_ID
	)
	if button_route != null:
		button_route.obsolete = true
		var midpoint_b := (world.get_settlement(0).position + world.get_settlement(1).position) * 0.5
		_left_click(map_view, midpoint_b)
		_ok(game.selected_route_id == button_route.id, "B mouse selects obsolete route", str(game.selected_route_id))
		remove_button.emit_signal("pressed")
		await process_frame
		_ok(world.get_route(button_route.id) == null, "B remove button removes selected obsolete route")
	else:
		_ok(false, "B route can be recreated for button removal")

	# Game-side rejection remains correct and is observable for expected-rejection QA.
	var inland = null
	for settlement in world.settlements:
		if settlement.active and not settlement.is_supply_base and not game.ship_system.is_port_capable(settlement):
			inland = settlement
			break
	if inland != null:
		var rejection_money := world.money
		game.select_settlement(inland.id)
		var rejected: bool = game.build_port_selected()
		_ok(not rejected and not inland.has_port, "Inland port construction is rejected")
		_ok(is_equal_approx(world.money, rejection_money), "Rejected port construction has no charge")
		_ok(world.event_log.any(func(entry): return str(entry).contains("内陸")),
			"Expected rejection reason is present in state log")
	else:
		_ok(false, "An inland city exists for expected-rejection test")

	print("=== HOLD RELEASE ACCEPTANCE SUMMARY ===")
	print("PASS COUNT: ", passes.size())
	print("FAIL COUNT: ", failures.size())
	if failures.is_empty():
		quit(0)
	else:
		for failure in failures:
			print("FAILED: ", failure)
		quit(1)

