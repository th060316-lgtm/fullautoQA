extends SceneTree

var failures: Array[String] = []
var passes: Array[String] = []

func _init() -> void:
	var watchdog := create_timer(25.0)
	watchdog.timeout.connect(func():
		push_error("FAIL: EconomicCoreIntegrationTest watchdog timeout")
		quit(2)
	)
	call_deferred("_run")

func _ok(condition: bool, label: String) -> void:
	if condition:
		passes.append(label)
		print("PASS: ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)

func _run() -> void:
	print("TRACE: setup")
	var world := WorldState.new(40715)
	world.create_initial_world()
	world.economic_core = EconomicCore.new(world)
	world.economic_core.bootstrap_from_settlements()
	var core := world.economic_core
	core.process_pre_transport()
	_ok(CargoRegistry.CargoKind.PASSENGER == 0 and CargoRegistry.CargoKind.FOOD == 1 \
		and CargoRegistry.CargoKind.FUEL == 2, "#4 legacy cargo ids remain 0/1/2")
	_ok(core.facilities.size() > world.settlements.size(), "#4 independent industry facilities bootstrap")
	_ok(not core.estimate_pair_extended_demand(0, 1).is_empty(), "#4 extended general cargo exposes route demand")

	print("TRACE: route transport")
	var route := Route.new(world.next_route_id, 0, 1, Route.RouteType.ROAD)
	route.capacity = 70.0 # Reserve enough room to observe post-legacy general cargo.
	world.next_route_id += 1
	route.company_id = WorldState.PLAYER_COMPANY_ID
	world.routes.append(route)
	world.get_player_company().add_connection(route.id)
	var transport := TransportSystem.new(world)
	var economy := EconomySystem.new(world)
	economy.transport_system = transport
	var war := WarSystem.new(world)
	transport.war_policy = war.war_policy
	var dynamics := WorldDynamicsSystem.new(world, war.war_policy)
	dynamics.set_economy_delegate(core)

	world.day += 1
	dynamics.process_pre_transport()
	economy.process_day()
	dynamics.process_post_transport()
	var general_volume := 0.0
	for amount in route.carried_general.values():
		general_volume += float(amount)
	_ok(general_volume > 0.0, "#4 new general cargo moves through an actual Route")
	_ok(route.daily_revenue > 0.0 and world.get_player_company().last_day_revenue > 0.0,
		"#5 extended cargo revenue credits route/company once")

	print("TRACE: saturation")
	var market = core.get_or_create_market(1, CargoRegistry.CargoKind.WOOD)
	market.reset_day()
	market.cumulative_delivered = 0.0
	var first_unit: float = core.compute_saturated_revenue(1, CargoRegistry.CargoKind.WOOD, 5.0, Route.RouteType.ROAD) / 5.0
	var last_unit := first_unit
	for i in range(24):
		last_unit = core.compute_saturated_revenue(1, CargoRegistry.CargoKind.WOOD, 20.0, Route.RouteType.ROAD) / 20.0
	_ok(last_unit < first_unit and last_unit >= core.registry.unit_price(CargoRegistry.CargoKind.WOOD, Route.RouteType.ROAD) * market.price_floor_ratio,
		"#5 saturation lowers value without zero-price collapse")

	print("TRACE: facility transfer")
	world.money = 2000.0
	world.sync_player_company_money()
	var facility_id := dynamics.intervention.build_industry_facility(0, "wood_processing")
	for i in range(13):
		world.day += 1
		dynamics.intervention.process_day()
	var built := dynamics.intervention.get_facility(facility_id)
	_ok(facility_id > 0 and built.get("status", "") == "operating" \
		and int(built.get("owner_company_id", 0)) == -1, "#14 player-built facility transfers to local operator")
	_ok(core.external_facility_ids.has(facility_id), "#14 transferred facility participates in production")

	print("TRACE: diagnostics")
	var snapshot := core.diagnostic_snapshot()
	_ok(snapshot.get("cargo_registry_connected", false) and snapshot.has("recent_events"),
		"#15 economic diagnostics snapshot is UI-ready")
	_ok(transport.process_call_count == 1, "single test day invokes transport exactly once")

	print("PASS COUNT: ", passes.size(), " FAIL COUNT: ", failures.size())
	quit(1 if failures.size() > 0 else 0)
