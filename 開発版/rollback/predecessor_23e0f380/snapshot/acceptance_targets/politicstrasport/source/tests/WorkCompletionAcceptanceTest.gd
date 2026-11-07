extends SceneTree

var failures: Array[String] = []
var passes: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _ok(condition: bool, label: String) -> void:
	if condition:
		passes.append(label)
		print("PASS: ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)

func _sum_moves(moves: Array) -> float:
	var total := 0.0
	for move in moves:
		total += float(move[1])
	return total

func _run() -> void:
	var world := WorldState.new(20261101)
	world.create_initial_world()
	world.economic_core = EconomicCore.new(world)
	world.economic_core.bootstrap_from_settlements()
	var policy := WarSupplyPolicy.new(world)
	var dynamics := WorldDynamicsSystem.new(world, policy)
	dynamics.set_economy_delegate(world.economic_core)

	# #8: all saved political-logistics profile families are selectable and materially affect demand.
	var n0 = world.get_nation(0)
	n0.economic_system = Nation.EconomicSystem.MIXED
	n0.logistics_profile = Nation.LogisticsProfile.STANDARD
	var luxury_base := n0.logistics_multiplier("luxury")
	_ok(dynamics.political.set_logistics_profile(0, Nation.LogisticsProfile.SILK_ROAD),
		"#8 Silk Road profile selectable")
	_ok(n0.logistics_multiplier("luxury") > luxury_base, "#8 Silk Road raises high-value logistics")
	dynamics.political.set_logistics_profile(0, Nation.LogisticsProfile.MILITARY_ALLIANCE)
	var military_mult := n0.logistics_multiplier("military")
	dynamics.political.set_logistics_profile(0, Nation.LogisticsProfile.STANDARD)
	_ok(military_mult > n0.logistics_multiplier("military"), "#8 military alliance raises military logistics")
	for profile in [
		Nation.LogisticsProfile.FEUDAL_CENTER,
		Nation.LogisticsProfile.VASSAL,
		Nation.LogisticsProfile.COLONIAL,
		Nation.LogisticsProfile.TRIBUTARY,
		Nation.LogisticsProfile.SILK_ROAD,
		Nation.LogisticsProfile.INTEGRATION_BLOC,
		Nation.LogisticsProfile.INTERNATIONAL_ORG,
		Nation.LogisticsProfile.MILITARY_ALLIANCE,
		Nation.LogisticsProfile.CUSTOMS_UNION,
		Nation.LogisticsProfile.FRONTIER,
	]:
		_ok(dynamics.political.set_logistics_profile(0, profile), "#8 profile %d is supported" % profile)

	# #12: cooperation is functional; spare capacity of one partner can absorb another's unserved demand.
	var a := dynamics.companies.create_company("qa")
	var b := dynamics.companies.create_company("qa")
	var c := dynamics.companies.create_company("qa")
	_ok(a != null and b != null and c != null, "#12 dynamic QA companies created")
	var industry_entrant := dynamics.companies.create_company_from_related_industry("construction")
	_ok(industry_entrant != null, "#12 related industry can enter transport market")
	if industry_entrant != null:
		_ok(industry_entrant.origin_business_type == "construction",
			"#12 entrant preserves related-industry origin")
	var r1 := Route.new(world.next_route_id, 0, 2, Route.RouteType.AIR)
	world.next_route_id += 1
	r1.company_id = a.company_id
	r1.capacity = 20.0
	r1.carried_passenger = 19.8
	var r2 := Route.new(world.next_route_id, 0, 2, Route.RouteType.AIR)
	world.next_route_id += 1
	r2.company_id = b.company_id
	r2.capacity = 20.0
	var r3 := Route.new(world.next_route_id, 0, 2, Route.RouteType.AIR)
	world.next_route_id += 1
	r3.company_id = c.company_id
	r3.capacity = 20.0
	world.routes.append_array([r1, r2, r3])
	a.add_connection(r1.id)
	b.add_connection(r2.id)
	c.add_connection(r3.id)
	var competition := CompetitionResolver.new(world)
	competition.refresh_scores()
	var solo_moved := _sum_moves(competition.distribute([r1, r2, r3], 20.0, TransportModeConfig.Cargo.PASSENGER))
	_ok(dynamics.corporate.create_cooperation(a.company_id, b.company_id), "#12 cooperation agreement created")
	competition.refresh_scores()
	var coop_moved := _sum_moves(competition.distribute([r1, r2, r3], 20.0, TransportModeConfig.Cargo.PASSENGER))
	_ok(coop_moved > solo_moved + 0.05, "#12 cooperation reallocates otherwise unserved demand")

	# #13/#14: hostile acquisition, related business, subsidiary directives and player investment APIs.
	world.money = 20000.0
	world.sync_player_company_money()
	_ok(dynamics.intervention.invest_transport_company(a.company_id, 0.51, true),
		"#13/#14 hostile transport-company acquisition entry point")
	_ok(a.parent_company_id == WorldState.PLAYER_COMPANY_ID, "#13 acquired transport company becomes subsidiary")
	_ok(dynamics.intervention.set_subsidiary_directive(a.company_id, "preferred_mode", Route.RouteType.RAIL),
		"#13 parent can set high-level subsidiary directive")
	_ok(int(a.management_directives.get("preferred_mode", -1)) == Route.RouteType.RAIL,
		"#13 subsidiary directive stored for AI strategy")

	var construction_business := {}
	for business in dynamics.corporate.related_businesses:
		if str(business.get("service", "")) == "construction":
			construction_business = business
			break
	_ok(not construction_business.is_empty(), "#13 related construction company exists")
	var related_id := int(construction_business.get("id", -1))
	_ok(dynamics.intervention.acquire_related_business(related_id, 0.51, true),
		"#13 related construction company can be hostile-acquired")
	_ok(int(construction_business.get("owner_company_id", -1)) == WorldState.PLAYER_COMPANY_ID,
		"#13 related company becomes player group company")
	var cash_before := world.money
	var contract_id := dynamics.corporate.request_outsource(WorldState.PLAYER_COMPANY_ID, "construction", 100.0, 5)
	_ok(contract_id > 0, "#13 owned construction company accepts outsource contract")
	_ok(is_equal_approx(cash_before - world.money, 65.0), "#13 owned related company reduces outsourcing cost without double charge")

	# #10: war damages actual industry production; reconstruction/military state drives industrial cargo demand.
	var facilities := world.economic_core.facilities_at(0)
	_ok(not facilities.is_empty(), "#10 economic facility exists for war damage test")
	if not facilities.is_empty():
		var fac = facilities[0]
		var cargo_keys: Array = fac.production_capacity.keys()
		if not cargo_keys.is_empty():
			var cargo_id := int(cargo_keys[0])
			var production_before: float = fac.effective_production(cargo_id)
			world.economic_core.apply_facility_damage(0, 0.40)
			var production_after: float = fac.effective_production(cargo_id)
			_ok(production_after < production_before, "#10 facility war damage lowers real production")
			var damage_before: float = fac.war_damage
			world.economic_core.repair_facility_damage(0, 0.10)
			_ok(fac.war_damage < damage_before, "#10 reconstruction repairs facility damage")

	var s0 = world.get_settlement(0)
	s0.reconstruction_demand = 0.0
	s0.military_demand = 0.0
	world.economic_core.update_markets()
	var industrial_market = world.economic_core.get_or_create_market(0, CargoRegistry.CargoKind.INDUSTRIAL)
	var normal_capacity: float = industrial_market.market_capacity
	s0.reconstruction_demand = 15.0
	s0.military_demand = 12.0
	world.economic_core.update_markets()
	_ok(industrial_market.market_capacity > normal_capacity * 1.5,
		"#10 military/reconstruction demand expands actual industrial cargo market")

	# Military demand also creates/expands a secondary industrial facility.
	world.war_active = true
	world.war_nation_a = 0
	world.war_nation_b = 1
	dynamics.impact.process_day()
	var industrial_found := false
	for fac in world.economic_core.facilities_at(0):
		if fac.production_capacity.has(CargoRegistry.CargoKind.INDUSTRIAL):
			industrial_found = true
			break
	_ok(industrial_found, "#10 wartime demand creates or expands military-industrial production")
	world.war_active = false

	# #15: these cross-system changes are visible through diagnostic backend.
	_ok(world.diagnostics != null and world.diagnostics.events.size() > 0,
		"#15 Work diagnostics contains cross-system change reasons")
	var economic_snapshot := world.economic_core.diagnostic_snapshot()
	_ok(economic_snapshot.has("damaged_facility_count"), "#15 economic diagnostics exposes facility damage")

	print("PASS COUNT: ", passes.size(), " FAIL COUNT: ", failures.size())
	quit(1 if failures.size() > 0 else 0)
