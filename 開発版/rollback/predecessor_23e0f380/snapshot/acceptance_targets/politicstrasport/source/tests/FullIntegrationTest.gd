extends SceneTree

var passes: Array[String] = []
var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run_all")

func _ok(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		passes.append(label)
		print("PASS: ", label)
	else:
		failures.append(label + (" :: " + detail if detail != "" else ""))
		push_error("FAIL: " + label + (" :: " + detail if detail != "" else ""))

func _make(seed_value: int = 20261030) -> Dictionary:
	var world := WorldState.new(seed_value)
	world.create_initial_world()
	var economy := EconomySystem.new(world)
	var politics := PoliticalSystem.new(world)
	var war := WarSystem.new(world)
	var ship := ShipSystem.new(world)
	var air := AirSystem.new(world)
	var transport := TransportSystem.new(world)
	transport.war_policy = war.war_policy
	economy.transport_system = transport
	var ai := AICompetitionSystem.new(world)
	ai.setup(ship, air)
	ai.configure_ground_provider(world.ground)
	ai.create_ai_companies()
	return {"world":world,"economy":economy,"politics":politics,"war":war,"ship":ship,"air":air,"transport":transport,"ai":ai}

func _run_all() -> void:
	print("=== PoliticsTrasport v0.2 Integrated Acceptance ===")
	await _test_scene_boot_and_inputs()
	_test_unified_classes_and_ground()
	_test_ai_ground_company_money_and_ownership()
	_test_company_parallel_ground_routes()
	_test_ground_cut_and_repair()
	_test_ship_and_air()
	_test_war_supply_and_ground_terminals()
	_test_transport_long_run()
	print("=== SUMMARY ===")
	print("PASS COUNT: ", passes.size())
	print("FAIL COUNT: ", failures.size())
	for f in failures:
		print("FAILED: ", f)
	quit(1 if failures.size() > 0 else 0)

func _test_scene_boot_and_inputs() -> void:
	var packed = load("res://scenes/Main.tscn")
	_ok(packed != null, "Main.tscn loads")
	if packed == null:
		return
	var main = packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var game = main.get_node_or_null("GameController")
	_ok(game != null, "GameController boots")
	if game != null:
		_ok(game.world != null and game.world.ground != null, "Scene owns GroundNetwork")
		_ok(game.ai_system != null and game.ai_system.adapter.has_provider(), "AI GroundTransportAdapter is bound to real provider")
		game.start_build_road()
		_ok(game.build_mode == 0, "Road uses tile build mode")
		game.start_build_rail()
		_ok(game.build_mode == 1, "Rail uses tile build mode")
		game.start_build_ship()
		_ok(game.build_mode == 2, "Ship uses city-pair mode")
		game.start_build_air()
		_ok(game.build_mode == 3, "Air uses city-pair mode")
		game.start_remove_infra()
		_ok(game.build_mode == 4, "Ground removal has separate mode")
	main.queue_free()
	await process_frame

func _test_unified_classes_and_ground() -> void:
	var ctx = _make(1001)
	var world: WorldState = ctx.world
	_ok(Route.RouteType.ROAD == 0 and Route.RouteType.RAIL == 1 and Route.RouteType.SHIP == 2 and Route.RouteType.AIR == 3,
		"Unified RouteType enum is ROAD/RAIL/SHIP/AIR")
	_ok(world.settlements.size() == 6 and world.nations.size() == 3, "Initial world remains 6 settlements / 3 nations")
	_ok(world.ground.terminals.size() == 6, "All initial settlements have fixed ground terminals", str(world.ground.terminals.size()))
	world.money = 5000.0
	world.sync_player_company_money()
	var a = world.ground.get_terminal(0)
	var b = world.ground.get_terminal(1)
	var money_before = world.money
	var built = world.ground.build_path_between(a, b, Route.RouteType.ROAD, false, WorldState.PLAYER_COMPANY_ID)
	_ok(built.ok, "Player can physically lay road tiles between terminals", str(built))
	_ok(world.money < money_before, "Player pays per-tile ground construction cost")
	var route = world.ground._ensure_logical_route(0, 1, Route.RouteType.ROAD, WorldState.PLAYER_COMPANY_ID)
	_ok(route != null and route.company_id == 0, "Player logical ground route is owned by player")
	_ok(route != null and route.build_cost == 0.0, "Logical ground route does not double-charge flat build cost")

func _test_ai_ground_company_money_and_ownership() -> void:
	var ctx = _make(2002)
	var world: WorldState = ctx.world
	var ai_company: TransportCompany = world.companies[1]
	var ai_before = ai_company.money
	var player_before = world.money
	var rail_before = world.ground.count_infra(Route.RouteType.RAIL)
	var rid: int = ctx.ai.adapter.request_ground_connection(ai_company.company_id, Route.RouteType.RAIL, 2, 3)
	var route = world.get_route(rid)
	_ok(rid >= 0 and route != null, "AI ground provider creates a real rail route", str(rid))
	_ok(route != null and route.company_id == ai_company.company_id, "AI ground route preserves company_id")
	_ok(ai_company.money < ai_before, "AI pays ground tile construction from its own funds", "%s -> %s" % [ai_before, ai_company.money])
	_ok(abs(world.money - player_before) < 0.001, "AI ground construction does not charge player funds", str(world.money))
	_ok(world.ground.count_infra(Route.RouteType.RAIL) > rail_before, "AI ground request physically lays rail tiles")
	_ok(not ctx.ai.adapter.using_mock, "Integrated runtime does not use silent mock ground fallback")

func _test_company_parallel_ground_routes() -> void:
	var ctx = _make(3003)
	var world: WorldState = ctx.world
	world.money = 5000.0
	world.sync_player_company_money()
	var p_id: int = world.ground.request_ground_connection(0, Route.RouteType.ROAD, 0, 1)
	var ai_id: int = world.ground.request_ground_connection(1, Route.RouteType.ROAD, 0, 1)
	var pr = world.get_route(p_id)
	var ar = world.get_route(ai_id)
	_ok(p_id >= 0 and ai_id >= 0 and p_id != ai_id, "Player and AI can own parallel logical routes on same city pair")
	_ok(pr != null and ar != null and pr.company_id == 0 and ar.company_id == 1, "Parallel routes keep separate owners")
	var same_pair := 0
	for r in world.routes:
		if r.type == Route.RouteType.ROAD and ((r.from_id == 0 and r.to_id == 1) or (r.from_id == 1 and r.to_id == 0)):
			same_pair += 1
	_ok(same_pair == 2, "Duplicate contract is pair x company x mode", str(same_pair))

func _test_ground_cut_and_repair() -> void:
	var ctx = _make(4004)
	var world: WorldState = ctx.world
	world.money = 5000.0
	world.sync_player_company_money()
	var rid: int = world.ground.request_ground_connection(0, Route.RouteType.ROAD, 0, 1)
	var route = world.get_route(rid)
	var a = world.ground.get_terminal(0)
	var b = world.ground.get_terminal(1)
	var cells: Array[Vector2i] = world.ground._bresenham_line(a, b)
	_ok(cells.size() >= 3, "Ground path has removable middle tile", str(cells.size()))
	if route == null or cells.size() < 3:
		return
	var mid = cells[cells.size() / 2]
	world.ground.remove_infra(mid, Route.RouteType.ROAD)
	world.ground.refresh_logical_routes()
	_ok(not route.active, "Removing middle ground tile deactivates logical route")
	world.ground.build_road(mid, true, 0)
	world.ground.refresh_logical_routes()
	_ok(route.active, "Repairing tile reactivates logical route")

func _test_ship_and_air() -> void:
	var ctx = _make(5005)
	var world: WorldState = ctx.world
	world.money = 10000.0
	world.sync_player_company_money()
	_ok(ctx.ship.build_port(1, 0) and ctx.ship.build_port(4, 0), "Player can build two valid ports")
	var ship_route = ctx.ship.create_ship_connection(0, 1, 4)
	_ok(ship_route != null and ship_route.type == Route.RouteType.SHIP, "Ship route is created")
	_ok(ctx.air.build_airport(0, 0) and ctx.air.build_airport(2, 0), "Player can build two airports")
	var air_route = ctx.air.create_air_connection(0, 0, 2)
	_ok(air_route != null and air_route.type == Route.RouteType.AIR, "Air route is created")

func _test_war_supply_and_ground_terminals() -> void:
	var ctx = _make(6006)
	var world: WorldState = ctx.world
	world.money = 10000.0
	world.sync_player_company_money()
	ctx.war._start_war(0, 1)
	_ok(world.war_supply_base_ids.size() == 2, "War spawns bilateral supply bases", str(world.war_supply_base_ids))
	var red_base = null
	for bid in world.war_supply_base_ids:
		var base = world.get_settlement(bid)
		if base != null and base.support_nation_id == 0:
			red_base = base
		_ok(world.ground.terminals.has(bid), "Supply base receives a fixed ground terminal")
	_ok(red_base != null, "Red-side supply base exists")
	if red_base == null:
		return
	var red_city = world.get_settlement(0)
	var blue_city = world.get_settlement(2)
	_ok(ctx.war.war_policy.is_valid_supply_source(red_city, red_base), "Same-side city is valid military supply source")
	_ok(not ctx.war.war_policy.is_valid_supply_source(blue_city, red_base), "Enemy city is rejected as military supply source")
	var base_ids = world.war_supply_base_ids.duplicate()
	var rid = world.ground.request_ground_connection(0, Route.RouteType.ROAD, red_city.id, red_base.id)
	_ok(rid >= 0, "Ground connection can be constructed to temporary supply base")
	var stranded = world.get_route(rid)
	ctx.war._end_war_cleanup()
	for bid in base_ids:
		_ok(world.get_settlement(bid) == null, "Temporary supply base removed from settlements")
		_ok(not world.ground.terminals.has(bid), "Retired supply-base terminal is removed")
	_ok(stranded != null and stranded.obsolete and stranded.active, "Postwar supply route remains visible/removable but obsolete")
	_ok(not stranded.is_operational(world), "Obsolete postwar route cannot carry traffic")

func _test_transport_long_run() -> void:
	var ctx = _make(7007)
	var world: WorldState = ctx.world
	world.money = 20000.0
	world.sync_player_company_money()
	world.ground.request_ground_connection(0, Route.RouteType.ROAD, 0, 1)
	ctx.ship.build_port(1, 0)
	ctx.ship.build_port(4, 0)
	ctx.ship.create_ship_connection(0, 1, 4)
	for _i in range(365):
		world.day += 1
		world.ground.refresh_logical_routes()
		ctx.economy.process_day()
		ctx.politics.process_day()
		ctx.war.process_day()
		ctx.ai.process_day()
	_ok(world.money >= 0.0 and world.money < 1000000000.0, "365-day player money remains finite/non-negative", str(world.money))
	_ok(world.event_log.size() <= world.MAX_LOG, "Event log remains bounded", str(world.event_log.size()))
	for c in world.companies:
		_ok(c.money >= 0.0 and c.money < 1000000000.0, "Company funds remain finite/non-negative: " + c.company_name, str(c.money))
