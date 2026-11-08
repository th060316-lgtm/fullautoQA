extends SceneTree

## Deterministic 300-day management acceptance profile.
## The player road is constructed as physical GroundNetwork tiles first, then
## registered as a logical Route. Day 150 and Day 300 are persisted as evidence.

var failures: Array[String] = []
var checkpoints: Dictionary = {}


func _init() -> void:
	call_deferred("_go")


func _fail(message: String) -> void:
	failures.append(message)
	push_error("LONG RUN FAIL: " + message)


func _company_metrics(world: WorldState, company: TransportCompany) -> Dictionary:
	var transported := 0.0
	var active_routes := 0
	for route in world.routes:
		if route.company_id != company.company_id:
			continue
		transported += float(route.total_carried)
		if route.active:
			active_routes += 1
	return {
		"id": company.company_id,
		"name": company.company_name,
		"money": company.money,
		"total_revenue": company.total_revenue,
		"total_expenses": company.total_expenses,
		"lifetime_profit": company.lifetime_profit,
		"last_day_revenue": company.last_day_revenue,
		"last_day_expense": company.last_day_expense,
		"reputation": company.reputation,
		"route_count": active_routes,
		"transported": transported,
		"connections_built": company.connections_built,
		"connections_removed": company.connections_removed,
	}


func _is_finite_world(world: WorldState) -> bool:
	if not is_finite(world.money):
		return false
	for company in world.companies:
		for value in [
			company.money, company.total_revenue, company.total_expenses,
			company.lifetime_profit, company.last_day_revenue,
			company.last_day_expense, company.reputation,
		]:
			if not is_finite(float(value)):
				return false
	for settlement in world.settlements:
		for value in [
			settlement.population, settlement.economy, settlement.food_demand,
			settlement.fuel_demand, settlement.passenger_demand,
			settlement.food_supply_capacity, settlement.fuel_supply_capacity,
		]:
			if not is_finite(float(value)):
				return false
		for demand in settlement.passenger_destinations.values():
			if not is_finite(float(demand)):
				return false
	return true


func _checkpoint(world: WorldState, ai: AICompetitionSystem) -> Dictionary:
	var companies: Array = []
	for company in world.companies:
		companies.append(_company_metrics(world, company))
	var active_supply_bases := 0
	for settlement in world.settlements:
		if settlement.is_supply_base and settlement.active:
			active_supply_bases += 1
	var obsolete_routes := 0
	for route in world.routes:
		if route.obsolete:
			obsolete_routes += 1
	var ai_counters: Array = []
	for brain in ai.brains:
		ai_counters.append({
			"company_id": brain.company.company_id,
			"build_count": brain.build_count,
			"remove_count": brain.remove_count,
		})
	return {
		"day": world.day,
		"world_money": world.money,
		"companies": companies,
		"route_count": world.routes.size(),
		"settlement_count": world.settlements.size(),
		"active_supply_bases": active_supply_bases,
		"obsolete_routes": obsolete_routes,
		"finite": _is_finite_world(world),
		"ai_counters": ai_counters,
	}


func _go() -> void:
	var world := WorldState.new(20261026)
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
	ai.create_ai_companies()
	ai.configure_ground_provider(world.ground)

	world.money = 500.0
	world.sync_player_company_money()
	var terminal_a: Vector2i = world.ground.get_terminal(0)
	var terminal_b: Vector2i = world.ground.get_terminal(1)
	var physical := world.ground.build_path_between(
		terminal_a, terminal_b, Route.RouteType.ROAD, false,
		WorldState.PLAYER_COMPANY_ID
	)
	if not physical.get("ok", false):
		_fail("player physical road construction failed: %s" % physical)
	var player_route = world.create_route(
		0, 1, Route.RouteType.ROAD, WorldState.PLAYER_COMPANY_ID
	)
	if player_route == null:
		_fail("player logical road route was not created after physical connection")
	if not world.ground.has_settlement_connection(0, 1, Route.RouteType.ROAD):
		_fail("player physical road is not connected")
	var player_company := world.get_player_company()
	if player_company == null or player_company.total_expenses <= 0.0:
		_fail("player construction expense was not recorded")
	if player_company != null and not is_equal_approx(player_company.money, world.money):
		_fail("player company money diverged from world.money after construction")

	while world.day < 300:
		world.day += 1
		if world.ground != null:
			world.ground.refresh_logical_routes()
		economy.process_day()
		politics.process_day()
		war.process_day()
		ai.process_day()
		if world.day == 150 or world.day == 300:
			checkpoints[str(world.day)] = _checkpoint(world, ai)
			print("LONG_RUN_CHECKPOINT ", JSON.stringify(checkpoints[str(world.day)]))

	if not checkpoints.has("150") or not checkpoints.has("300"):
		_fail("Day150/Day300 checkpoint missing")
	var final_checkpoint: Dictionary = checkpoints.get("300", {})
	if not final_checkpoint.get("finite", false):
		_fail("NaN/Inf detected in company, demand, or city values")
	if int(final_checkpoint.get("route_count", 1000000)) >= 100:
		_fail("route count indicates unbounded growth")
	if int(final_checkpoint.get("active_supply_bases", 1000000)) > 2:
		_fail("supply bases exceeded the two-side wartime bound")
	if int(final_checkpoint.get("obsolete_routes", 1000000)) >= 20:
		_fail("obsolete routes indicate unbounded residue")

	if player_company != null:
		if player_company.total_revenue <= 0.0:
			_fail("player revenue remained zero")
		if player_company.total_expenses <= 0.0:
			_fail("player expenses remained zero")
		if is_zero_approx(player_company.lifetime_profit):
			_fail("player lifetime profit remained zero")
		if is_equal_approx(player_company.reputation, 1.0):
			_fail("player reputation remained fixed at its initial value")
		if not is_equal_approx(player_company.money, world.money):
			_fail("player company money diverged from world.money at Day300")

	var ai_built := false
	for brain in ai.brains:
		if brain.build_count > 0:
			ai_built = true
		var company: TransportCompany = brain.company
		if company.total_revenue <= 0.0 and company.total_expenses <= 0.0:
			_fail("AI company accounting remained entirely zero: %s" % company.company_name)
	if not ai_built:
		_fail("AI construction never started during 300-day profile")

	var result := {
		"status": "pass" if failures.is_empty() else "fail",
		"failures": failures,
		"physical_player_road": physical,
		"player_route_id": player_route.id if player_route != null else -1,
		"checkpoints": checkpoints,
	}
	var output = FileAccess.open("res://tests/long-run-results.json", FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify(result, "\t"))
	print("=== LONG RUN SUMMARY ===")
	print(JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)

