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

func _resolve_now(world: WorldState, war: WarSystem) -> void:
	world.war_days_left = 1
	war.process_day()

func _run() -> void:
	print("=== PoliticsTrasport destructive/boundary test ===")
	var world = WorldState.new(7001)
	world.create_initial_world()
	world.money = 1000.0
	var money0 = world.money
	_ok(world.create_route(0, 0, Route.RouteType.ROAD) == null and world.money == money0, "Same-endpoint route rejected without cost")
	_ok(world.create_route(0, 9999, Route.RouteType.ROAD) == null and world.money == money0, "Unknown endpoint route rejected without cost")
	var inactive = Settlement.new(999, "inactive", Vector2.ZERO)
	inactive.active = false
	world.settlements.append(inactive)
	_ok(world.create_route(0, inactive.id, Route.RouteType.ROAD) == null and world.money == money0, "Inactive endpoint route rejected without cost")
	_ok(world.create_route(0, 1, 999) == null and world.money == money0, "Unknown route type rejected without cost")
	world.money = 7.0
	world.sync_player_company_money()
	var unaffordable = world.ground.build_road(Vector2i(0, 0), false, WorldState.PLAYER_COMPANY_ID)
	_ok(not unaffordable.get("ok", false) and is_equal_approx(world.money, 7.0), "Insufficient funds rejects road tile without cost")

	var churn = WorldState.new(7002)
	churn.create_initial_world()
	churn.money = 100000.0
	churn.sync_player_company_money()
	var churn_a: Vector2i = churn.ground.get_terminal(0)
	var churn_b: Vector2i = churn.ground.get_terminal(1)
	churn.ground.build_path_between(churn_a, churn_b, Route.RouteType.ROAD, true, WorldState.PLAYER_COMPANY_ID)
	for i in range(250):
		var r = churn.create_route(0, 1, Route.RouteType.ROAD)
		if r == null:
			break
		churn.remove_route(r.id)
	_ok(churn.routes.size() <= 2, "250 build/remove cycles do not retain unbounded inactive route records", str(churn.routes.size()))

	var no_route = WorldState.new(7003)
	no_route.create_initial_world()
	var war0 = WarSystem.new(no_route)
	war0._start_war(0, 1)
	var no_route_base_id = no_route.war_supply_base_id
	_ok(no_route.get_settlement(no_route_base_id) != null, "No-route war creates temporary base")
	_resolve_now(no_route, war0)
	_ok(no_route.get_settlement(no_route_base_id) == null, "Unconnected temporary base is purged after war")

	var stranded = WorldState.new(7004)
	stranded.create_initial_world()
	stranded.money = 10000.0
	var war1 = WarSystem.new(stranded)
	war1._start_war(0, 1)
	var base_id = stranded.war_supply_base_id
	var stranded_a: Vector2i = stranded.ground.get_terminal(0)
	var stranded_b: Vector2i = stranded.ground.get_terminal(base_id)
	stranded.ground.build_path_between(stranded_a, stranded_b, Route.RouteType.ROAD, true, WorldState.PLAYER_COMPANY_ID)
	var sr = stranded.create_route(0, base_id, Route.RouteType.ROAD)
	_ok(sr != null, "Stranded-route setup connects base")
	_resolve_now(stranded, war1)
	var kept_base = stranded.get_settlement(base_id)
	_ok(kept_base == null and sr.active and sr.obsolete, "Postwar base is purged while obsolete route remains selectable by stored path")
	stranded.remove_route(sr.id)
	_ok(stranded.get_settlement(base_id) == null, "Removing last stranded route purges obsolete base endpoint")
	_ok(stranded.routes.size() == 0, "Removing stranded route purges inactive route record")

	var repeated = WorldState.new(7005)
	repeated.create_initial_world()
	var war2 = WarSystem.new(repeated)
	for i in range(100):
		war2._start_war(i % 3, (i + 1) % 3)
		_resolve_now(repeated, war2)
	_ok(repeated.settlements.size() == 6, "100 no-route wars leave no obsolete temporary settlements", str(repeated.settlements.size()))
	_ok(repeated.event_log.size() <= repeated.MAX_LOG, "100-war event log remains bounded", str(repeated.event_log.size()))

	print("=== DESTRUCTIVE SUMMARY ===")
	print("PASS COUNT: ", passes.size())
	print("FAIL COUNT: ", failures.size())
	if failures.size() > 0:
		for f in failures:
			print("FAILED: ", f)
		quit(1)
	else:
		print("ALL DESTRUCTIVE TESTS PASSED")
		quit(0)

